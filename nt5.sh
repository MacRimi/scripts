#!/bin/bash
# Script para obtener lista de drivers NVIDIA con depuración
set -e

log() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

# 1. Obtener contenido de la página
log "Obteniendo el HTML de la página..."
html_content=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/)

if [ -z "$html_content" ]; then
    error "No se pudo conectar a la URL. Verifica tu conexión a Internet."
fi

# 2. Mostrar las primeras líneas del HTML (para depuración)
log "Primeras líneas del HTML:"
echo "$html_content" | head -n 20

# 3. Extraer versiones de drivers usando una combinación simple de grep y awk
log "Filtrando versiones de drivers NVIDIA..."
driver_list=$(echo "$html_content" | grep -oP "href='[0-9]+\.[0-9]+\.[0-9]+/'" | awk -F"'" '{print $2}' | sed 's:/$::' | sort -Vr | head -n 10)

# 4. Validar y mostrar la lista obtenida
if [ -z "$driver_list" ]; then
    error "No se pudo extraer la lista de controladores NVIDIA del HTML."
fi

log "Lista de drivers obtenida:"
echo "$driver_list"

# Fin del script
exit 0
