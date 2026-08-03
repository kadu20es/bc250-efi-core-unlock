#!/usr/bin/env bash
# Auto-installer para BC-250 EFI Core Unlock (Adaptado para Bazzite/Distrobox)

echo "=================================================="
echo "  Instalador Automático - BC-250 Core Unlock      "
echo "  Suporte a Sistemas Imutáveis via Distrobox      "
echo "=================================================="

# 1. Verificação de Root
if [[ $EUID -eq 0 ]]; then
    echo "Erro: Por favor, NÃO execute o script inteiro com sudo."
    echo "O Distrobox precisa rodar no seu usuário normal. O script pedirá a senha do sudo automaticamente quando for montar a partição EFI."
    exit 1
fi

USER_HOME=$HOME
PROJECT_DIR="$USER_HOME/BC250_Projects"
DISTROBOX_NAME="bc250-builder"

# 2. Configuração do Diretório
echo "[1/6] Configurando diretório em $PROJECT_DIR..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR" || exit 1

# 3. Verificação do Distrobox e Compilação
echo "[2/6] Preparando ambiente de compilação..."
if ! command -v distrobox &> /dev/null; then
    echo "Erro: Distrobox não encontrado. Este script requer o Distrobox para contornar a imutabilidade do sistema."
    exit 1
fi

# Cria o container Fedora silenciosamente, se não existir
echo "      Verificando container '$DISTROBOX_NAME'..."
distrobox create --name "$DISTROBOX_NAME" --image fedora:latest --yes &> /dev/null

# O comando mágico: Executa toda a cadeia de baixar, atualizar módulos e compilar de dentro do container
echo "      Baixando dependências e compilando o arquivo .efi (Isso pode levar alguns minutos)..."
distrobox enter -n "$DISTROBOX_NAME" -- sh -c "
    sudo dnf install -y git make gcc gnu-efi gnu-efi-devel mingw64-gcc --quiet &&
    cd \"$PROJECT_DIR\" &&
    if [ ! -d bc250-efi-core-unlock ]; then
        git clone --quiet https://github.com/Hexxeh/bc250-efi-core-unlock.git
    fi &&
    cd bc250-efi-core-unlock &&
    git pull --quiet &&
    git submodule update --init --recursive --quiet &&
    make clean > /dev/null 2>&1 &&
    make > /dev/null 2>&1
"

# Verifica se o arquivo vazou corretamente para o host
if [ ! -f "$PROJECT_DIR/bc250-efi-core-unlock/bc250-unlock.efi" ]; then
    echo "Erro: A compilação falhou dentro do Distrobox. O arquivo .efi não foi encontrado."
    exit 1
fi
echo "      Compilação concluída com sucesso!"

# 4. Identificação Inteligente da Partição EFI no Host
echo "[3/6] Mapeando topologia de discos..."
EFI_DEV=$(lsblk -lno NAME,PARTTYPE | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print $1}' | head -n 1)

if [ -z "$EFI_DEV" ]; then
    EFI_DEV=$(lsblk -lno NAME,FSTYPE | grep -i "vfat" | awk '{print $1}' | head -n 1)
fi

if [ -z "$EFI_DEV" ]; then
    echo "Erro: Nenhuma partição EFI/FAT32 encontrada."
    exit 1
fi

EFI_PART_PATH="/dev/$EFI_DEV"
EFI_DISK_PATH="/dev/$(lsblk -no PKNAME "$EFI_PART_PATH")"
EFI_PART_NUM=$(lsblk -no PARTN "$EFI_PART_PATH")

echo "      Partição detectada: $EFI_PART_PATH (Disco: $EFI_DISK_PATH | Partição: $EFI_PART_NUM)"

# 5. Montagem Automática e Cópia (Aqui pedirá sudo)
echo "[4/6] Solicitando elevação de privilégios para acessar a partição EFI..."
CURRENT_MOUNT=$(lsblk -no MOUNTPOINT "$EFI_PART_PATH")
NEEDS_UNMOUNT=0

if [ -z "$CURRENT_MOUNT" ]; then
    CURRENT_MOUNT="/tmp/bc250_efi_mount_$$"
    sudo mkdir -p "$CURRENT_MOUNT"
    sudo mount "$EFI_PART_PATH" "$CURRENT_MOUNT"
    NEEDS_UNMOUNT=1
fi

DEST_DIR="$CURRENT_MOUNT/EFI/bc250"
sudo mkdir -p "$DEST_DIR"
sudo cp "$PROJECT_DIR/bc250-efi-core-unlock/bc250-unlock.efi" "$DEST_DIR/"

# 6. Gravação na NVRAM
echo "[5/6] Configurando ordem de boot na BIOS..."
OLD_ENTRY=$(efibootmgr | grep -i "BC-250 Core Unlock" | grep -o 'Boot[0-9A-F]*' | sed 's/Boot//')
if [ -n "$OLD_ENTRY" ]; then
    sudo efibootmgr -b "$OLD_ENTRY" -B -q
fi

sudo efibootmgr -c -d "$EFI_DISK_PATH" -p "$EFI_PART_NUM" -L "BC-250 Core Unlock" -l '\EFI\bc250\bc250-unlock.efi' -q

if [ $NEEDS_UNMOUNT -eq 1 ]; then
    sudo umount "$CURRENT_MOUNT"
    sudo rmdir "$CURRENT_MOUNT"
fi

echo "[6/6] Limpeza..."
echo "      Deseja remover o container de compilação para liberar espaço? (O arquivo na EFI será mantido)"
read -r -p "      Remover Distrobox 'bc250-builder'? [S/n]: " RM_BOX
if [[ "$RM_BOX" =~ ^[Ss]$ ]] || [[ -z "$RM_BOX" ]]; then
    distrobox rm "$DISTROBOX_NAME" --force &> /dev/null
    echo "      Container removido."
fi

echo "=================================================="
echo " SUCESSO! O desbloqueador EFI foi instalado."
echo "=================================================="
efibootmgr | grep -E "BootOrder|BC-250"
echo ""

read -r -p "O computador precisa ser reiniciado para ativar os 8 núcleos. Deseja reiniciar agora? [s/N]: " REBOOT_ANS
case "$REBOOT_ANS" in
    [sS]|[yY])
        echo "Reiniciando..."
        sleep 3
        sudo reboot
        ;;
    *)
        echo "Reinício adiado."
        ;;
esac