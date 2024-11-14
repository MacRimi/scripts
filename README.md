# Proxmox

## - Añadir aceleracion gráfica GPU y/o añadir Coral TPU: <img src="https://raw.githubusercontent.com/lucide-icons/lucide/master/icons/cpu.svg" alt="Ícono de CPU" width="50" height="50">

![Ícono de CPU](https://cdn-icons-png.flaticon.com/512/1995/1995574.png)



```
bash -c "$(wget -qLO - https://raw.githubusercontent.com/MacRimi/scripts/refs/heads/main/Igpu_and_coral.sh)"
```

#


## - **Script quitar cartel suscripcion proxmox**

```
bash -c "$(wget -qLO - https://raw.githubusercontent.com/proxmology/proxmox/main/start.sh)"
```

## - **Script para activar Wake On Lan en cada uno de los nodos (*hay que hacerlo nodo por nodo*)**

```
bash -c "$(wget -qLO - https://raw.githubusercontent.com/proxmology/proxmox/main/wol.sh)"

```

## - **Script para activar IOMMU para intel & amd**

```
wget -O - https://raw.githubusercontent.com/proxmology/proxmox/main/habilitar_iommu.sh | bash

```
## - **Script para desactivar el idioma por defecto**

```
bash -c "$(wget -qLO - https://raw.githubusercontent.com/proxmology/scripts/main/desactivar_idioma_defecto.sh)"

```
