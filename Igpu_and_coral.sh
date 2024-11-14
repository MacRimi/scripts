#!/bin/bash

# Listar contenedores LXC disponibles
echo "Selecciona el contenedor LXC al que deseas añadir recursos:"
pct list | awk 'NR>1 {print $1 " - " $3}'  # Lista contenedores con ID y nombre
read -p "Introduce el ID del contenedor: " CONTAINER_ID

# Verificar si el contenedor existe
if ! pct status "$CONTAINER_ID" &>/dev/null; then
    echo "Error: No se encontró el contenedor con ID $CONTAINER_ID"
    exit 1
fi

# Menú de selección de recursos
echo "Selecciona los recursos a añadir al contenedor:"
echo "1. Añadir aceleración gráfica iGPU"
echo "2. Añadir Coral TPU (incluye iGPU si está disponible)"
read -p "Introduce el número de la opción (1 o 2): " OPTION

# Verificación de entrada válida
if [[ "$OPTION" != "1" && "$OPTION" != "2" ]]; then
    echo "Opción no válida. Saliendo."
    exit 1
fi

# Apagar el contenedor antes de realizar cambios
echo "Apagando el contenedor LXC..."
pct stop "$CONTAINER_ID"

# Verificar si el contenedor es no privilegiado y modificarlo si es necesario
CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
if grep -q "^unprivileged: 1" "$CONFIG_FILE"; then
    echo "El contenedor es no privilegiado. Cambiando a privilegiado..."
    sed -i "s/^unprivileged: 1/unprivileged: 0/" "$CONFIG_FILE"
    chown -R root:root "/rpool/data/subvol-${CONTAINER_ID}/"  # Cambia la ruta según tu configuración
else
    echo "El contenedor ya es privilegiado."
fi

# Comprobar si la iGPU está disponible
IGPU_AVAILABLE=false
if ls /dev/dri/renderD128 &>/dev/null; then
    IGPU_AVAILABLE=true
    echo "iGPU detectada. Se añadirá la configuración de iGPU al contenedor."
else
    echo "No se detectó iGPU."
fi

# Añadir configuración de iGPU si se selecciona la opción 1 o 2
if [[ "$OPTION" == "1" || "$OPTION" == "2" ]]; then
    if $IGPU_AVAILABLE; then
        echo "Configurando iGPU para el contenedor..."

        # Configurar iGPU en el archivo de configuración del contenedor
        if ! grep -q "cgroup2.devices.allow: c 226" "$CONFIG_FILE"; then
 cat <<EOF >> "$CONFIG_FILE"
features: nesting=1
lxc.cgroup2.devices.allow: c 226:0 rwm #igpu
lxc.cgroup2.devices.allow: c 226:128 rwm #igpu
lxc.cgroup2.devices.allow: c 29:0 rwm
lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF

            echo "iGPU añadida al contenedor $CONTAINER_ID."
        else
            echo "La iGPU ya está configurada en el contenedor."
        fi
    else
        # Si se seleccionó solo la iGPU (opción 1) y no está disponible, detener el script
        if [[ "$OPTION" == "1" ]]; then
            echo "Error: Se seleccionó iGPU, pero no se detectó una iGPU en el sistema."
            echo "Instalación cancelada."
            exit 1
        fi
    fi
fi

# Añadir configuración de Coral TPU si se selecciona la opción 2
if [[ "$OPTION" == "2" ]]; then
    echo "Configurando Coral TPU para el contenedor..."

    # Comprobar tipo de Coral TPU
    CORAL_USB_AVAILABLE=false
    CORAL_M2_AVAILABLE=false

    if lsusb | grep -i "Global Unichip" &>/dev/null; then
        CORAL_USB_AVAILABLE=true
        echo "TPU Coral (USB) detectado."
    fi

    if lspci | grep -i "Global Unichip" &>/dev/null; then
        CORAL_M2_AVAILABLE=true
        echo "TPU Coral (M.2) detectado."
    fi

    # Configurar Coral TPU según el tipo
    if $CORAL_USB_AVAILABLE; then
        cat <<EOL >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 189:* rwm #coral USB
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
EOL
        echo "Coral TPU (USB) añadido al contenedor $CONTAINER_ID."
    fi

    if $CORAL_M2_AVAILABLE; then
        cat <<EOL >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 29:0 rwm #coral M.2
lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file 0, 0 #coral M.2
EOL
        echo "Coral TPU (M.2) añadido al contenedor $CONTAINER_ID."
    fi

    # Verificar que al menos un tipo de Coral TPU esté disponible
    if ! $CORAL_USB_AVAILABLE && ! $CORAL_M2_AVAILABLE; then
        echo "Advertencia: No se detectó ningún dispositivo Coral TPU. Verifica la conexión del dispositivo."
    fi
fi

# Instalar controladores de Coral TPU dentro del contenedor si se seleccionó la opción 2
if [[ "$OPTION" == "2" ]]; then
    echo "Instalando controladores de Coral TPU en el contenedor LXC..."

    # Ejecutar comandos dentro del contenedor para añadir repositorio e instalar el driver
    pct exec "$CONTAINER_ID" -- bash -c "
    echo 'deb https://packages.cloud.google.com/apt coral-edgetpu-stable main' | tee /etc/apt/sources.list.d/coral-edgetpu.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    apt-get update
    apt-get install -y libedgetpu1-std
    "
    echo "Instalación de drivers de Coral TPU en el contenedor LXC completada."
fi

# Iniciar el contenedor LXC
echo "Iniciando el contenedor LXC con la configuración actualizada."
pct start "$CONTAINER_ID"
