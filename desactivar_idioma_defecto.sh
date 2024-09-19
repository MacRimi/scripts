#!/usr/bin/env bash
# Desactivar el idioma por defecto en APT

echo ""
echo ""

if [ -f "/etc/apt/apt.conf.d/30desdability-lang" ]; then
    echo "-------------------------------------------"
    echo "* El idioma por defecto ya está desactivado *"
    echo "-------------------------------------------"
    echo ""
    echo ""
else
    echo "Acquire::Languages \"none\";" > /etc/apt/apt.conf.d/30desdability-lang
    echo "Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled \"false\";" >> /etc/apt/apt.conf.d/30desdability-lang

    echo "------------------------------------------"
    echo "* El idioma por defecto se ha desactivado *"
    echo "------------------------------------------"
    echo ""
    echo ""
    echo "Reinicia Proxmox para aplicar el cambio"
    echo ""
    echo ""
fi
