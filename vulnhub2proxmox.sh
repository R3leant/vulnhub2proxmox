#!/bin/bash

set -euo pipefail

#############################################
# Dependencias
#############################################

echo "[+] Instalando dependencias..."

apt install -y \
    p7zip-full \
    libguestfs-tools

#############################################
# Datos entrada generales
#############################################

read -rp "URL Mirror de la maquina: " URL

read -rp "Almacenamiento Proxmox [ej: local-lvm, ssd-vms]: " STORAGE

if [ -z "$STORAGE" ]; then
    echo "ERROR: almacenamiento vacío"
    exit 1
fi

VMID=$(pvesh get /cluster/nextid)

ARCHIVE_FILE=$(basename "$URL")

VMNAME="${ARCHIVE_FILE%%.*}"

#############################################
# Bucle de Interfaces de Red (Multi-NIC)
#############################################

declare -a NET_CONFIGS=()
declare -a NET_QEMU_PARAMS=()
NET_INDEX=0
AGREGAR_OTRA="s"

echo
echo "--- CONFIGURACIÓN DE REDES ---"

while [[ "$AGREGAR_OTRA" =~ ^[Ss]$ ]]; do
    echo
    echo "Configurando red para la interfaz eth${NET_INDEX}..."
    
    read -rp " Bridge para eth${NET_INDEX} [ej: vmbr0]: " BRIDGE
    if [ -z "$BRIDGE" ]; then
        echo "ERROR: bridge vacío"
        exit 1
    fi

    echo " Tipo de IP para eth${NET_INDEX}:"
    select TIPO_IP in "DHCP" "Estatica"; do
        case $TIPO_IP in
            DHCP )
                NET_CONFIGS+=("dhcp:${NET_INDEX}")
                QEMU_NET="net${NET_INDEX}=e1000,bridge=${BRIDGE}"
                break
                ;;
            Estatica )
                read -rp " IP estática [ej: 10.0.1.50/24]: " STATIC_IP
                read -rp " Puerta de enlace (Gateway) [ej: 10.0.1.254] (dejar en blanco si no lleva): " GATEWAY
                
                NET_CONFIGS+=("static:${NET_INDEX}:${STATIC_IP}:${GATEWAY}")
                QEMU_NET="net${NET_INDEX}=e1000,bridge=${BRIDGE}"
                break
                ;;
            * ) 
                echo "Opción no válida. Selecciona 1 o 2." 
                ;;
        esac
    done

    NET_QEMU_PARAMS+=("$QEMU_NET")
    NET_INDEX=$((NET_INDEX + 1))

    read -rp "¿Quieres añadir otra interfaz de red? (S/n): " AGREGAR_OTRA
    AGREGAR_OTRA=${AGREGAR_OTRA:-s}
done

echo
echo "================================"
echo " VMID          : $VMID"
echo " Nombre        : $VMNAME"
echo " Storage       : $STORAGE"
echo " Total NICs    : $NET_INDEX"
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
# Buscar disco (RECURSIVO)
#############################################

echo "[3/10] Buscando disco de manera recursiva..."

DISK_PATH=$(find . \
    -type f \
    \( \
    -iname "*.vmdk" \
    -o -iname "*.qcow2" \
    -o -iname "*.raw" \
    -o -iname "*.img" \
    \) \
    | head -n1)

if [ -z "$DISK_PATH" ]; then
    echo "ERROR: No se encontró disco"
    exit 1
fi

echo "Disco encontrado en: $DISK_PATH"

#############################################
# Convertir a QCOW2
#############################################

echo "[4/10] Preparando QCOW2..."

EXT="${DISK_PATH##*.}"
EXT=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')

if [ "$EXT" = "qcow2" ]; then
    cp "$DISK_PATH" "${VMNAME}.qcow2"
else
    qemu-img convert \
        -p \
        -f "$EXT" \
        -O qcow2 \
        "$DISK_PATH" \
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
# Detección Inteligente y Vista Previa de Red
#############################################

