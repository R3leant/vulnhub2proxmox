#!/bin/bash

set -euo pipefail

#############################################
# Instalar dependencias
#############################################

echo "[+] Instalando dependencias..."

apt install -y \
    p7zip-full \
    libguestfs-tools

#############################################
# Datos de entrada
#############################################

read -rp "URL Mirror de la maquina (ej: https://download.vulnhub.com/symfonos/symfonos1.7z): " URL

read -rp "Almacenamiento en Proxmox [ej: local-lvm, ssd-vms]: " STORAGE
if [ -z "$STORAGE" ]; then
    echo "ERROR: El almacenamiento no puede estar vacío."
    exit 1
fi

read -rp "Bridge de red [ej: vmbr0, vmbr1]: " BRIDGE
if [ -z "$BRIDGE" ]; then
    echo "ERROR: El bridge de red no puede estar vacío."
    exit 1
fi

VMID=$(pvesh get /cluster/nextid)

ARCHIVE_FILE=$(basename "$URL")
VMNAME="${ARCHIVE_FILE%%.*}"

echo
echo "========================================="
echo " VMID          : $VMID"
echo " Nombre        : $VMNAME"
echo " Almacenamiento: $STORAGE"
echo " Bridge        : $BRIDGE"
echo "========================================="
echo

#############################################
# Descargar archivo
#############################################

echo "[1/8] Descargando..."

wget -O "$ARCHIVE_FILE" "$URL"

#############################################
# Extraer universalmente con 7z
#############################################

echo "[2/8] Extrayendo archivo universalmente..."

7z x "$ARCHIVE_FILE" -y > /dev/null

#############################################
# Obtener VMDK o disco compatible
#############################################

VMDK=$(find . -type f \( -name "*.vmdk" -o -name "*.qcow2" -o -name "*.raw" -o -name "*.img" \) | head -n1)

if [ -z "$VMDK" ]; then
    echo "ERROR: No se encontró ningún disco compatible (vmdk, qcow2, raw, img) dentro del archivo."
    exit 1
fi

VMDK="${VMDK#./}"
echo "Disco encontrado: $VMDK"

DISK_EXT="${VMDK##*.}"
DISK_EXT_LOWER=$(echo "$DISK_EXT" | tr '[:upper:]' '[:lower:]')

#############################################
# Convertir a QCOW2 (si no lo es ya)
#############################################

echo "[3/8] Preparando disco..."

if [ "$DISK_EXT_LOWER" = "qcow2" ]; then
    cp "$VMDK" "${VMNAME}.qcow2"
else
    qemu-img convert -p \
        -f "$DISK_EXT_LOWER" \
        -O qcow2 \
        "$VMDK" \
        "${VMNAME}.qcow2"
fi

#############################################
# Configurar GRUB
#############################################

echo "[4/8] Configurando GRUB..."

virt-customize \
    -a "${VMNAME}.qcow2" \
    --edit '/etc/default/grub:s/quiet/quiet net.ifnames=0 biosdevname=0/' \
    --run-command 'update-grub' || true

#############################################
# Configurar red
#############################################

echo "[5/8] Configurando red (DHCP en eth0)..."

virt-customize \
    -a "${VMNAME}.qcow2" \
    --run-command "echo -e 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp' > /etc/network/interfaces" || true

#############################################
# Crear VM
#############################################

echo "[6/8] Creando VM..."

qm create "$VMID" \
    --name "$VMNAME" \
    --memory 1024 \
    --cores 1 \
    --bios seabios \
    --machine pc \
    --net0 e1000,bridge="$BRIDGE"

#############################################
# Importar disco y capturar referencia
#############################################

echo "[7/8] Importando disco..."

# Capturamos la línea exacta que devuelve qm importdisk (ej: "successfully imported disk 'ssd-vms:103/vm-103-disk-0.raw'")
IMPORT_OUTPUT=$(qm importdisk "$VMID" "${VMNAME}.qcow2" "$STORAGE" | grep "successfully imported disk")
DISK_REF=$(echo "$IMPORT_OUTPUT" | sed -n "s/.*'\(.*\)'.*/\1/p")

if [ -z "$DISK_REF" ]; then
    echo "ERROR: No se pudo obtener la referencia del disco importado."
    exit 1
fi

echo "Referencia del disco: $DISK_REF"

#############################################
# Asociar disco
#############################################

echo "[8/8] Configurando VM..."

qm set "$VMID" \
    --sata0 "$DISK_REF" \
    --boot order=sata0

#############################################
# Limpieza
#############################################

echo "[+] Limpiando..."

rm -f "$ARCHIVE_FILE"
rm -f "${VMNAME}.qcow2"

find . -type f \( -name "*.vmdk" -o -name "*.ovf" -o -name "*.mf" -o -name "*.cert" -o -name "*.qcow2" -o -name "*.img" -o -name "*.raw" \) -delete
find . -type d -empty -delete

#############################################
# Final
#############################################

echo
echo "========================================="
echo "Importación completada correctamente"
echo "========================================="
echo
echo "VMID      : $VMID"
echo "Nombre    : $VMNAME"
echo
echo "Para arrancarla:"
echo
echo "qm start $VMID"
