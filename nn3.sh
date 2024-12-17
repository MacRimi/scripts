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
apt install -y git pve-headers-$(uname -r) gcc make wget whiptail curl

# 5. Obtener lista de drivers NVIDIA
log "Obteniendo lista de drivers NVIDIA..."

# Obtener y validar el HTML
html_output=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/) || error "Error al descargar el HTML de NVIDIA."
if [ -z "$html_output" ]; then
    error "El HTML descargado está vacío. Verifica tu conexión."
fi

log "HTML descargado correctamente. Filtrando lista de drivers..."

# Extraer la lista de drivers
driver_list=$(echo "$html_output" | grep -oP "href='[0-9]+\.[0-9]+\.[0-9]+/'" | awk -F"'" '{print $2}' | sed 's:/$::' | sort -Vr | head -n 10)

# Validar si la lista es correcta
if [ -z "$driver_list" ]; then
    error "No se pudo obtener la lista de controladores NVIDIA."
fi

log "Lista de drivers obtenida:"
echo "$driver_list"

# Obtener el último driver
latest_driver=$(wget -qO- "$NVIDIA_DRIVER_URL" | grep -Eo '[0-9]{3}\.[0-9]{3}\.[0-9]{2}') || error "Error al obtener la última versión del driver."
if [ -z "$latest_driver" ]; then
    error "No se pudo obtener la última versión del controlador NVIDIA."
fi

log "Último driver encontrado: $latest_driver"

# 6. Construir menú de selección
log "Construyendo menú de selección..."
menu_options=("1" "Instalar último driver ($latest_driver)")
count=2
while read -r driver; do
    menu_options+=("$count" "$driver")
    count=$((count + 1))
done <<< "$driver_list"

# Mostrar menú
log "Mostrando menú para seleccionar el driver..."
selection=$(whiptail --title "Seleccionar Driver NVIDIA" --menu "Elige una opción:" 20 70 10 "${menu_options[@]}" 3>&1 1>&2 2>&3 || echo "cancelled")

# Validar selección
if [ "$selection" = "cancelled" ] || [ -z "$selection" ]; then
    error "Selección cancelada por el usuario."
fi

# Determinar driver seleccionado
if [ "$selection" -eq 1 ]; then
    selected_driver=$latest_driver
else
    selected_driver=$(echo "$driver_list" | sed -n "$((selection-1))p")
fi

log "Driver seleccionado: $selected_driver"

# Simulación de instalación del driver
log "Descargar e instalar driver $selected_driver aquí..."

# Descargar el driver
mkdir -p "$DRIVER_DIR" && cd "$DRIVER_DIR"
DRIVER_RUN="NVIDIA-Linux-x86_64-$selected_driver.run"
wget -q "https://download.nvidia.com/XFree86/Linux-x86_64/$selected_driver/$DRIVER_RUN" -O "$DRIVER_RUN" || error "No se pudo descargar el driver."

chmod +x "$DRIVER_RUN"
log "Driver $selected_driver descargado correctamente."

# Mensaje final
log "Proceso completado. El driver $selected_driver está listo para ser instalado."