#!/bin/bash

# Colores para salida
YW="\033[33m"
GN="\033[1;92m"
RD="\033[01;31m"
CL="\033[m"

# Funciones auxiliares
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}
msg_info() {
    echo -ne " ${YW}[INFO] $1...${CL}"
}
msg_ok() {
    echo -e " ${GN}[OK] $1${CL}"
}
msg_error() {
    echo -e " ${RD}[ERROR] $1${CL}"
}

# Selección del contenedor LXC
select_container() {
    CONTAINERS=$(pct list | awk 'NR>1 {print $1, $3}')
    CONTAINER_ID=$(whiptail --title "Seleccionar Contenedor" --menu "Selecciona el contenedor LXC al que deseas añadir recursos:" 15 60 5 $(echo $CONTAINERS | xargs -n2) 3>&1 1>&2 2>&3)

    if [ -z "$CONTAINER_ID" ]; then
        msg_error "No se seleccionó ningún contenedor."
        exit 1
    fi

    if ! pct status "$CONTAINER_ID" &>/dev/null; then
        msg_error "No se encontró el contenedor con ID $CONTAINER_ID."
        exit 1
    fi

    msg_ok "Contenedor seleccionado: $CONTAINER_ID"
}

# Validar y cambiar a privilegiado si es necesario
ensure_privileged_container() {
    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
    if grep -q "^unprivileged: 1" "$CONFIG_FILE"; then
        msg_info "El contenedor es no privilegiado. Cambiando a privilegiado..."
        sed -i "s/^unprivileged: 1/unprivileged: 0/" "$CONFIG_FILE"
        STORAGE_TYPE=$(pct config "$CONTAINER_ID" | grep "^rootfs:" | awk -F, '{print $2}' | cut -d'=' -f2)
        if [[ "$STORAGE_TYPE" == "dir" ]]; then
            STORAGE_PATH=$(pct config "$CONTAINER_ID" | grep "^rootfs:" | awk '{print $2}' | cut -d',' -f1)
            chown -R root:root "$STORAGE_PATH"
        fi
        msg_ok "Contenedor cambiado a privilegiado."
    else
        msg_ok "El contenedor ya es privilegiado."
    fi
}

# Verificar y configurar repositorios en el host
verify_and_add_repos() {
    msg_info "Verificando y configurando repositorios necesarios en el host..."

    # Repositorio de Proxmox no suscripción
    if ! grep -q "pve-no-subscription" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "deb http://download.proxmox.com/debian/pve $(lsb_release -sc) pve-no-subscription" | tee /etc/apt/sources.list.d/pve-no-subscription.list
        msg_ok "Repositorio pve-no-subscription añadido."
    else
        msg_ok "Repositorio pve-no-subscription ya configurado."
    fi

    # Repositorio de firmware non-free
    if ! grep -q "non-free-firmware" /etc/apt/sources.list; then
        echo "deb http://deb.debian.org/debian $(lsb_release -sc) main contrib non-free-firmware
deb http://deb.debian.org/debian $(lsb_release -sc)-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $(lsb_release -sc)-security main contrib non-free-firmware" | tee -a /etc/apt/sources.list
        msg_ok "Repositorios non-free-firmware añadidos."
    else
        msg_ok "Repositorios non-free-firmware ya configurados."
    fi

    apt-get update &>/dev/null
    msg_ok "Repositorios verificados y actualizados."
}

# Configurar repositorio de Coral TPU en el contenedor
add_coral_repos() {
    msg_info "Verificando repositorios de Coral TPU en el contenedor..."
    pct exec "$CONTAINER_ID" -- bash -c "
    if ! grep -q 'coral-edgetpu-stable' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo 'deb https://packages.cloud.google.com/apt coral-edgetpu-stable main' | tee /etc/apt/sources.list.d/coral-edgetpu.list
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/coral-edgetpu.gpg
        msg_ok 'Repositorio de Coral TPU añadido.'
    else
        msg_ok 'Repositorio de Coral TPU ya configurado.'
    fi
    apt-get update &>/dev/null
    "
}

# Configurar iGPU en el contenedor
configure_lxc_for_igpu() {
    ensure_privileged_container
    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 226:/d' "$CONFIG_FILE"
    sed -i '/^lxc\.mount\.entry: \/dev\/dri/d' "$CONFIG_FILE"

    cat <<EOF >> "$CONFIG_FILE"
features: nesting=1
lxc.cgroup2.devices.allow: c 226:0 rwm # iGPU
lxc.cgroup2.devices.allow: c 226:128 rwm # iGPU
lxc.cgroup2.devices.allow: c 29:0 rwm # Framebuffer
lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF

    msg_ok "Configuración de iGPU añadida al contenedor $CONTAINER_ID."
}

