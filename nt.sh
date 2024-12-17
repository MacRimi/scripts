#!/bin/bash
# Script para instalar drivers NVIDIA en Proxmox
set -e

log() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

# Obtener lista de drivers
log "Obteniendo lista de drivers NVIDIA..."
driver_list=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ | grep -oP "(?<=href=\')[0-9]{3}\.[0-9]{2,}\.[0-9]{2}(?=/)" | sort -Vr | head -n 10)

# Mostrar lista para depuración
log "Lista de drivers obtenida:"
echo "$driver_list"

if [ -z "$driver_list" ]; then
    error "No se pudo obtener la lista de controladores NVIDIA."
fi

# Crear menú manualmente (sin whiptail por ahora)
log "Creando menú de selección..."
count=2
menu_options="1 Instalar último driver (latest)\n"
while read -r driver; do
    menu_options+="$count $driver\n"
    count=$((count+1))
done <<< "$driver_list"

# Mostrar menú manual
echo -e "Opciones disponibles:"
echo -e "$menu_options"
