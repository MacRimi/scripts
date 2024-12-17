#!/bin/bash
# Script para instalar drivers NVIDIA en Proxmox y configurarlos para LXC
# Autor: @MacRimi

set -e

# Variables
NVIDIA_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt"
DRIVER_DIR="/opt/nvidia"
RESTART_FILE="/nvidia_install_restart.flag"

# Funciones auxiliares
log() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
    exit 1
}

reboot_required=false

# Control de reinicio
if [ -f "$RESTART_FILE" ]; then
    log "Reanudando la instalación después del reinicio..."
    rm -f "$RESTART_FILE"
    CONFIGURE_LXC_FOR_NVIDIA
    exit 0
fi

# 1. Blacklist nouveau
log "Blacklisteando nouveau..."
echo "blacklist nouveau" | tee /etc/modprobe.d/blacklist.conf
update-initramfs -u

# 2. Actualización de repositorios y paquetes
log "Actualizando repositorios y paquetes..."
apt update && apt dist-upgrade -y
apt install -y git pve-headers-$(uname -r) gcc make wget whiptail

# 3. Menú para selección de driver NVIDIA
log "Obteniendo lista de drivers NVIDIA..."
mkdir -p $DRIVER_DIR && cd $DRIVER_DIR
driver_list=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ | grep -Eo '[0-9]{3}\.[0-9]{3}\.[0-9]{2}' | sort -Vr | head -n 10 | tr -s '\n' ' ')
latest_driver=$(wget -qO- $NVIDIA_DRIVER_URL | grep -Eo '[0-9]{3}\.[0-9]{3}\.[0-9]{2}')
if [ -z "$latest_driver" ]; then
    error "No se pudo obtener la última versión del controlador NVIDIA."
fi

options="\n1 Instalar último driver ($latest_driver)\n"
count=2
for driver in $driver_list; do
    options+="$count $driver\n"
    count=$((count+1))
done

selection=$(whiptail --title "Seleccionar Driver NVIDIA" --menu "Elige una opción:" 15 50 10 $options 3>&1 1>&2 2>&3)

if [[ ! "$selection" =~ ^[0-9]+$ ]]; then
    error "Selección inválida o cancelada por el usuario."
fi

if [ "$selection" -eq 1 ]; then
    selected_driver=$latest_driver
else
    selected_driver=$(echo $driver_list | tr ' ' '\n' | sed -n "$((selection-1))p")
fi

DRIVER_RUN="NVIDIA-Linux-x86_64-$selected_driver.run"
log "Descargando e instalando driver $selected_driver..."
wget -q https://download.nvidia.com/XFree86/Linux-x86_64/$selected_driver/$DRIVER_RUN -O $DRIVER_RUN
chmod +x $DRIVER_RUN
./$DRIVER_RUN --no-questions --ui=none --disable-nouveau || error "Error instalando driver NVIDIA."
reboot_required=true

# Configuración LXC antes del reinicio
CONFIGURE_LXC_FOR_NVIDIA() {
    log "Configurando acceso NVIDIA para contenedores LXC..."
    available_lxc=$(pct list | awk 'NR>1 {print $1, $3}')
    lxc_selection=$(whiptail --title "Seleccionar LXC" --menu "Selecciona un contenedor para instalar los drivers NVIDIA:" 20 70 10 $available_lxc 3>&1 1>&2 2>&3)

    if [[ ! "$lxc_selection" =~ ^[0-9]+$ ]]; then
        error "Selección inválida o cancelada."
    fi

    CONFIG_FILE="/etc/pve/lxc/${lxc_selection}.conf"
    if ls /dev/nv* > /dev/null 2>&1; then
        NV_DEVICES=$(ls -l /dev/nv* | awk '{print $5,$6}' | sed 's/,/:/g')
    else
        error "No se encontraron dispositivos NVIDIA en /dev/nv*."
    fi

    # Limpiar configuraciones previas
    sed -i '/^lxc\.cgroup2\.devices\.allow: c /d' "$CONFIG_FILE"
    sed -i '/^lxc\.mount\.entry: \/dev\/nvidia/d' "$CONFIG_FILE"

    # Añadir configuraciones nuevas
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

    log "Configuración completada para el LXC $lxc_selection."
    reboot_required=true
}

CONFIGURE_LXC_FOR_NVIDIA

if [ "$reboot_required" = true ]; then
    touch "$RESTART_FILE"
    log "Reinicio necesario. Por favor, reinicia y vuelve a ejecutar el script:"
    log "bash -c \"\$(wget -qLO - https://raw.githubusercontent.com/MacRimi/scripts/refs/heads/main/nvidia.sh)\""
    exit 0
fi

# Mensaje final
log "Proceso completado exitosamente."
exit 0
