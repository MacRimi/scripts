log "Obteniendo lista de drivers NVIDIA..."

# Comprobar conexión a la URL y contenido
curl_output=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/)

if [ -z "$curl_output" ]; then
    error "No se pudo conectar a la URL. Verifica tu conexión a Internet."
fi

# Extraer la lista de versiones de los drivers
driver_list=$(echo "$curl_output" | grep "href=" | grep -o "[0-9]\{3\}\.[0-9]\{2,\}\.[0-9]\{2\}/" | sed 's:/$::' | sort -Vr | head -n 10)

# Debug: Mostrar la lista para verificar
log "Lista de drivers obtenida:"
echo "$driver_list"

# Validar si la lista está vacía
if [ -z "$driver_list" ]; then
    error "No se pudo obtener la lista de controladores NVIDIA. Verifica la salida de la URL."
fi
