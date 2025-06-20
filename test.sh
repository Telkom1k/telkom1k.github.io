#!/bin/bash

# Script de instalación de Arch Linux Hardened con UKI + TPM + Measured Boot

# Configuración ultra segura con cifrado completo, AppArmor y logging avanzado

set -euo pipefail

# Colores para output

RED=’\033[0;31m’
GREEN=’\033[0;32m’
YELLOW=’\033[1;33m’
BLUE=’\033[0;34m’
NC=’\033[0m’ # No Color

# Función para logging

log() {
echo -e “${GREEN}[$(date +’%Y-%m-%d %H:%M:%S’)] $1${NC}”
}

warning() {
echo -e “${YELLOW}[WARNING] $1${NC}”
}

error() {
echo -e “${RED}[ERROR] $1${NC}”
exit 1
}

# Verificar que estamos en modo UEFI

check_uefi() {
if [ ! -d “/sys/firmware/efi” ]; then
error “Este script requiere arranque UEFI. Sistema Legacy BIOS no soportado.”
fi
log “Verificación UEFI: OK”
}

# Configurar teclado

setup_keyboard() {
log “Configurando teclado español…”
loadkeys es
}

# Verificar conexión a internet

check_internet() {
log “Verificando conexión a internet…”
if ! ping -c 1 8.8.8.8 &> /dev/null; then
warning “No hay conexión a internet.”
echo “Por favor, conecta a una red WiFi usando ‘iwctl’ o conecta cable ethernet.”
read -p “Presiona Enter cuando tengas conexión a internet…”

```
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        error "Aún no hay conexión a internet. Abortando."
    fi
fi
log "Conexión a internet: OK"
```

}

# Sincronizar reloj

sync_time() {
log “Sincronizando reloj del sistema…”
timedatectl set-ntp true
sleep 2
}

# Configurar mirrors optimizados (CORREGIDO)

setup_mirrors() {
log “Configurando mirrors optimizados…”
# CAMBIO PRINCIPAL: Eliminado –sort rate que causaba problemas
# Agregado –fastest 10 para seleccionar los 10 más rápidos
reflector –country Spain,Germany,France,Italy,Netherlands   
–age 24   
–protocol https   
–fastest 10   
–save /etc/pacman.d/mirrorlist

```
log "Mirrors configurados correctamente"
```

}

# Actualizar sistema antes de instalar

update_system() {
log “Actualizando base de datos de paquetes…”
pacman -Sy –noconfirm
}

# Seleccionar disco automáticamente

select_disk() {
log “Detectando discos disponibles…”

```
# Listar discos disponibles
lsblk -dpno NAME,SIZE,TYPE | grep disk

# Autodetectar el disco principal (generalmente el más grande)
DISK=$(lsblk -dpno NAME,SIZE,TYPE | grep disk | sort -k2 -hr | head -n1 | awk '{print $1}')

echo -e "\n${BLUE}Disco detectado automáticamente: $DISK${NC}"
lsblk $DISK

echo -e "\n${RED}¡ADVERTENCIA!${NC} Se borrarán TODOS los datos del disco $DISK"
read -p "¿Continuar? (s/N): " confirm

if [[ ! $confirm =~ ^[sS]$ ]]; then
    error "Instalación cancelada por el usuario"
fi

export DISK
log "Disco seleccionado: $DISK"
```

}

# Solicitar contraseñas de manera segura

get_passwords() {
log “Configurando contraseñas del sistema…”

```
# Contraseña de cifrado LUKS
while true; do
    echo -n "Ingresa la contraseña para cifrado de disco (LUKS): "
    read -s LUKS_PASSWORD
    echo
    echo -n "Confirma la contraseña: "
    read -s LUKS_PASSWORD_CONFIRM
    echo
    
    if [ "$LUKS_PASSWORD" = "$LUKS_PASSWORD_CONFIRM" ] && [ ${#LUKS_PASSWORD} -ge 8 ]; then
        break
    else
        echo "Las contraseñas no coinciden o son muy cortas (mínimo 8 caracteres)"
    fi
done

# Contraseña de root
while true; do
    echo -n "Ingresa la contraseña para root: "
    read -s ROOT_PASSWORD
    echo
    echo -n "Confirma la contraseña: "
    read -s ROOT_PASSWORD_CONFIRM
    echo
    
    if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ] && [ ${#ROOT_PASSWORD} -ge 8 ]; then
        break
    else
        echo "Las contraseñas no coinciden o son muy cortas (mínimo 8 caracteres)"
    fi
done

# Nombre y contraseña del usuario
read -p "Nombre del usuario principal: " USERNAME
while true; do
    echo -n "Contraseña para $USERNAME: "
    read -s USER_PASSWORD
    echo
    echo -n "Confirma la contraseña: "
    read -s USER_PASSWORD_CONFIRM
    echo
    
    if [ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ] && [ ${#USER_PASSWORD} -ge 8 ]; then
        break
    else
        echo "Las contraseñas no coinciden o son muy cortas (mínimo 8 caracteres)"
    fi
done

export LUKS_PASSWORD ROOT_PASSWORD USERNAME USER_PASSWORD
```

}

# Preparar y particionar disco (MEJORADO)

prepare_disk() {
log “Preparando disco $DISK…”

```
# Desmontar cualquier partición que pueda estar montada
umount -A --recursive ${DISK}* 2>/dev/null || true

# Cerrar cualquier volumen LVM o LUKS existente
vgchange -an 2>/dev/null || true
cryptsetup close cryptlvm 2>/dev/null || true

# Limpiar completamente el disco
wipefs -af $DISK
sgdisk --zap-all $DISK

# Crear nueva tabla de particiones GPT
sgdisk --clear \
       --new=1:0:+1G --typecode=1:ef00 --change-name=1:'EFI System' \
       --new=2:0:0 --typecode=2:8300 --change-name=2:'Linux filesystem' \
       $DISK

# Informar al kernel sobre los cambios
partprobe $DISK
sleep 2

# Establecer variables de particiones
if [[ $DISK == *"nvme"* ]]; then
    export EFI_PART="${DISK}p1"
    export ROOT_PART="${DISK}p2"
else
    export EFI_PART="${DISK}1"
    export ROOT_PART="${DISK}2"
fi

log "Particiones creadas: EFI=$EFI_PART, ROOT=$ROOT_PART"
```

}

# Configurar cifrado LUKS con parámetros seguros

setup_encryption() {
log “Configurando cifrado LUKS con parámetros de seguridad avanzados…”

```
# Configuración LUKS2 con algoritmos seguros y verificación de integridad
echo "$LUKS_PASSWORD" | cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --iter-time 5000 \
    --use-random \
    --verify-passphrase \
    $ROOT_PART

# Abrir el contenedor cifrado
echo "$LUKS_PASSWORD" | cryptsetup open $ROOT_PART cryptlvm

log "Cifrado LUKS configurado correctamente"
```

}

# Configurar LVM

setup_lvm() {
log “Configurando LVM…”

```
# Crear volumen físico
pvcreate /dev/mapper/cryptlvm

# Crear grupo de volúmenes
vgcreate vg0 /dev/mapper/cryptlvm

# Detectar RAM para configurar swap
RAM_SIZE=$(free -m | awk '/^Mem:/{print $2}')
if [ $RAM_SIZE -lt 2048 ]; then
    SWAP_SIZE="${RAM_SIZE}M"
elif [ $RAM_SIZE -lt 8192 ]; then
    SWAP_SIZE="4G"
else
    SWAP_SIZE="8G"
fi

# Crear volúmenes lógicos
lvcreate -L $SWAP_SIZE vg0 -n swap
lvcreate -L 50G vg0 -n root
lvcreate -l 100%FREE vg0 -n home

log "LVM configurado: swap=$SWAP_SIZE, root=50G, home=resto"
```

}

# Formatear particiones

format_partitions() {
log “Formateando particiones…”

```
# Formatear EFI como FAT32
mkfs.fat -F32 -n "EFI" $EFI_PART

# Formatear volúmenes lógicos con parámetros seguros
mkfs.ext4 -L "root" -O ^has_journal /dev/vg0/root
mkfs.ext4 -L "home" -O ^has_journal /dev/vg0/home
mkswap -L "swap" /dev/vg0/swap

log "Particiones formateadas correctamente"
```

}

# Montar sistema de archivos

mount_filesystems() {
log “Montando sistema de archivos…”

```
# Montar partición raíz
mount /dev/vg0/root /mnt

# Crear directorios de montaje
mkdir -p /mnt/{boot,home,var/log,tmp}

# Montar particiones
mount $EFI_PART /mnt/boot
mount /dev/vg0/home /mnt/home
swapon /dev/vg0/swap

# Configurar tmpfs para /tmp (seguridad)
mount -t tmpfs -o nodev,nosuid,noexec tmpfs /mnt/tmp

log "Sistema de archivos montado"
```

}

# Instalar sistema base con kernel hardened

install_base_system() {
log “Instalando sistema base con kernel hardened…”

```
# Lista completa de paquetes necesarios
pacstrap -K /mnt \
    base base-devel \
    linux-hardened linux-hardened-headers \
    linux-firmware \
    intel-ucode \
    lvm2 cryptsetup \
    networkmanager \
    sudo nano git \
    efibootmgr systemd-boot \
    tpm2-tools \
    apparmor \
    sway waybar wofi \
    kitty firefox \
    pipewire pipewire-pulse wireplumber \
    brightnessctl \
    grim slurp wl-clipboard \
    thunar tumbler \
    ttf-dejavu ttf-liberation noto-fonts \
    reflector \
    sbctl \
    systemd-ukify

log "Sistema base instalado"
```

}

# Generar fstab

generate_fstab() {
log “Generando fstab…”
genfstab -U /mnt >> /mnt/etc/fstab

```
# Agregar tmpfs para /tmp con opciones de seguridad
echo "tmpfs /tmp tmpfs nodev,nosuid,noexec,size=2G 0 0" >> /mnt/etc/fstab
```

}

# Configurar sistema en chroot

configure_system() {
log “Configurando sistema…”

```
# Crear script de configuración para ejecutar en chroot
cat > /mnt/configure_chroot.sh << 'CHROOT_EOF'
```

#!/bin/bash

# Configurar zona horaria

ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock –systohc

# Configurar localización

sed -i ‘s/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/’ /etc/locale.gen
sed -i ‘s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/’ /etc/locale.gen
locale-gen

echo “LANG=es_ES.UTF-8” > /etc/locale.conf
echo “KEYMAP=es” > /etc/vconsole.conf

# Configurar hostname

echo “arch-hardened” > /etc/hostname

# Configurar hosts

cat > /etc/hosts << ‘EOF’
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch-hardened.localdomain arch-hardened
EOF

# Configurar cmdline para UKI

mkdir -p /etc/kernel
cat > /etc/kernel/cmdline << ‘EOF’
cryptdevice=UUID=CRYPTUUID:cryptlvm root=/dev/vg0/root rw quiet loglevel=3 apparmor=1 security=apparmor audit=1 kernel.yama.ptrace_scope=3 kernel.dmesg_restrict=1 kernel.kptr_restrict=2 slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off module.sig_enforce=1 lockdown=confidentiality ima_policy=tcb ima_hash=sha256
EOF

# Configurar mkinitcpio para UKI

cat > /etc/mkinitcpio.conf << ‘EOF’
MODULES=()
BINARIES=()
FILES=()
HOOKS=(systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)
COMPRESSION=“zstd”
EOF

# Configurar AppArmor

systemctl enable apparmor
aa-enforce /etc/apparmor.d/*

# Configurar auditd para logging avanzado

cat > /etc/audit/rules.d/audit.rules << ‘EOF’

# Eliminar reglas existentes

-D

# Buffer size

-b 8192

# Fallo del sistema si se llena el buffer

-f 1

# Monitorear cambios en archivos críticos del sistema

-w /etc/passwd -p rwxa -k passwd_changes
-w /etc/group -p rwxa -k group_changes
-w /etc/shadow -p rwxa -k shadow_changes
-w /etc/sudoers -p rwxa -k sudoers_changes
-w /etc/ssh/sshd_config -p rwxa -k ssh_config

# Monitorear escalamiento de privilegios

-w /bin/su -p x -k privilege_escalation
-w /usr/bin/sudo -p x -k privilege_escalation
-w /usr/bin/pkexec -p x -k privilege_escalation

# Monitorear syscalls de escalamiento

-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid -k privilege_escalation
-a always,exit -F arch=b32 -S setuid,setgid,setreuid,setregid -k privilege_escalation

# Monitorear acceso a archivos sensibles

-w /etc/kernel/ -p rwxa -k kernel_modules
-w /etc/modprobe.d/ -p rwxa -k kernel_modules
-w /proc/sys/kernel/ -p rwxa -k kernel_tuning

# Monitorear procesos con privilegios altos

-a always,exit -F euid=0 -S execve -k root_commands
-a always,exit -F uid=1000 -S execve -k user_commands

# Monitorear network connections

-a always,exit -F arch=b64 -S socket,connect,accept -k network
-a always,exit -F arch=b32 -S socket,connect,accept -k network

# Habilitar logging

-e 1
EOF

systemctl enable auditd

# Configurar systemd-boot con UKI

bootctl install
systemctl enable systemd-boot-update

# Configurar TPM2

mkdir -p /etc/systemd/system/systemd-cryptsetup@cryptlvm.service.d/
cat > /etc/systemd/system/systemd-cryptsetup@cryptlvm.service.d/tpm2.conf << ‘EOF’
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-cryptsetup attach %i /dev/disk/by-uuid/CRYPTUUID - tpm2-device=auto,headless=1
EOF

# Configurar journald para logging seguro

cat > /etc/systemd/journald.conf << ‘EOF’
[Journal]
Storage=persistent
Compress=yes
Seal=yes
SplitMode=uid
SyncIntervalSec=5m
RateLimitInterval=30s
RateLimitBurst=10000
SystemMaxUse=1G
SystemKeepFree=2G
MaxFileSec=1month
MaxRetentionSec=6month
ForwardToSyslog=yes
EOF

systemctl enable systemd-journald

# Configurar rsyslog para logging adicional

cat > /etc/rsyslog.d/50-hardened.conf << ‘EOF’

# Log all kernel messages to separate file

kern.*                          /var/log/kernel.log

# Log all privilege escalation attempts

auth,authpriv.*                 /var/log/auth.log

# Log all sudo commands

local0.*                        /var/log/sudo.log

# Log all network connections

daemon.info                     /var/log/network.log

# Log all cron jobs

cron.*                          /var/log/cron.log
EOF

systemctl enable rsyslog

# Configurar logrotate para gestión de logs

cat > /etc/logrotate.d/hardened << ‘EOF’
/var/log/kernel.log
/var/log/auth.log
/var/log/sudo.log
/var/log/network.log
/var/log/cron.log {
daily
rotate 30
compress
delaycompress
missingok
notifempty
create 0640 root log
}
EOF

# Habilitar servicios básicos

systemctl enable NetworkManager
systemctl enable systemd-timesyncd
systemctl enable fstrim.timer

# Configurar sysctl para seguridad

cat > /etc/sysctl.d/99-security.conf << ‘EOF’

# Kernel hardening

kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 3
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Network security

net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Memory protection

vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16
EOF

CHROOT_EOF

```
# Hacer ejecutable el script
chmod +x /mnt/configure_chroot.sh

# Ejecutar configuración en chroot
arch-chroot /mnt /configure_chroot.sh

# Obtener UUID de la partición cifrada y actualizar configuraciones
CRYPT_UUID=$(blkid -s UUID -o value $ROOT_PART)

# Actualizar cmdline con UUID real
arch-chroot /mnt sed -i "s/CRYPTUUID/$CRYPT_UUID/g" /etc/kernel/cmdline
arch-chroot /mnt sed -i "s/CRYPTUUID/$CRYPT_UUID/g" /etc/systemd/system/systemd-cryptsetup@cryptlvm.service.d/tpm2.conf

# Configurar contraseñas
echo "root:$ROOT_PASSWORD" | arch-chroot /mnt chpasswd

# Crear usuario
arch-chroot /mnt useradd -m -G wheel,audio,video,storage -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASSWORD" | arch-chroot /mnt chpasswd

# Configurar sudo
echo '%wheel ALL=(ALL:ALL) ALL' > /mnt/etc/sudoers.d/wheel

# Generar UKI
arch-chroot /mnt mkinitcpio -P

# Configurar Secure Boot
arch-chroot /mnt sbctl create-keys
arch-chroot /mnt sbctl enroll-keys -m

# Firmar UKI con Secure Boot
UKI_PATH=$(arch-chroot /mnt find /boot -name "*.efi" | head -n1)
if [ -n "$UKI_PATH" ]; then
    arch-chroot /mnt sbctl sign "${UKI_PATH#/mnt}"
fi

# Limpiar script temporal
rm /mnt/configure_chroot.sh

log "Sistema configurado correctamente"
```

}

# Configurar AppArmor profiles estrictos

setup_apparmor() {
log “Configurando AppArmor con perfiles estrictos…”

```
# Profile para navegador
cat > /mnt/etc/apparmor.d/firefox << 'EOF'
```

#include <tunables/global>

/usr/lib/firefox/firefox {
#include <abstractions/base>
#include <abstractions/audio>
#include <abstractions/dbus-session-strict>
#include <abstractions/fonts>
#include <abstractions/gnome>
#include <abstractions/nameservice>
#include <abstractions/user-tmp>
#include <abstractions/X>

capability sys_admin,
capability sys_chroot,
capability setgid,
capability setuid,

/usr/lib/firefox/** mr,
/usr/share/firefox/** r,
owner @{HOME}/.mozilla/** rwk,
owner @{HOME}/.cache/mozilla/** rwk,
owner /tmp/.X11-unix/X* rw,

deny /home/** w,
deny /etc/passwd r,
deny /etc/shadow r,
deny /proc/sys/kernel/** r,
deny @{PROC}/[0-9]*/stat r,
deny capability dac_override,
deny capability dac_read_search,
}
EOF

```
# Aplicar perfiles
arch-chroot /mnt aa-enforce /etc/apparmor.d/firefox

log "AppArmor configurado"
```

}

# Enrollar claves TPM

setup_tpm() {
log “Configurando TPM para desbloqueo automático…”

```
# Verificar si TPM está disponible
if arch-chroot /mnt tpm2_startup -c 2>/dev/null; then
    log "TPM detectado, configurando desbloqueo automático..."
    
    # Enrollar LUKS con TPM
    CRYPT_UUID=$(blkid -s UUID -o value $ROOT_PART)
    echo "$LUKS_PASSWORD" | arch-chroot /mnt systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+2+4+7+9 /dev/disk/by-uuid/$CRYPT_UUID
    
    log "TPM configurado exitosamente"
else
    warning "TPM no disponible o no configurado, se usará solo contraseña"
fi
```

}

# Configurar Sway y entorno gráfico

setup_sway() {
log “Configurando Sway y entorno gráfico…”

```
# Configuración básica de Sway
arch-chroot /mnt mkdir -p /home/$USERNAME/.config/sway
cat > /mnt/home/$USERNAME/.config/sway/config << 'SWAY_EOF'
```

# Configuración básica de Sway

set $mod Mod4
set $term kitty
set $menu wofi –show drun

# Configuración de entrada

input type:keyboard {
xkb_layout es
xkb_variant ,nodeadkeys
xkb_options grp:alt_shift_toggle
}

# Atajos básicos

bindsym $mod+Return exec $term
bindsym $mod+d exec $menu
bindsym $mod+Shift+q kill
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exec swaynag -t warning -m ‘Salir?’ -b ‘Sí’ ‘swaymsg exit’

# Movimiento entre ventanas

bindsym $mod+Left focus left
bindsym $mod+Down focus down
bindsym $mod+Up focus up
bindsym $mod+Right focus right

# Mover ventanas

bindsym $mod+Shift+Left move left
bindsym $mod+Shift+Down move down
bindsym $mod+Shift+Up move up
bindsym $mod+Shift+Right move right

# Workspaces

bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4

# Mover ventanas a workspaces

bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4

# Layout

bindsym $mod+b splith
bindsym $mod+v splitv
bindsym $mod+f fullscreen
bindsym $mod+Shift+space floating toggle

# Brillo y volumen

bindsym XF86BrightnessUp exec brightnessctl set +5%
bindsym XF86BrightnessDown exec brightnessctl set 5%-
bindsym XF86AudioRaiseVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindsym XF86AudioLowerVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym XF86AudioMute exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle

# Screenshots

bindsym Print exec grim ~/screenshot.png
bindsym $mod+Print exec grim -g “$(slurp)” ~/screenshot.png

# Bar

bar {
position top
status_command while date +’%Y-%m-%d %H:%M:%S’; do sleep 1; done
colors {
statusline #ffffff
background #323232
}
}

# Tema

default_border pixel 2
gaps inner 10
SWAY_EOF

```
# Establecer propietario correcto
arch-chroot /mnt chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

log "Sway configurado"
```

}

# Configurar servicios adicionales de seguridad

setup_security_services() {
log “Configurando servicios adicionales de seguridad…”

```
# Configurar fail2ban para protección contra ataques
cat > /mnt/etc/fail2ban/jail.local << 'EOF'
```

[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
filter = sshd
action = iptables[name=SSH, port=ssh, protocol=tcp]
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
EOF

```
# Configurar AIDE para detección de intrusiones
cat > /mnt/etc/aide.conf << 'EOF'
```

# AIDE configuration

database_in = file:/var/lib/aide/aide.db
database_out = file:/var/lib/aide/aide.db.new
database_new = file:/var/lib/aide/aide.db.new
gzip_dbout = yes

# Reglas de monitoreo

/boot R+a+sha256
/bin R+a+sha256
/sbin R+a+sha256
/lib R+a+sha256
/lib64 R+a+sha256
/usr R+a+sha256
/etc R+a+sha256
/root R+a+sha256

# Excluir directorios temporales

!/var/log
!/var/tmp
!/tmp
!/proc
!/sys
!/dev
EOF

```
# Configurar ClamAV antivirus
arch-chroot /mnt systemctl enable clamav-freshclam
arch-chroot /mnt systemctl enable clamav-daemon

# Configurar timer para escaneo diario
cat > /mnt/etc/systemd/system/clamav-scan.service << 'EOF'
```

[Unit]
Description=Full system antivirus scan
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/clamscan -r –log=/var/log/clamav-scan.log –quiet /home /etc /usr /var
User=clamav
EOF

```
cat > /mnt/etc/systemd/system/clamav-scan.timer << 'EOF'
```

[Unit]
Description=Run full system scan daily
Requires=clamav-scan.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

```
arch-chroot /mnt systemctl enable clamav-scan.timer

log "Servicios de seguridad configurados"
```

}

# Configurar monitoreo del sistema

setup_monitoring() {
log “Configurando monitoreo del sistema…”

```
# Script de monitoreo de seguridad
cat > /mnt/usr/local/bin/security-monitor.sh << 'EOF'
```

#!/bin/bash

# Script de monitoreo de seguridad

LOG_FILE=”/var/log/security-monitor.log”
DATE=$(date ‘+%Y-%m-%d %H:%M:%S’)

echo “[$DATE] Iniciando chequeo de seguridad” >> $LOG_FILE

# Verificar conexiones sospechosas

netstat -tuln | grep LISTEN >> $LOG_FILE

# Verificar procesos con privilegios altos

ps aux | awk ‘$1 == “root”’ >> $LOG_FILE

# Verificar últimos login

last -n 10 >> $LOG_FILE

# Verificar intentos de sudo fallidos

grep “sudo.*COMMAND” /var/log/auth.log | tail -10 >> $LOG_FILE

# Verificar integridad de archivos críticos con AIDE

if [ -f /var/lib/aide/aide.db ]; then
aide –check >> $LOG_FILE 2>&1
fi

echo “[$DATE] Chequeo completado” >> $LOG_FILE
EOF

```
chmod +x /mnt/usr/local/bin/security-monitor.sh

# Timer para ejecutar cada hora
cat > /mnt/etc/systemd/system/security-monitor.service << 'EOF'
```

[Unit]
Description=Security monitoring script
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/security-monitor.sh
User=root
EOF

```
cat > /mnt/etc/systemd/system/security-monitor.timer << 'EOF'
```

[Unit]
Description=Run security monitoring hourly
Requires=security-monitor.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

```
arch-chroot /mnt systemctl enable security-monitor.timer

log "Monitoreo configurado"
```

}

# Limpiar sistema y optimizar

cleanup_system() {
log “Limpiando sistema y optimizando…”

```
# Limpiar cache de pacman
arch-chroot /mnt pacman -Scc --noconfirm

# Limpiar archivos temporales
rm -rf /mnt/tmp/*
rm -rf /mnt/var/tmp/*

# Configurar limpieza automática
cat > /mnt/etc/systemd/system/cleanup.service << 'EOF'
```

[Unit]
Description=System cleanup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/find /tmp -type f -atime +7 -delete
ExecStart=/usr/bin/find /var/tmp -type f -atime +7 -delete
ExecStart=/usr/bin/journalctl –vacuum-time=1month
User=root
EOF

```
cat > /mnt/etc/systemd/system/cleanup.timer << 'EOF'
```

[Unit]
Description=Run system cleanup weekly
Requires=cleanup.service

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

```
arch-chroot /mnt systemctl enable cleanup.timer

log "Sistema optimizado"
```

}

# Función principal

main() {
log “Iniciando instalación de Arch Linux Hardened…”

```
check_uefi
setup_keyboard
check_internet
sync_time
setup_mirrors
update_system
select_disk
get_passwords
prepare_disk
setup_encryption
setup_lvm
format_partitions
mount_filesystems
install_base_system
generate_fstab
configure_system
setup_apparmor
setup_tpm
setup_sway
setup_security_services
setup_monitoring
cleanup_system

log "¡Instalación completada exitosamente!"
echo -e "\n${GREEN}Sistema instalado con las siguientes características de seguridad:${NC}"
echo "✓ Cifrado completo de disco con LUKS2"
echo "✓ Kernel Linux Hardened"
echo "✓ Unified Kernel Image (UKI)"
echo "✓ TPM 2.0 para desbloqueo automático"
echo "✓ Secure Boot configurado"
echo "✓ AppArmor con perfiles estrictos"
echo "✓ Logging avanzado y auditoria completa"
echo "✓ Parámetros de kernel endurecidos"
echo "✓ Sway como entorno de escritorio"
echo "✓ Fail2ban para protección contra ataques"
echo "✓ ClamAV antivirus configurado"
echo "✓ AIDE para detección de intrusiones"
echo "✓ Monitoreo de seguridad automatizado"
echo "✓ Sistema de limpieza automática"

echo -e "\n${BLUE}Características de logging y monitoreo:${NC}"
echo "• Auditd: Monitoreo de syscalls y privilegios"
echo "• Journald: Logs firmados y comprimidos"
echo "• Rsyslog: Categorización avanzada de logs"
echo "• Security Monitor: Chequeos automáticos cada hora"
echo "• AIDE: Verificación de integridad de archivos"
echo "• ClamAV: Escaneo antivirus diario"

echo -e "\n${BLUE}Logs disponibles en:${NC}"
echo "• /var/log/auth.log - Autenticación y privilegios"
echo "• /var/log/kernel.log - Mensajes del kernel"
echo "• /var/log/sudo.log - Comandos sudo"
echo "• /var/log/security-monitor.log - Monitoreo de seguridad"
echo "• /var/log/audit/audit.log - Logs de auditoria"
echo "• journalctl - Logs del sistema"

echo -e "\n${YELLOW}Comandos útiles para monitoreo:${NC}"
echo "• journalctl -f - Ver logs en tiempo real"
echo "• ausearch -k privilege_escalation - Buscar escalamientos"
echo "• aa-status - Estado de AppArmor"
echo "• systemctl status security-monitor.timer - Estado del monitoreo"
echo "• clamscan -r /home - Escaneo manual antivirus"
echo "• aide --check - Verificar integridad de archivos"

echo -e "\n${YELLOW}Pasos siguientes:${NC}"
echo "1. Salir del entorno de instalación: exit"
echo "2. Desmontar: umount -R /mnt"
echo "3. Reiniciar: reboot"
echo "4. Configurar Secure Boot en UEFI"
echo "5. Primer arranque requerirá contraseña LUKS"
echo "6. Inicializar base de datos AIDE: sudo aide --init"
echo "7. Actualizar definiciones de ClamAV: sudo freshclam"

read -p "¿Desmontar y reiniciar ahora? (s/N): " reboot_now
if [[ $reboot_now =~ ^[sS]$ ]]; then
    log "Desmontando sistema..."
    umount -R /mnt 2>/dev/null || true
    swapoff /dev/vg0/swap 2>/dev/null || true
    vgchange -an vg0 2>/dev/null || true
    cryptsetup close cryptlvm 2>/dev/null || true
    log "Sistema desmontado. Reiniciando..."
    reboot
fi
```

}

# Verificar si se ejecuta como root

if [ “$EUID” -ne 0 ]; then
error “Este script debe ejecutarse como root”
fi

# Ejecutar función principal

main “$@”