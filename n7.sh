#!/bin/bash
# Script para instalar drivers NVIDIA en Proxmox y configurarlos para LXC
# Autor: @MacRimi

set -e

# Variables
NVIDIA_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt"
DRIVER_DIR="/opt/nvidia"
RESTART_FILE="/nvidia_install_restart.flag"

# Funciones auxiliares
log() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

# 1. Verificar si se ejecuta como root
if [ "$EUID" -ne 0 ]; then
    error "Este script debe ejecutarse como root."
fi

# 2. Control de reinicio
if [ -f "$RESTART_FILE" ]; then
    log "Reanudando instalación después del reinicio..."
    rm -f "$RESTART_FILE"
    log "Instalación completada después del reinicio. Verifica los drivers instalados."
    exit 0
fi

# 3. Blacklist nouveau
log "Blacklisteando nouveau..."
echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
update-initramfs -u

# 4. Actualización de paquetes
log "Actualizando repositorios y paquetes..."
apt update && apt dist-upgrade -y
apt install -y git pve-headers-$(uname -r) gcc make wget whiptail

# 5. Obtener lista de drivers NVIDIA
log "Obteniendo lista de drivers NVIDIA..."
driver_list=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ | \
grep -oP "href='[0-9]+\.[0-9]+\.[0-9]+/'" | awk -F"'" '{print $2}' | sed 's:/$::' | sort -Vr | head -n 10)

if [ -z "$driver_list" ]; then
    error "No se pudo obtener la lista de controladores NVIDIA."
fi

latest_driver=$(wget -qO- "$NVIDIA_DRIVER_URL" | grep -Eo '[0-9]{3}\.[0-9]{3}\.[0-9]{2}')
if [ -z "$latest_driver" ]; then
    error "No se pudo obtener la última versión del controlador NVIDIA."
fi

# 6. Menú de selección de drivers
log "Construyendo menú de selección..."
menu_options=("1" "Instalar último driver ($latest_driver)")
count=2
while read -r driver; do
    menu_options+=("$count" "$driver")
    count=$((count + 1))
done <<< "$driver_list"

selection=$(whiptail --title "Seleccionar Driver NVIDIA" --menu "Elige una opción:" 20 70 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)

if [ -z "$selection" ]; then
    error "Selección cancelada por el usuario."
fi

if [ "$selection" -eq 1 ]; then
    selected_driver=$latest_driver
else
    selected_driver=$(echo "$driver_list" | sed -n "$((selection-1))p")
fi

# 7. Descargar e instalar el driver seleccionado
log "Descargando e instalando driver $selected_driver..."
mkdir -p "$DRIVER_DIR" && cd "$DRIVER_DIR"
DRIVER_RUN="NVIDIA-Linux-x86_64-$selected_driver.run"
wget -q "https://download.nvidia.com/XFree86/Linux-x86_64/$selected_driver/$DRIVER_RUN" -O "$DRIVER_RUN"

if [ ! -f "$DRIVER_RUN" ]; then
    error "No se pudo descargar el driver NVIDIA."
fi

chmod +x "$DRIVER_RUN"
./"$DRIVER_RUN" --no-questions --ui=none --disable-nouveau || error "Error al instalar el driver NVIDIA."

# 8. Añadir módulos VFIO y NVIDIA
log "Configurando módulos VFIO y NVIDIA..."
cat > /etc/modules-load.d/modules.conf <<EOF
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
nvidia
nvidia_uvm
EOF

# 9. Crear reglas udev para NVIDIA
log "Creando reglas udev para NVIDIA..."
cat > /etc/udev/rules.d/70-nvidia.rules <<EOF
KERNEL=="nvidia", RUN+="/bin/bash -c '/usr/bin/nvidia-smi -L'"
KERNEL=="nvidia_uvm", RUN+="/bin/bash -c '/usr/bin/nvidia-modprobe -c0 -u'"
EOF

# 10. Instalar NVIDIA Persistence Daemon
log "Instalando NVIDIA Persistence Daemon..."
cd "$DRIVER_DIR"
git clone https://github.com/NVIDIA/nvidia-persistenced.git
cd nvidia-persistenced/init
./install.sh || error "Error al instalar NVIDIA Persistence Daemon."

# 11. Parchear controladores NVIDIA
log "Aplicando parche a los controladores NVIDIA..."
cd "$DRIVER_DIR"
git clone https://github.com/keylase/nvidia-patch.git
cd nvidia-patch
./patch.sh || error "Error al aplicar el parche a los controladores NVIDIA."

# 12. Reinicio requerido
log "Instalación completada. Reiniciando el sistema..."
touch "$RESTART_FILE"
reboot
