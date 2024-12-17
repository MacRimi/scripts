#!/bin/bash
# Script para instalar drivers NVIDIA en Proxmox
set -e

log() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

# Obtener la lista de drivers
log "Obteniendo lista de drivers NVIDIA..."
driver_list=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ | \
grep -oP "href='[0-9]+\.[0-9]+\.[0-9]+/'" | awk -F"'" '{print $2}' | sed 's:/$::' | sort -Vr | head -n 10)

# Verificar la lista obtenida
if [ -z "$driver_list" ]; then
    error "No se pudo obtener la lista de controladores NVIDIA."
fi

log "Lista de drivers obtenida:"
echo "$driver_list"

# Construir opciones del menú para whiptail
log "Construyendo menú de selección..."
menu_options=()
menu_options+=("1" "Instalar último driver (latest)")

count=2
while read -r driver; do
    menu_options+=("$count" "$driver")
    count=$((count + 1))
done <<< "$driver_list"

# Mostrar el menú
selection=$(whiptail --title "Seleccionar Driver NVIDIA" --menu "Elige una opción:" 20 70 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)

# Validar selección
if [ -z "$selection" ]; then
    error "Selección cancelada por el usuario."
fi

# Determinar la opción seleccionada
if [ "$selection" -eq 1 ]; then
    selected_driver="latest"
else
    selected_driver=$(echo "$driver_list" | sed -n "$((selection-1))p")
fi

log "Driver seleccionado: $selected_driver"
exit 0
