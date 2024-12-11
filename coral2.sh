#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

NEED_REBOOT=false

# Verificar y configurar repositorios
verify_and_add_repos() {
    log "Verificando y configurando repositorios necesarios..."
    # Repositorio Proxmox "No Subscription"
    if ! grep -q "pve-no-subscription" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "deb http://download.proxmox.com/debian/pve $(lsb_release -sc) pve-no-subscription" | tee /etc/apt/sources.list.d/pve-no-subscription.list
    fi
    # Repositorios Debian con firmware no libre
    if ! grep -q "non-free-firmware" /etc/apt/sources.list; then
        echo "deb http://deb.debian.org/debian $(lsb_release -sc) main contrib non-free-firmware
deb http://deb.debian.org/debian $(lsb_release -sc)-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $(lsb_release -sc)-security main contrib non-free-firmware" | tee -a /etc/apt/sources.list
    fi
    apt-get update && log "Repositorios configurados correctamente."
}

# Verificar si se requieren repositorios adicionales y añadirlos
add_coral_repos() {
    log "Verificando repositorios de Coral TPU..."
    if ! grep -q "coral-edgetpu-stable" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" | tee /etc/apt/sources.list.d/coral-edgetpu.list
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/coral-edgetpu.gpg
        apt-get update
        log "Repositorio de Coral añadido correctamente."
    else
        log "Repositorio de Coral ya está configurado."
    fi
}

# Configurar LXC para iGPU
configure_lxc_for_igpu() {
    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 226:/d' "$CONFIG_FILE"
    sed -i '/^lxc\.mount\.entry: \/dev\/dri/d' "$CONFIG_FILE"

    cat <<EOF >> "$CONFIG_FILE"
features: nesting=1
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
    log "Configuración para iGPU añadida al contenedor ${CONTAINER_ID}."
}

# Configurar LXC para NVIDIA
configure_lxc_for_nvidia() {
    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
    log "Obteniendo dispositivos NVIDIA..."
    NV_DEVICES=$(ls -l /dev/nv* | awk '{print $5,$6}' | sed 's/,/:/g')

    # Limpiar configuraciones previas relacionadas con NVIDIA
    sed -i '/^lxc\.cgroup2\.devices\.allow: c /d' "$CONFIG_FILE"
    sed -i '/^lxc\.mount\.entry: \/dev\/nvidia/d' "$CONFIG_FILE"

    # Añadir configuraciones dinámicas basadas en los dispositivos detectados
    for DEV in $NV_DEVICES; do
        echo "lxc.cgroup2.devices.allow: c $DEV rwm" >> "$CONFIG_FILE"
    done

    cat <<EOF >> "$CONFIG_FILE"
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
EOF

    log "Configuración para NVIDIA añadida al contenedor ${CONTAINER_ID}."
}

# Configurar LXC para Coral TPU
configure_lxc_for_coral() {
    add_coral_repos
    log "Configurando Coral TPU para el contenedor..."
    if lsusb | grep -i "Global Unichip" &>/dev/null || lspci | grep -i "Global Unichip" &>/dev/null; then
        if lsusb | grep -i "Global Unichip" &>/dev/null; then
            log "Configurando Coral USB..."
            cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
EOF
        fi
        if lspci | grep -i "Global Unichip" &>/dev/null; then
            log "Configurando Coral M.2/PCI..."
            cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 29:0 rwm
lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file
EOF
        fi
    else
        log "No se detectó hardware Coral TPU conectado."
        read -p "¿Deseas instalar soporte para Coral USB y M.2/PCI de todas formas? (s/n): " RESPUESTA
        if [[ "$RESPUESTA" =~ ^[Ss]$ ]]; then
            log "Instalando soporte para Coral TPU..."
            cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 29:0 rwm
lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file
EOF
        else
            log "Operación cancelada por el usuario."
            return
        fi
    fi
    log "Configuración para Coral añadida al contenedor ${CONTAINER_ID}."
}

