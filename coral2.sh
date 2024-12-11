#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Verificar y configurar el repositorio "No Subscription" de Proxmox
add_pve_no_subscription_repo() {
    log "Verificando repositorio 'No Subscription' de Proxmox..."
    if ! grep -q "pve-no-subscription" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "deb http://download.proxmox.com/debian/pve $(lsb_release -sc) pve-no-subscription" | tee /etc/apt/sources.list.d/pve-no-subscription.list
        apt-get update && log "Repositorio 'No Subscription' configurado correctamente."
    else
        log "El repositorio 'No Subscription' ya está configurado."
    fi
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

install_usb_driver() {
    log "Instalando controlador para Coral USB..."
    apt-get install -y libedgetpu1-max && log "Controlador USB instalado correctamente." || log "Error al instalar el controlador USB."
}

install_pci_driver() {
    log "Instalando controlador para Coral M.2/PCI..."
    add_pve_no_subscription_repo
    log "Instalando controlador para Coral M.2/PCI..."
    if ! dkms status | grep -q gasket; then
        apt-get remove -y gasket-dkms
        apt-get install -y git devscripts dh-dkms dkms pve-headers-$(uname -r)
        cd /tmp
        rm -rf gasket-driver
        git clone https://github.com/google/gasket-driver.git
        cd gasket-driver/
        debuild -us -uc -tc -b
        dpkg -i ../gasket-dkms_*.deb && log "Controlador M.2/PCI instalado correctamente." || log "Error al instalar el controlador M.2/PCI."
        cd /tmp
        rm -rf gasket-driver
    else
        log "Controlador M.2/PCI ya está instalado."
    fi
}

# Listar contenedores LXC disponibles
echo "Selecciona el contenedor LXC al que deseas añadir recursos:"
LXC_OPTIONS=($(pct list | awk 'NR>1 {print $1 " - " $3}'))
if [ ${#LXC_OPTIONS[@]} -eq 0 ]; then
    echo "No hay contenedores disponibles. Saliendo."
    exit 1
fi

PS3="Selecciona el número del contenedor: "
select LXC_OPTION in "${LXC_OPTIONS[@]}"; do
    if [[ -n "$LXC_OPTION" ]]; then
        CONTAINER_ID=$(echo "$LXC_OPTION" | awk '{print $1}')
        break
    else
        echo "Opción inválida. Intenta de nuevo."
    fi
done

# Verificar si el contenedor existe
if ! pct status "$CONTAINER_ID" &>/dev/null; then
    echo "Error: No se encontró el contenedor con ID $CONTAINER_ID"
    exit 1
fi

# Menú de selección de recursos
echo "Selecciona los recursos a añadir al contenedor:"
OPTIONS=("Añadir aceleración gráfica iGPU" "Añadir Coral TPU (incluye iGPU si está disponible)")
PS3="Selecciona el número de la opción: "
select OPTION in "${OPTIONS[@]}"; do
    if [[ -n "$OPTION" ]]; then
        case $REPLY in
            1) OPTION=1; break ;;
            2) OPTION=2; break ;;
            *) echo "Opción inválida. Intenta de nuevo." ;;
        esac
    fi
done

# Apagar el contenedor
echo "Apagando el contenedor LXC..."
pct stop "$CONTAINER_ID"

# Configurar privilegios y recursos
CONFIG_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"
if grep -q "^unprivileged: 1" "$CONFIG_FILE"; then
    echo "El contenedor es no privilegiado. Cambiando a privilegiado..."
    sed -i "s/^unprivileged: 1/unprivileged: 0/" "$CONFIG_FILE"
    STORAGE_TYPE=$(pct config "$CONTAINER_ID" | grep "^rootfs:" | awk -F, '{print $2}' | cut -d'=' -f2)
    if [[ "$STORAGE_TYPE" == "dir" ]]; then
        STORAGE_PATH=$(pct config "$CONTAINER_ID" | grep "^rootfs:" | awk '{print $2}' | cut -d',' -f1)
        chown -R root:root "$STORAGE_PATH"
    fi
fi

if [[ "$OPTION" == "1" || "$OPTION" == "2" ]]; then
    if [[ -e /dev/dri/renderD128 ]]; then
        echo "Añadiendo iGPU al contenedor..."
        grep -q "cgroup2.devices.allow: c 226" "$CONFIG_FILE" || cat <<EOF >> "$CONFIG_FILE"
features: nesting=1
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
    fi
fi

if [[ "$OPTION" == "2" ]]; then
    add_coral_repos
    log "Detectando dispositivos Coral TPU..."
    if lsusb | grep -i "Global Unichip" &>/dev/null; then
        install_usb_driver
        grep -q "c 189:* rwm" "$CONFIG_FILE" || cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
EOF
    elif lspci | grep -i "Global Unichip" &>/dev/null; then
        install_pci_driver
        grep -q "c 29:0 rwm" "$CONFIG_FILE" || cat <<EOF >> "$CONFIG_FILE"
lxc.cgroup2.devices.allow: c 29:0 rwm
lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file
EOF
    else
        echo "No se detectó un dispositivo Coral TPU. Verifica la conexión."
        exit 1
    fi
fi

# Iniciar contenedor
pct start "$CONTAINER_ID"
log "Recursos añadidos correctamente al contenedor."
