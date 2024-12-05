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

    # Detectar el tipo de almacenamiento y aplicar `chown` solo si es de tipo directorio
    STORAGE_TYPE=$(pct config "$CONTAINER_ID" | grep "^rootfs:" | awk -F, '{print $2}' | cut -d'=' -f2)
    if [[ "$STORAGE_TYPE" == "dir" ]]; then
        STORAGE_PATH=$(pct config "$CONTAINER_ID" | grep "^rootfs:" | awk '{print $2}' | cut -d',' -f1)
        echo "Aplicando permisos root en el almacenamiento de tipo directorio..."
        chown -R root:root "$STORAGE_PATH"
    else
        echo "El contenedor usa almacenamiento de tipo LVM, no se requiere cambio de permisos."
    fi
else
    echo "El contenedor ya es privilegiado."
fi

# Añadir configuración de iGPU si se selecciona la opción 1 o 2
if [[ "$OPTION" == "1" || "$OPTION" == "2" ]]; then
    if [[ -e /dev/dri/renderD128 ]]; then
        echo "Configurando iGPU para el contenedor..."

        # Configurar iGPU en el archivo de configuración del contenedor
        if ! grep -q "cgroup2.devices.allow: c 226" "$CONFIG_FILE"; then
            cat <<EOF >> "$CONFIG_FILE"
features: nesting=1
lxc.cgroup2.devices.allow: c 226:0 rwm # iGPU
lxc.cgroup2.devices.allow: c 226:128 rwm # iGPU
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
            echo "iGPU añadida al contenedor $CONTAINER_ID."
        else
            echo "La iGPU ya está configurada en el contenedor."
        fi
    else
        echo "Error: No se detectó una iGPU en el sistema."
        [[ "$OPTION" == "1" ]] && exit 1
    fi
fi

# Añadir configuración de Coral TPU si se selecciona la opción 2
if [[ "$OPTION" == "2" ]]; then
    echo "Configurando Coral TPU para el contenedor..."

    # Detectar Coral TPU
    CORAL_USB=$(lsusb | grep -i "Global Unichip")
    CORAL_M2=$(lspci | grep -i "Global Unichip")

    if [[ -n "$CORAL_USB" ]]; then
        cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 189:* rwm # Coral USB
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
EOF
        echo "TPU Coral (USB) añadido al contenedor $CONTAINER_ID."
    fi

    if [[ -n "$CORAL_M2" ]]; then
        cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 29:0 rwm # Coral M.2
lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file
EOF
        echo "TPU Coral (M.2) añadido al contenedor $CONTAINER_ID."
    fi

    if [[ -z "$CORAL_USB" && -z "$CORAL_M2" ]]; then
        echo "Error: No se detectó ningún dispositivo Coral TPU. Verifica la conexión del dispositivo."
        exit 1
    fi

    # Instalar controladores en el contenedor
    echo "Instalando controladores de Coral TPU dentro del contenedor..."
    pct start "$CONTAINER_ID"
    pct exec "$CONTAINER_ID" -- bash -c "
    apt-get update
    apt-get install -y gnupg
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/coral-edgetpu.gpg
    echo 'deb [signed-by=/usr/share/keyrings/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main' | tee /etc/apt/sources.list.d/coral-edgetpu.list
    apt-get update
    apt-get install -y libedgetpu1-std
    " && echo "Controladores de Coral TPU instalados correctamente."
fi

# Iniciar el contenedor si estaba apagado
if [[ "$(pct status "$CONTAINER_ID" | awk '{print $2}')" != "running" ]]; then
    echo "Iniciando el contenedor con la configuración actualizada..."
    pct start "$CONTAINER_ID"
fi