# Seleccionar el contenedor mediante dialog
select_container_id() {
    local CONTAINERS=($(pct list | awk 'NR>1 {print $1}'))
    local CONTAINER_NAMES=($(pct list | awk 'NR>1 {print $3}'))
    local MENU_OPTIONS=()

    for i in "${!CONTAINERS[@]}"; do
        MENU_OPTIONS+=("${CONTAINERS[$i]}" "${CONTAINER_NAMES[$i]}")
    done

    CONTAINER_ID=$(dialog --clear --title "Seleccionar contenedor LXC" \
        --menu "Selecciona un contenedor:" 15 50 10 \
        "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

    if [[ -z "$CONTAINER_ID" ]]; then
        log "No se seleccionó ningún contenedor."
        exit 1
    fi
    log "Contenedor seleccionado: $CONTAINER_ID"
}

# Selección interactiva de opciones mediante dialog
select_option() {
    local OPTIONS=(
        "1" "Añadir aceleración gráfica iGPU"
        "2" "Añadir aceleración gráfica NVIDIA"
        "3" "Añadir Coral TPU (incluye GPU si está disponible)"
    )

    OPTION=$(dialog --clear --title "Opciones de configuración" \
        --menu "Selecciona una opción:" 15 50 10 \
        "${OPTIONS[@]}" 3>&1 1>&2 2>&3)

    if [[ -z "$OPTION" ]]; then
        log "No se seleccionó ninguna opción."
        exit 1
    fi
    echo "$OPTION"
}

select_coral_option() {
    local CORAL_OPTIONS=(
        "1" "Coral + iGPU"
        "2" "Coral + NVIDIA"
    )

    CORAL_OPTION=$(dialog --clear --title "Opciones de Coral TPU" \
        --menu "Selecciona una opción para Coral TPU:" 15 50 10 \
        "${CORAL_OPTIONS[@]}" 3>&1 1>&2 2>&3)

    if [[ -z "$CORAL_OPTION" ]]; then
        log "No se seleccionó ninguna opción para Coral TPU."
        exit 1
    fi
    echo "$CORAL_OPTION"
}

install_nvidia_drivers() {
    log "Instalando controladores NVIDIA en el host Proxmox..."
    verify_and_add_repos
    apt update && apt dist-upgrade -y
    apt install -y git pve-headers-$(uname -r) gcc make || {
        log "Error al instalar dependencias necesarias. Abortando instalación."
        exit 1
    }

    log "Seleccionando y descargando controlador NVIDIA..."
    local DRIVER_VERSION=$(dialog --inputbox "Introduce la versión del controlador NVIDIA o deja en blanco para la última versión:" 10 50 "" 3>&1 1>&2 2>&3)

    if [[ -z "$DRIVER_VERSION" ]]; then
        DRIVER_VERSION=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt)
    fi

    NVIDIA_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/$DRIVER_VERSION/NVIDIA-Linux-x86_64-$DRIVER_VERSION.run"

    mkdir -p /opt/nvidia
    cd /opt/nvidia
    wget "$NVIDIA_DRIVER_URL" -O NVIDIA-Driver.run
    chmod +x NVIDIA-Driver.run

    ./NVIDIA-Driver.run --no-questions --ui=none --disable-nouveau || {
        log "Error al instalar el controlador NVIDIA."
        exit 1
    }
    log "Controladores NVIDIA instalados."
    NEED_REBOOT=true
}

PS3="Selecciona una opción: "
OPTION=$(select_option)

case "$OPTION" in
    1)
        log "Seleccionando contenedor para iGPU..."
        select_container_id
        pct stop "$CONTAINER_ID"
        configure_lxc_for_igpu
        pct start "$CONTAINER_ID"
        ;;
    2)
        install_nvidia_drivers
        log "Seleccionando contenedor para NVIDIA..."
        select_container_id
        pct stop "$CONTAINER_ID"
        configure_lxc_for_nvidia
        pct start "$CONTAINER_ID"
        ;;
    3)
        CORAL_OPTION=$(select_coral_option)
        if [[ "$CORAL_OPTION" == "1" ]]; then
            log "Seleccionando contenedor para Coral + iGPU..."
            select_container_id
            pct stop "$CONTAINER_ID"
            configure_lxc_for_igpu
            configure_lxc_for_coral
            pct start "$CONTAINER_ID"
        elif [[ "$CORAL_OPTION" == "2" ]]; then
            log "Seleccionando contenedor para Coral + NVIDIA..."
            select_container_id
            pct stop "$CONTAINER_ID"
            configure_lxc_for_nvidia
            configure_lxc_for_coral
            pct start "$CONTAINER_ID"
        fi
        ;;
    *)
        log "Opción inválida."
        ;;
esac

if $NEED_REBOOT; then
    dialog --yesno "Es necesario reiniciar para aplicar los cambios. ¿Deseas reiniciar ahora?" 10 50
    if [[ $? -eq 0 ]]; then
        reboot
    else
        log "Por favor, recuerda reiniciar el sistema más tarde."
    fi
fi
