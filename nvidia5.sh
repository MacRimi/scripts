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

reboot_required=false

# 1. Blacklist nouveau
log "Blacklisteando nouveau..."
echo "blacklist nouveau" | tee /etc/modprobe.d/blacklist.conf
update-initramfs -u

# 2. Actualización de paquetes
log "Actualizando repositorios y paquetes..."
apt update && apt dist-upgrade -y
apt install -y git pve-headers-$(uname -r) gcc make wget whiptail

# 3. Obtener lista de drivers NVIDIA
log "Obteniendo lista de drivers NVIDIA..."
driver_list=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ | \
grep -oP "(?<=href=\')[0-9]{3}\.[0-9]{2,}\.[0-9]{2}(?=/)" | sort -Vr | head -n 10)

if [ -z "$driver_list" ]; then
    error "No se pudo obtener la lista de controladores NVIDIA. Verifica tu conexión."
fi

# Obtener la última versión del driver
latest_driver=$(wget -qO- $NVIDIA_DRIVER_URL | grep -Eo '[0-9]{3}\.[0-9]{3}\.[0-9]{2}')
if [ -z "$latest_driver" ]; then
    error "No se pudo obtener la última versión del controlador NVIDIA."
fi

# Crear menú dinámico con whiptail
log "Construyendo menú de selección..."
menu_options=()
menu_options+=("1" "Instalar último driver ($latest_driver)")
count=2

# Añadir drivers a las opciones
while read -r driver; do
    menu_options+=("$count" "$driver")
    count=$((count + 1))
done <<< "$driver_list"

# Mostrar menú
selection=$(whiptail --title "Seleccionar Driver NVIDIA" --menu "Elige una opción:" 20 70 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)

# Validar selección
if [ -z "$selection" ]; then
    error "Selección cancelada por el usuario."
fi

if [ "$selection" -eq 1 ]; then
    selected_driver=$latest_driver
else
    selected_driver=$(echo "$driver_list" | sed -n "$((selection-1))p")
fi

# Descargar e instalar el driver seleccionado
DRIVER_RUN="NVIDIA-Linux-x86_64-$selected_driver.run"
log "Descargando e instalando driver $selected_driver..."
wget -q https://download.nvidia.com/XFree86/Linux-x86_64/$selected_driver/$DRIVER_RUN -O $DRIVER_RUN
chmod +x $DRIVER_RUN
./$DRIVER_RUN --no-questions --ui=none --disable-nouveau || error "Error instalando driver NVIDIA."

log "Proceso completado. Reinicia y vuelve a ejecutar el script si es necesario."
