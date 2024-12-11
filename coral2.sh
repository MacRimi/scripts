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

# Menú interactivo basado en select
main_menu() {
    log "Mostrando el menú principal."
    PS3="Selecciona una opción: "
    OPTIONS=(
        "Añadir aceleración gráfica iGPU"
        "Añadir aceleración gráfica NVIDIA"
        "Añadir Coral TPU (incluye GPU si está disponible)"
        "Salir"
    )
    select OPTION in "${OPTIONS[@]}"; do
        case "$REPLY" in
            1)
                log "Seleccionando contenedor para iGPU..."
                select_container_id
                pct stop "$CONTAINER_ID"
                configure_lxc_for_igpu
                pct start "$CONTAINER_ID"
                break
                ;;
            2)
                install_nvidia_drivers
                log "Seleccionando contenedor para NVIDIA..."
                select_container_id
                pct stop "$CONTAINER_ID"
                configure_lxc_for_nvidia
                pct start "$CONTAINER_ID"
                break
                ;;
            3)
                coral_menu
                break
                ;;
            4)
                log "Saliendo del script."
                exit 0
                ;;
            *)
                log "Opción inválida. Intenta de nuevo."
                ;;
        esac
    done
}

# Menú para Coral TPU
coral_menu() {
    log "Mostrando el menú de Coral TPU."
    PS3="Selecciona una opción para Coral TPU: "
    OPTIONS=(
        "Coral + iGPU"
        "Coral + NVIDIA"
        "Volver"
    )
    select OPTION in "${OPTIONS[@]}"; do
        case "$REPLY" in
            1)
                log "Seleccionando contenedor para Coral + iGPU..."
                select_container_id
                pct stop "$CONTAINER_ID"
                configure_lxc_for_igpu
                configure_lxc_for_coral
                pct start "$CONTAINER_ID"
                break
                ;;
            2)
                log "Seleccionando contenedor para Coral + NVIDIA..."
                select_container_id
                pct stop "$CONTAINER_ID"
                configure_lxc_for_nvidia
                configure_lxc_for_coral
                pct start "$CONTAINER_ID"
                break
                ;;
            3)
                main_menu
                break
                ;;
            *)
                log "Opción inválida. Intenta de nuevo."
                ;;
        esac
    done
}

# Seleccionar contenedor interactivo
select_container_id() {
    local CONTAINERS=($(pct list | awk 'NR>1 {print $1}'))
    local CONTAINER_NAMES=($(pct list | awk 'NR>1 {print $3}'))
    local MENU_OPTIONS=()

    for i in "${!CONTAINERS[@]}"; do
        MENU_OPTIONS+=("${CONTAINERS[$i]}" "${CONTAINER_NAMES[$i]}")
    done

    echo "Contenedores disponibles:"
    for i in "${!MENU_OPTIONS[@]}"; do
        if (( i % 2 == 0 )); then
            echo "$((i / 2 + 1)). ${MENU_OPTIONS[i + 1]} (ID: ${MENU_OPTIONS[i]})"
        fi
    done

    read -p "Selecciona el número del contenedor: " CONTAINER_SELECTION
    if [[ -n "$CONTAINER_SELECTION" && "$CONTAINER_SELECTION" =~ ^[0-9]+$ ]]; then
        CONTAINER_ID=${CONTAINERS[$CONTAINER_SELECTION-1]}
        if [[ -n "$CONTAINER_ID" ]]; then
            log "Contenedor seleccionado: ${CONTAINER_NAMES[$CONTAINER_SELECTION-1]} (ID: $CONTAINER_ID)"
        else
            log "Error: Selección inválida."
            select_container_id
        fi
    else
        log "Error: Entrada no válida."
        select_container_id
    fi
}

main_menu
