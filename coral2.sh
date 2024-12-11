#!/bin/bash

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\r\033[K"
CM="${GN}✓${CL}"
HOLD="-"

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

msg_info() {
    local msg="$1"
    echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
    local msg="$1"
    echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
    local msg="$1"
    echo -e "${BFR} ${RD}✗ ${CL}${msg}"
}

NEED_REBOOT=false

# Validar la versión de Proxmox
validate_pve_version() {
    if ! pveversion | grep -Eq "pve-manager/(8\.[1-3])"; then
        msg_error "Esta versión de Proxmox no es compatible."
        echo -e "Requiere Proxmox VE 8.1 o superior. Saliendo..."
        exit 1
    fi
    msg_ok "Versión de Proxmox compatible."
}

# Verificar y configurar repositorios
verify_and_add_repos() {
    msg_info "Verificando y configurando repositorios necesarios"
    if ! grep -q "pve-no-subscription" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "deb http://download.proxmox.com/debian/pve $(lsb_release -sc) pve-no-subscription" | tee /etc/apt/sources.list.d/pve-no-subscription.list
    fi
    if ! grep -q "non-free-firmware" /etc/apt/sources.list; then
        echo "deb http://deb.debian.org/debian $(lsb_release -sc) main contrib non-free-firmware
deb http://deb.debian.org/debian $(lsb_release -sc)-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $(lsb_release -sc)-security main contrib non-free-firmware" | tee -a /etc/apt/sources.list
    fi
    apt-get update &>/dev/null
    msg_ok "Repositorios configurados correctamente."
}

# Verificar si se requieren repositorios adicionales y añadirlos
add_coral_repos() {
    msg_info "Verificando repositorios de Coral TPU"
    if ! grep -q "coral-edgetpu-stable" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" | tee /etc/apt/sources.list.d/coral-edgetpu.list
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/coral-edgetpu.gpg
        apt-get update &>/dev/null
        msg_ok "Repositorio de Coral añadido correctamente."
    else
        msg_ok "Repositorio de Coral ya configurado."
    fi
}

# Instalar dependencias para Coral TPU
install_coral_dependencies() {
    msg_info "Instalando dependencias para Coral TPU"
    apt remove -y gasket-dkms &>/dev/null
    apt install -y git devscripts dh-dkms dkms pve-headers-$(uname -r) &>/dev/null
    cd /tmp
    rm -rf gasket-driver
    git clone https://github.com/google/gasket-driver.git &>/dev/null
    cd gasket-driver/
    debuild -us -uc -tc -b &>/dev/null
    dpkg -i ../gasket-dkms_1.0-18_all.deb &>/dev/null
    apt-get install -y libedgetpu1-max &>/dev/null
    msg_ok "Dependencias de Coral TPU instaladas correctamente."
}

# Cambiar contenedor a privilegiado
ensure_privileged_container() {
    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
    if grep -q "^unprivileged: 1" "$CONFIG_FILE"; then
        msg_info "El contenedor ${CONTAINER_ID} es no privilegiado. Cambiando a privilegiado..."
        sed -i "s/^unprivileged: 1/unprivileged: 0/" "$CONFIG_FILE"
        STORAGE_TYPE=$(pct config "$CONTAINER_ID" | grep "^rootfs:" | awk -F, '{print $2}' | cut -d'=' -f2)
        if [[ "$STORAGE_TYPE" == "dir" ]]; then
            STORAGE_PATH=$(pct config "$CONTAINER_ID" | grep "^rootfs:" | awk '{print $2}' | cut -d',' -f1)
            chown -R root:root "$STORAGE_PATH"
        fi
        msg_ok "Contenedor cambiado a privilegiado."
    else
        msg_ok "El contenedor ${CONTAINER_ID} ya es privilegiado."
    fi
}

# Seleccionar contenedor usando whiptail
select_container() {
    MENU_OPTIONS=()
    while IFS= read -r line; do
        CONTAINER_ID=$(echo "$line" | awk '{print $1}')
        CONTAINER_NAME=$(echo "$line" | awk '{print $2}')
        MENU_OPTIONS+=("$CONTAINER_ID" "$CONTAINER_NAME")
    done <<< "$(pct list | awk 'NR>1 {print $1, $3}')"

    CONTAINER_ID=$(whiptail --title "Seleccionar Contenedor" --menu "Selecciona un contenedor para configurar:" 15 60 5 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

    if [ -z "$CONTAINER_ID" ]; then
        msg_error "No se seleccionó ningún contenedor."
        exit 1
    fi

    msg_ok "Contenedor seleccionado: $CONTAINER_ID"
}

# Configurar LXC para iGPU
configure_lxc_for_igpu() {
    ensure_privileged_container
    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 226:/d' "$CONFIG_FILE"
    sed -i '/^lxc\.mount\.entry: \/dev\/dri/d' "$CONFIG_FILE"

    cat <<EOF >> "$CONFIG_FILE"
features: nesting=1
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.cgroup2.devices.allow: c 29:0 rwm
lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
EOF
    msg_ok "Configuración de iGPU añadida al contenedor ${CONTAINER_ID}."
}

# Configurar LXC para NVIDIA
configure_lxc_for_nvidia() {
    ensure_privileged_container
    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
    NV_DEVICES=$(ls -l /dev/nv* | awk '{print $5,$6}' | sed 's/,/:/g')

    sed -i '/^lxc\.cgroup2\.devices\.allow: c /d' "$CONFIG_FILE"
    sed -i '/^lxc\.mount\.entry: \/dev\/nvidia/d' "$CONFIG_FILE"

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
    msg_ok "Configuración de NVIDIA añadida al contenedor ${CONTAINER_ID}."
}

# Configurar LXC para Coral TPU
configure_lxc_for_coral() {
    ensure_privileged_container
    add_coral_repos
    install_coral_dependencies

    CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
    cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 29:0 rwm
lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file
EOF
    msg_ok "Configuración de Coral TPU añadida al contenedor ${CONTAINER_ID}."
}

# Reiniciar si es necesario
prompt_reboot() {
    if $NEED_REBOOT; then
        if whiptail --title "Reinicio Requerido" --yesno "Se requiere un reinicio para aplicar los cambios. ¿Deseas reiniciar ahora?" 10 60; then
            msg_info "Reiniciando el sistema..."
            reboot
        else
            msg_ok "Por favor, reinicia el sistema más tarde para aplicar los cambios."
        fi
    fi
}

# Menú principal
main_menu() {
    validate_pve_version
    PS3="Selecciona una opción: "
    OPTIONS=(
        "Añadir iGPU"
        "Añadir NVIDIA"
        "Añadir Coral TPU"
        "Salir"
    )
    select OPTION in "${OPTIONS[@]}"; do
        case "$REPLY" in
            1)
                select_container
                configure_lxc_for_igpu
                NEED_REBOOT=true
                break
                ;;
            2)
                select_container
                configure_lxc_for_nvidia
                NEED_REBOOT=true
                break
                ;;
            3)
                select_container
                configure_lxc_for_coral
                NEED_REBOOT=true
                break
                ;;
            4)
                msg_ok "Saliendo del script."
                exit 0
                ;;
            *)
                msg_error "Opción inválida. Intenta de nuevo."
                ;;
        esac
    done
    prompt_reboot
}

main_menu
