#!/bin/bash
# Script para obtener lista de drivers NVIDIA

log() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

# Obtener la lista de drivers usando awk
log "Obteniendo lista de drivers NVIDIA..."
driver_list=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ | \
awk -F"'" '/href=/ && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\/$/ {print substr($2, 1, length($2)-1)}' | sort -Vr | head -n 10)

# Mostrar la lista obtenida
if [ -z "$driver_list" ]; then
    error "No se pudo obtener la lista de controladores NVIDIA."
fi

log "Lista de drivers obtenida:"
echo "$driver_list"

# Proceso de menú
menu_options="1 Instalar último driver (latest)"
count=2
for driver in $driver_list; do
    menu_options+="\n$count $driver"
    count=$((count + 1))
done

# Mostrar menú con whiptail
selection=$(whiptail --title "Seleccionar Driver NVIDIA" --menu "Elige una opción:" 20 70 10 $(echo -e "$menu_options") 3>&1 1>&2 2>&3)

if [ -z "$selection" ]; then
    error "Selección cancelada por el usuario."
fi

log "Opción seleccionada: $selection"
