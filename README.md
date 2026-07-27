# Importador de maquinas de Vulnhub en Proxmox

Script automatizado en Bash para Proxmox VE que permite descargar, descomprimir, convertir, personalizar e importar cualquier máquina virtual empaquetada directamente a Proxmox.

## Características

* **Extracción Universal:** Detecta y extrae automáticamente cualquier formato de compresión mediante `7z`.
* **Búsqueda Inteligente:** Localiza el disco virtual (`.vmdk`, `.qcow2`, `.raw`, `.img`) sin importar la estructura de directorios resultante.
* **Conversión Automática:** Convierte cualquier formato de disco compatible a `QCOW2` de forma optimizada.
* **Personalización de Red:** Reescribe el archivo `/etc/network/interfaces` configurando automáticamente la interfaz `eth0` por **DHCP**.
* **Configuración de GRUB:** Ajusta las opciones del kernel para asegurar nombres de red tradicionales (`net.ifnames=0 biosdevname=0`).
* **Soporte de Almacenamiento Dinámico:** Compatible tanto con almacenamientos tipo LVM/ZFS como con directorios estándar (capturando automáticamente la ruta generada por `qm importdisk`).
* **Limpieza Automática:** Borra los archivos temporales y la basura descargada al finalizar el proceso.

## Requisitos Previos

El script instalará automáticamente las dependencias necesarias (`wget`, `p7zip-full`, `qemu-utils`, `libguestfs-tools`), pero asegúrate de ejecutarlo como `root` en un nodo de Proxmox VE.

## Uso

1. Clona el repositorio o descarga el script:

  ```bash
  git clone https://github.com/R3leant/vulnhub2proxmox
  cd vulnhub2proxmox
  ```
   
2. Dale permisos de ejecucion:

  ```bash
  chmod +x vulnhub2proxmox.sh
  ```

3. Ejecutalo y rellena los datos que te pide:

  ```bash
  ./vulnhub2proxmox
  ```