# Instalar controladores iGPU en el contenedor
install_igpu_in_container() {
    msg_info "Instalando controladores de iGPU dentro del contenedor..."
    pct start "$CONTAINER_ID"
    pct exec "$CONTAINER_ID" -- bash -c "
    apt-get update && apt-get install -y vainfo intel-media-va-driver-non-free intel-gpu-tools
    adduser root video
    adduser root render
    "
    msg_ok "Controladores de iGPU instalados dentro del contenedor."
}

# Instalar Coral TPU en el host
install_coral_host() {
    msg_info "Instalando controladores de Coral TPU en el host..."
    verify_and_add_repos
    apt-get install -y git devscripts dh-dkms dkms pve-headers-$(uname -r) &>/dev/null
    cd /tmp
    rm -rf gasket-driver
    git clone https://github.com/google/gasket-driver.git &>/dev/null
    cd gasket-driver/
    debuild -us -uc -tc -b &>/dev/null
    dpkg -i ../gasket-dkms_1.0-18_all.deb &>/dev/null
    msg_ok "Controladores de Coral TPU instalados en el host."
}

# Configurar Coral TPU en el contenedor
configure_lxc_for_coral() {
    ensure_privileged_container
    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"

    # Configurar dispositivos Coral TPU sin verificar su detección
    cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 189:* rwm # Coral USB
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 29:0 rwm # Coral M.2
lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file
EOF

    msg_ok "Configuración de Coral TPU (USB y M.2) añadida al contenedor $CONTAINER_ID."
}

# Instalar controladores Coral TPU en el contenedor
install_coral_in_container() {
    msg_info "Detectando dispositivos Coral TPU dentro del contenedor..."
    CORAL_M2=$(lspci | grep -i "Global Unichip")

    if [[ -n "$CORAL_M2" ]]; then
        msg_info "Se detectó un Coral M.2. Preguntando por la versión de controladores a instalar..."
        DRIVER_OPTION=$(whiptail --title "Seleccionar versión de controladores" \
            --menu "Elige la versión de controladores para Coral M.2:\n\nPrecaución: El modo máximo genera más calor." 15 60 2 \
            1 "libedgetpu1-std (rendimiento estándar)" \
            2 "libedgetpu1-max (máximo rendimiento)" 3>&1 1>&2 2>&3)

        case "$DRIVER_OPTION" in
            1)
                DRIVER_PACKAGE="libedgetpu1-std"
                ;;
            2)
                DRIVER_PACKAGE="libedgetpu1-max"
                ;;
            *)
                msg_error "Opción no válida. Instalando libedgetpu1-std por defecto."
                DRIVER_PACKAGE="libedgetpu1-std"
                ;;
        esac
    else
        msg_info "No se detectó un Coral M.2. Instalando libedgetpu1-std por defecto."
        DRIVER_PACKAGE="libedgetpu1-std"
    fi

    pct start "$CONTAINER_ID"
    pct exec "$CONTAINER_ID" -- bash -c "
    apt-get update && apt-get install -y gnupg
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/coral-edgetpu.gpg
    echo 'deb [signed-by=/usr/share/keyrings/coral-edgetpu.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main' | tee /etc/apt/sources.list.d/coral-edgetpu.list
    apt-get update && apt-get install -y $DRIVER_PACKAGE
    "
    msg_ok "Controladores de Coral TPU instalados dentro del contenedor."
}

# Menú principal
main_menu() {
    OPTIONS=(
        1 "Añadir aceleración gráfica iGPU"
        2 "Añadir Coral TPU (incluye instalación en host y contenedor)"
    )

    OPTION=$(whiptail --title "Menú Principal" --menu "Selecciona los recursos a añadir al contenedor:" 15 60 2 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)

    case "$OPTION" in
        1)
            configure_lxc_for_igpu
            install_igpu_in_container
            ;;
        2)
            install_coral_host
            configure_lxc_for_coral
            install_coral_in_container
            ;;
        *)
            msg_error "Opción no válida. Saliendo."
            exit 1
            ;;
    esac

    msg_ok "Configuración completada."
}

main_menu
