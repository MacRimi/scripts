#!/bin/bash
# Script para instalar drivers NVIDIA en Proxmox
set -e

# Funciones auxiliares
log() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

# Variables
NVIDIA_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt"
DRIVER_DIR="/opt/nvidia"
latest_driver=""
driver_list=""

# Obtener la lista de drivers
log "Obteniendo lista de drivers NVIDIA..."
driver_list=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ | \
grep -oP "(?<=href=\')[0-9]{3}\.[0-9]{2,}\.[0-9]{2}(?=/)" | sort -Vr | head -n 10)

if [ -z "$driver_list" ]; then
    error "No se pudo obtener la lista de controladores NVIDIA."
fi

# Obtener el último driver
latest_driver=$(wget -qO- $NVIDIA_DRIVER_URL | grep -Eo '[0-9]{3}\.[0-9]{3}\.[0-9]{2}')
if [ -z "$latest_driver" ]; then
    error "No se pudo obtener la última versión del controlador NVIDIA."
fi

# Construir opciones del menú en una línea
menu_options=("1" "Instalar último driver ($latest_driver)")
count=2
while read -r driver; do
    menu_options+=("$count" "$driver")
    count=$((count + 1))
done <<< "$driver_list"

# Mostrar el menú con whiptail
log "Mostrando el menú de selección..."
selection=$(whiptail --title "Seleccionar Driver NVIDIA" --menu "Elige una opción:" 20 70 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)

# Validar selección
if [ -z "$selection" ]; then
    error "Selección cancelada por el usuario."
fi

# Determinar el driver seleccionado
if [ "$selection" -eq 1 ]; then
    selected_driver=$latest_driver
else
    selected_driver=$(echo "$driver_list" | sed -n "$((selection-1))p")
fi

# Descargar e instalar el driver seleccionado
log "Descargando e instalando driver $selected_driver..."
mkdir -p $DRIVER_DIR && cd $DRIVER_DIR
DRIVER_RUN="NVIDIA-Linux-x86_64-$selected_driver.run"
wget -q https://download.nvidia.com/XFree86/Linux-x86_64/$selected_driver/$DRIVER_RUN -O $DRIVER_RUN
chmod +x $DRIVER_RUN
./$DRIVER_RUN --no-questions --ui=none --disable-nouveau || error "Error al instalar el driver NVIDIA."

log "Driver $selected_driver instalado correctamente. Reinicia el sistema si es necesario."
exit 0
