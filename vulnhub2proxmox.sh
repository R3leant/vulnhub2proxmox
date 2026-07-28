#!/bin/bash

set -euo pipefail

#############################################
# Dependencias
#############################################

echo "[+] Instalando dependencias..."

apt install -y \
    p7zip-full \
    libguestfs-tools \

#############################################
# Datos entrada
#############################################

read -rp "URL Mirror de la maquina: " URL

read -rp "Almacenamiento Proxmox [ej: local-lvm, ssd-vms]: " STORAGE

if [ -z "$STORAGE" ]; then
    echo "ERROR: almacenamiento vacío"
    exit 1
fi


read -rp "Bridge red [ej: vmbr0]: " BRIDGE

if [ -z "$BRIDGE" ]; then
    echo "ERROR: bridge vacío"
    exit 1
fi


VMID=$(pvesh get /cluster/nextid)

ARCHIVE_FILE=$(basename "$URL")

VMNAME="${ARCHIVE_FILE%%.*}"


echo
echo "================================"
echo " VMID          : $VMID"
echo " Nombre        : $VMNAME"
echo " Storage       : $STORAGE"
echo " Bridge        : $BRIDGE"
echo "================================"
echo



#############################################
# Descargar
#############################################

echo "[1/10] Descargando..."

wget -O "$ARCHIVE_FILE" "$URL"



#############################################
# Extraer
#############################################

echo "[2/10] Extrayendo..."

7z x "$ARCHIVE_FILE" -y



#############################################
# Buscar disco
#############################################

echo "[3/10] Buscando disco..."

DISK=$(find . \
    -type f \
    \( \
    -iname "*.vmdk" \
    -o -iname "*.qcow2" \
    -o -iname "*.raw" \
    -o -iname "*.img" \
    \) \
    | head -n1)


if [ -z "$DISK" ]; then
    echo "ERROR: No se encontró disco"
    exit 1
fi


DISK=$(basename "$DISK")

echo "Disco encontrado: $DISK"



#############################################
# Convertir a QCOW2
#############################################

echo "[4/10] Preparando QCOW2..."

EXT="${DISK##*.}"

EXT=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')


if [ "$EXT" = "qcow2" ]; then

    cp "$DISK" "${VMNAME}.qcow2"

else

    qemu-img convert \
        -p \
        -f "$EXT" \
        -O qcow2 \
        "$DISK" \
        "${VMNAME}.qcow2"

fi



#############################################
# GRUB
#############################################

echo "[5/10] Configurando GRUB..."

virt-customize \
    -a "${VMNAME}.qcow2" \
    --edit '/etc/default/grub:s/quiet/quiet net.ifnames=0 biosdevname=0/' \
    --run-command "update-grub"



#############################################
# Red
#############################################

echo "[6/10] Configurando eth0 DHCP..."

virt-customize \
    -a "${VMNAME}.qcow2" \
    --run-command \
"printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > /etc/network/interfaces"



#############################################
# Verificación
#############################################

echo "[+] Verificando interfaces..."

virt-cat \
    -a "${VMNAME}.qcow2" \
    /etc/network/interfaces



#############################################
# Crear VM
#############################################

echo "[7/10] Creando VM..."

qm create "$VMID" \
    --name "$VMNAME" \
    --memory 1024 \
    --cores 1 \
    --bios seabios \
    --machine pc \
    --net0 e1000,bridge="$BRIDGE"



#############################################
# Importar disco
#############################################

echo "[8/10] Importando disco..."

qm importdisk \
    "$VMID" \
    "${VMNAME}.qcow2" \
    "$STORAGE"



#############################################
# Obtener disco importado
#############################################

DISK_REF=$(qm config "$VMID" | awk '/unused/ {print $2}')


if [ -z "$DISK_REF" ]; then
    echo "ERROR: No se encontró disco importado"
    exit 1
fi


echo "Disco importado: $DISK_REF"



#############################################
# SATA + BOOT
#############################################

echo "[9/10] Asociando SATA..."

qm set "$VMID" \
    --sata0 "$DISK_REF" \
    --boot order=sata0



#############################################
# Forzar e1000
#############################################

qm set "$VMID" \
    --net0 e1000,bridge="$BRIDGE"



#############################################
# Limpieza
#############################################

echo "[10/10] Limpiando..."

rm -f "$ARCHIVE_FILE"
rm -f "${VMNAME}.qcow2"


find . \
    -type f \
    \( \
    -iname "*.vmdk" \
    -o -iname "*.ovf" \
    -o -iname "*.mf" \
    -o -iname "*.cert" \
    -o -iname "*.qcow2" \
    -o -iname "*.raw" \
    -o -iname "*.img" \
    \) \
    -delete


find . -type d -empty -delete



#############################################
# Final
#############################################

echo
echo "================================"
echo " IMPORTACION COMPLETADA"
echo "================================"
echo
echo "VMID : $VMID"
echo "NAME : $VMNAME"
echo
echo "Arrancar:"
echo
echo "qm start $VMID"
echo
