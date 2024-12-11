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

# Seleccionar el contenedor mediante un menú
select_container_id() {
    local CONTAINERS=($(pct list | awk 'NR>1 {print $1}'))
    local CONTAINER_NAMES=($(pct list | awk 'NR>1 {print $3}'))
    echo "Selecciona un contenedor:"
    PS3="Introduce el número correspondiente: "
    select CONTAINER_ID in "${CONTAINERS[@]}"; do
        if [[ -n "$CONTAINER_ID" ]]; then
            echo "Contenedor seleccionado: ${CONTAINER_NAMES[$REPLY-1]} (ID: $CONTAINER_ID)"
            break
        else
            echo "Opción inválida. Intenta de nuevo."
        fi
    done
}

# Función para seleccionar y descargar el controlador NVIDIA
select_and_download_nvidia_driver() {
    log "Obteniendo la lista de controladores NVIDIA..."
    local LATEST_VERSION=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt)
    echo "Última versión estable disponible: $LATEST_VERSION"
    echo "1) Instalar la última versión ($LATEST_VERSION)"
    echo "2) Elegir otra versión manualmente"
    read -p "Selecciona una opción: " DRIVER_OPTION

    if [[ "$DRIVER_OPTION" == "1" ]]; then
        NVIDIA_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/$LATEST_VERSION/NVIDIA-Linux-x86_64-$LATEST_VERSION.run"
    elif [[ "$DRIVER_OPTION" == "2" ]]; then
        echo "Consulta las versiones disponibles aquí: https://download.nvidia.com/XFree86/Linux-x86_64/"
        read -p "Introduce el número de versión deseado (e.g., 525.116.03): " SELECTED_VERSION
        NVIDIA_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/$SELECTED_VERSION/NVIDIA-Linux-x86_64-$SELECTED_VERSION.run"
    else
        log "Opción inválida. Cancelando instalación."
        exit 1
    fi

    log "Descargando controlador NVIDIA desde $NVIDIA_DRIVER_URL..."
    mkdir -p /opt/nvidia
    cd /opt/nvidia
    wget $NVIDIA_DRIVER_URL -O NVIDIA-Driver.run
    chmod +x NVIDIA-Driver.run
    log "Controlador NVIDIA descargado correctamente."
}

install_nvidia_drivers() {
    log "Instalando controladores NVIDIA en el host Proxmox..."
    verify_and_add_repos
    apt update && apt dist-upgrade -y
    apt install -y git pve-headers-$(uname -r) gcc make || {
        log "Error al instalar dependencias necesarias. Abortando instalación."
        exit 1
    }

    select_and_download_nvidia_driver

    ./NVIDIA-Driver.run --no-questions --ui=none --disable-nouveau || {
        log "Error al instalar el controlador NVIDIA."
        exit 1
    }
    log "Controladores NVIDIA instalados."
    NEED_REBOOT=true
}

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

configure_lxc_for_coral() {
    add_coral_repos
    log "Configurando Coral TPU para el contenedor..."
    if lsusb | grep -i "Global Unichip" &>/dev/null || lspci | grep -i "Global Unichip" &>/dev/null; then
        if lsusb | grep -i "Global Unichip" &>/dev/null; then
            install_usb_driver
        fi
        if lspci | grep -i "Global Unichip" &>/dev/null; then
            install_pci_driver
        fi
    else
        log "No se detectó hardware Coral TPU conectado."
        read -p "¿Deseas instalar soporte para Coral USB y M.2/PCI de todas formas? (s/n): " RESPUESTA
        if [[ "$RESPUESTA" =~ ^[Ss]$ ]]; then
            install_usb_driver
            install_pci_driver
            log "Soporte para Coral USB y M.2 instalado."
        else
            log "Operación cancelada por el usuario."
            return
        fi
    fi
    cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 29:0 rwm
lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file
EOF
    log "Configuración para Coral añadida al contenedor ${CONTAINER_ID}."
}

PS3="Selecciona una opción: "
OPTIONS=("Añadir aceleración gráfica iGPU" "Añadir aceleración gráfica NVIDIA" "Añadir Coral TPU (incluye GPU si está disponible)")
select OPTION in "${OPTIONS[@]}"; do
    case $REPLY in
        1)
            echo "Selecciona el contenedor para iGPU:"
            select_container_id
            pct stop "$CONTAINER_ID"
            configure_lxc_for_igpu
            pct start "$CONTAINER_ID"
            ;;
        2)
            install_nvidia_drivers
            echo "Selecciona el contenedor para NVIDIA:"
            select_container_id
            pct stop "$CONTAINER_ID"
            configure_lxc_for_nvidia
            pct start "$CONTAINER_ID"
            ;;
        3)
            echo "Selecciona una opción para Coral TPU:"
            CORAL_OPTIONS=("Coral + iGPU" "Coral + NVIDIA")
            select CORAL_OPTION in "${CORAL_OPTIONS[@]}"; do
                case $REPLY in
                    1)
                        echo "Selecciona el contenedor para Coral + iGPU:"
                        select_container_id
                        pct stop "$CONTAINER_ID"
                        configure_lxc_for_igpu
                        configure_lxc_for_coral
                        pct start "$CONTAINER_ID"
                        break
                        ;;
                    2)
                        echo "Selecciona el contenedor para Coral + NVIDIA:"
                        select_container_id
                        pct stop "$CONTAINER_ID"
                        configure_lxc_for_nvidia
                        configure_lxc_for_coral
                        pct start "$CONTAINER_ID"
                        break
                        ;;
                    *)
                        echo "Opción inválida. Intenta de nuevo."
                        ;;
                esac
            done
            ;;
        *)
            echo "Opción inválida. Intenta de nuevo."
            ;;
    esac
    break

done

if $NEED_REBOOT; then
    read -p "Es necesario reiniciar el sistema para aplicar los cambios. ¿Deseas reiniciar ahora? (s/n): " RESPUESTA
    if [[ "$RESPUESTA" =~ ^[Ss]$ ]]; then
        reboot
    else
        echo "Por favor, recuerda reiniciar el sistema más tarde."
    fi
fi
