#!/bin/bash
# Script dinámico para asignar GPU entre VM y LXC
# Autor: @MacRimi

set -e

# Funciones auxiliares
log() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; exit 1; }

# Verificar dependencias
check_dependencies() {
    for cmd in lspci whiptail pct qm; do
        if ! command -v $cmd &>/dev/null; then
            error "La herramienta '$cmd' no está instalada. Instálala primero."
        fi
    done
}

# Detección automática de GPU (Vendor ID y Product ID)
detect_gpu_ids() {
    log "Detectando GPU NVIDIA..."
    GPU_INFO=$(lspci -nn | grep -i nvidia | grep -oP '\[\K(10de:[^\]]+)')
    if [ -z "$GPU_INFO" ]; then
        error "No se detectó ninguna GPU NVIDIA. Asegúrate de que esté instalada correctamente."
    fi
    GPU_VID=${GPU_INFO%%:*}   # Extrae Vendor ID
    GPU_PID=${GPU_INFO##*:}   # Extrae Product ID
    log "GPU detectada: Vendor ID = $GPU_VID, Product ID = $GPU_PID"
}

# Configuraciones y rutas
LXC_CONF_DIR="/etc/pve/lxc/"
VFIO_CONF="/etc/modprobe.d/vfio.conf"

# Selección dinámica de contenedor LXC
dynamic_lxc_selection() {
    log "Obteniendo lista de contenedores LXC disponibles..."
    LXC_LIST=$(pct list | awk 'NR>1 {print $1, $3}')
    if [ -z "$LXC_LIST" ]; then
        error "No se encontraron contenedores LXC disponibles."
    fi

    menu_options=()
    while read -r id name; do
        menu_options+=("$id" "$name")
    done <<< "$LXC_LIST"

    LXC_ID=$(whiptail --title "Seleccionar LXC" --menu "Elige un contenedor LXC:" 20 70 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)
    if [ -z "$LXC_ID" ]; then
        error "Selección cancelada."
    fi
    LXC_CONF="$LXC_CONF_DIR$LXC_ID.conf"
    log "LXC seleccionado: $LXC_ID"
}

# Selección dinámica de VM
dynamic_vm_selection() {
    log "Obteniendo lista de VMs disponibles..."
    VM_LIST=$(qm list | awk 'NR>1 {print $1, $2}')
    if [ -z "$VM_LIST" ]; then
        error "No se encontraron VMs disponibles."
    fi

    menu_options=()
    while read -r id name; do
        menu_options+=("$id" "$name")
    done <<< "$VM_LIST"

    VM_ID=$(whiptail --title "Seleccionar VM" --menu "Elige una VM:" 20 70 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)
    if [ -z "$VM_ID" ]; then
        error "Selección cancelada."
    fi
    log "VM seleccionada: $VM_ID"
}

# Asignar GPU a LXC
assign_to_lxc() {
    dynamic_lxc_selection
    log "Asignando GPU al LXC $LXC_ID..."

    sed -i "/^options vfio-pci ids/d" "$VFIO_CONF" || true
    update-initramfs -u

    if grep -q "lxc.mount.entry: /dev/nvidia0" "$LXC_CONF"; then
        log "La configuración de GPU para LXC ya existe."
    else
        echo "lxc.cgroup2.devices.allow: c 195:* rwm" >> "$LXC_CONF"
        echo "lxc.cgroup2.devices.allow: c 511:* rwm" >> "$LXC_CONF"
        echo "lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,create=file 0 0" >> "$LXC_CONF"
        echo "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,create=file 0 0" >> "$LXC_CONF"
        echo "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,create=file 0 0" >> "$LXC_CONF"
        echo "lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,create=file 0 0" >> "$LXC_CONF"
    fi

    pct stop "$LXC_ID" && pct start "$LXC_ID"
    log "GPU asignada correctamente al LXC $LXC_ID."
}

# Asignar GPU a VM
assign_to_vm() {
    dynamic_vm_selection
    log "Asignando GPU a la VM $VM_ID..."

    echo "options vfio-pci ids=${GPU_VID}:${GPU_PID} disable_vga=1" > "$VFIO_CONF"
    update-initramfs -u

    qm stop "$VM_ID" || true
    qm start "$VM_ID"
    log "GPU asignada correctamente a la VM $VM_ID."
}

# Limpieza de configuraciones
cleanup() {
    log "Limpiando configuraciones de GPU..."
    sed -i "/^options vfio-pci ids/d" "$VFIO_CONF" || true
    update-initramfs -u

    if [ -f "$LXC_CONF" ]; then
        sed -i '/lxc.mount.entry: \/dev\/nvidia/d' "$LXC_CONF" || true
        sed -i '/lxc.cgroup2.devices.allow: c 195:/d' "$LXC_CONF" || true
        sed -i '/lxc.cgroup2.devices.allow: c 511:/d' "$LXC_CONF" || true
    fi

    log "Configuraciones limpiadas correctamente."
}

# Menú principal
main_menu() {
    check_dependencies
    detect_gpu_ids
    clear
    echo "=== Script Dinámico para Asignar GPU ==="
    echo "1. Asignar GPU a LXC"
    echo "2. Asignar GPU a VM"
    echo "3. Limpiar configuraciones"
    echo "4. Salir"
    echo "========================================="
    read -p "Selecciona una opción: " choice

    case $choice in
        1) assign_to_lxc ;;
        2) assign_to_vm ;;
        3) cleanup ;;
        4) exit 0 ;;
        *) error "Opción no válida." ;;
    esac
}

# Ejecutar menú principal
main_menu