echo "[6/10] Analizando sistema de red y generando vista previa..."

NETPLAN_EXISTS=$(virt-ls -a "${VMNAME}.qcow2" /etc 2>/dev/null | grep -w "netplan" || true)

if [ -n "$NETPLAN_EXISTS" ]; then
    CONFIG_TYPE="Netplan (/etc/netplan/01-netcfg-custom.yaml)"
    CONFIG_CONTENT="network:\n  version: 2\n  ethernets:\n"
    
    for conf in "${NET_CONFIGS[@]}"; do
        IFS=':' read -r tipo idx ip gw <<< "$conf"
        CONFIG_CONTENT="${CONFIG_CONTENT}    eth${idx}:\n"
        if [ "$tipo" = "dhcp" ]; then
            CONFIG_CONTENT="${CONFIG_CONTENT}      dhcp4: true\n"
        else
            CONFIG_CONTENT="${CONFIG_CONTENT}      dhcp4: no\n"
            CONFIG_CONTENT="${CONFIG_CONTENT}      addresses: [${ip}]\n"
            if [ -n "$gw" ]; then
                CONFIG_CONTENT="${CONFIG_CONTENT}      routes:\n        - to: default\n          via: ${gw}\n"
            fi
        fi
        CONFIG_CONTENT="${CONFIG_CONTENT}      nameservers:\n        addresses: [8.8.8.8]\n"
    done

    TARGET_FILE="/etc/netplan/01-netcfg-custom.yaml"

else
    CONFIG_TYPE="Clásico (/etc/network/interfaces)"
    CONFIG_CONTENT="auto lo\niface lo inet loopback\n\n"
    
    for conf in "${NET_CONFIGS[@]}"; do
        IFS=':' read -r tipo idx ip gw <<< "$conf"
        CONFIG_CONTENT="${CONFIG_CONTENT}auto eth${idx}\n"
        if [ "$tipo" = "dhcp" ]; then
            CONFIG_CONTENT="${CONFIG_CONTENT}iface eth${idx} inet dhcp\n\n"
        else
            CONFIG_CONTENT="${CONFIG_CONTENT}iface eth${idx} inet static\n    address ${ip}\n"
            if [ -n "$gw" ]; then
                CONFIG_CONTENT="${CONFIG_CONTENT}    gateway ${gw}\n"
            fi
            CONFIG_CONTENT="${CONFIG_CONTENT}\n"
        fi
    done

    TARGET_FILE="/etc/network/interfaces"
fi

# MOSTRAR VISTA PREVIA
echo
echo "=================================================="
echo "          VISTA PREVIA DE CONFIGURACIÓN DE RED    "
echo "=================================================="
echo " Sistema detectado : $CONFIG_TYPE"
echo " Archivo destino   : $TARGET_FILE"
echo "--------------------------------------------------"
echo -e "$CONFIG_CONTENT"
echo "=================================================="
echo

read -rp "¿Estás seguro de inyectar esta configuración y continuar? (S/n): " CONFIRMAR
CONFIRMAR=${CONFIRMAR:-s}

if [[ ! "$CONFIRMAR" =~ ^[Ss]$ ]]; then
    echo "Operación cancelada por el usuario."
    exit 0
fi

# Inyectar configuración comprobada
virt-customize \
    -a "${VMNAME}.qcow2" \
    --run-command "printf '${CONFIG_CONTENT}' > ${TARGET_FILE}"

#############################################
# Crear VM con múltiples NICs
#############################################

echo "[7/10] Creando VM..."

CREATE_CMD="qm create $VMID --name $VMNAME --memory 1024 --cores 1 --bios seabios --machine pc"

for qnet in "${NET_QEMU_PARAMS[@]}"; do
    CREATE_CMD="${CREATE_CMD} --${qnet}"
done

eval "$CREATE_CMD"

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
