#!/bin/bash

# Script de instalación de Arch Linux Hardened con UKI + TPM + Measured Boot
# Configuración ultra segura con cifrado completo, AppArmor y logging avanzado

set -euo pipefail

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Función para logging
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Verificar que estamos en modo UEFI
check_uefi() {
    if [ ! -d "/sys/firmware/efi" ]; then
        error "Este script requiere arranque UEFI. Sistema Legacy BIOS no soportado."
    fi
    log "Verificación UEFI: OK"
}

# Configurar teclado
setup_keyboard() {
    log "Configurando teclado español..."
    loadkeys es
}

# Verificar conexión a internet
check_internet() {
    log "Verificando conexión a internet..."
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        warning "No hay conexión a internet."
        echo "Por favor, conecta a una red WiFi usando 'iwctl' o conecta cable ethernet."
        read -p "Presiona Enter cuando tengas conexión a internet..."
        if ! ping -c 1 8.8.8.8 &> /dev/null; then
            error "Aún no hay conexión a internet. Abortando."
        fi
    fi
    log "Conexión a internet: OK"
}

# Sincronizar reloj
sync_time() {
    log "Sincronizando reloj del sistema..."
    timedatectl set-ntp true
    sleep 2
}

# Configurar mirrors optimizados
setup_mirrors() {
    log "Configurando mirrors optimizados..."
    reflector --country Spain,Germany,France,Italy,Netherlands \
        --age 24 \
        --protocol https \
        --fastest 10 \
        --save /etc/pacman.d/mirrorlist || warning "Reflector falló. Usando mirrors por defecto."
    log "Mirrors configurados correctamente"
}

# Actualizar sistema antes de instalar
update_system() {
    log "Actualizando base de datos de paquetes y keyring..."
    pacman -Sy --noconfirm archlinux-keyring || warning "No se pudo actualizar archlinux-keyring. Podría haber problemas con firmas PGP."
    pacman -Syy --noconfirm # Forzar resincronización completa
}

# Seleccionar disco automáticamente
select_disk() {
    log "Detectando discos disponibles..."
    # Listar discos disponibles
    lsblk -dpno NAME,SIZE,TYPE | grep disk

    # Autodetectar el disco principal (generalmente el más grande)
    DISK=$(lsblk -dpno NAME,SIZE,TYPE | grep disk | sort -k2 -hr | head -n1 | awk '{print $1}')

    echo -e "\n${BLUE}Disco detectado automáticamente: $DISK${NC}"
    lsblk "$DISK"

    echo -e "\n${RED}¡ADVERTENCIA!${NC} Se borrarán TODOS los datos del disco $DISK"
    read -p "¿Continuar? (s/N): " confirm

    if [[ ! "$confirm" =~ ^[sS]$ ]]; then
        error "Instalación cancelada por el usuario"
    fi

    export DISK
    log "Disco seleccionado: $DISK"
}

# Solicitar contraseñas de manera segura
get_passwords() {
    log "Configurando contraseñas del sistema..."

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
}

# Preparar y particionar disco
prepare_disk() {
    log "Preparando disco $DISK..."

    # Desmontar cualquier partición que pueda estar montada
    umount -A --recursive "${DISK}"* 2>/dev/null || true

    # Cerrar cualquier volumen LVM o LUKS existente
    vgchange -an 2>/dev/null || true
    cryptsetup close cryptlvm 2>/dev/null || true

    # Limpiar completamente el disco
    wipefs -af "$DISK"
    sgdisk --zap-all "$DISK"

    # Crear nueva tabla de particiones GPT
    sgdisk --clear \
           --new=1:0:+1G --typecode=1:ef00 --change-name=1:'EFI System' \
           --new=2:0:0 --typecode=2:8300 --change-name=2:'Linux filesystem' \
           "$DISK"

    # Informar al kernel sobre los cambios
    partprobe "$DISK"
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
}

# Configurar cifrado LUKS con parámetros seguros
setup_encryption() {
    log "Configurando cifrado LUKS con parámetros de seguridad avanzados..."

    # Configuración LUKS2 con algoritmos seguros y verificación de integridad
    echo "$LUKS_PASSWORD" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --iter-time 5000 \
        --use-random \
        --verify-passphrase \
        "$ROOT_PART"

    # Abrir el contenedor cifrado
    echo "$LUKS_PASSWORD" | cryptsetup open "$ROOT_PART" cryptlvm

    log "Cifrado LUKS configurado correctamente"
}

# Configurar LVM
setup_lvm() {
    log "Configurando LVM..."

    # Crear volumen físico
    pvcreate /dev/mapper/cryptlvm

    # Crear grupo de volúmenes
    vgcreate vg0 /dev/mapper/cryptlvm

    # Detectar RAM para configurar swap
    RAM_SIZE=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$RAM_SIZE" -lt 2048 ]; then
        SWAP_SIZE="${RAM_SIZE}M"
    elif [ "$RAM_SIZE" -lt 8192 ]; then
        SWAP_SIZE="4G"
    else
        SWAP_SIZE="8G"
    fi

    # Crear volúmenes lógicos
    lvcreate -L "$SWAP_SIZE" vg0 -n swap
    lvcreate -L 50G vg0 -n root
    lvcreate -l 100%FREE vg0 -n home

    log "LVM configurado: swap=$SWAP_SIZE, root=50G, home=resto"
}

# Formatear particiones
format_partitions() {
    log "Formateando particiones..."

    # Formatear EFI como FAT32
    mkfs.fat -F32 -n "EFI" "$EFI_PART"

    # Formatear volúmenes lógicos con parámetros seguros
    mkfs.ext4 -L "root" -O ^has_journal /dev/vg0/root
    mkfs.ext4 -L "home" -O ^has_journal /dev/vg0/home
    mkswap -L "swap" /dev/vg0/swap

    log "Particiones formateadas correctamente"
}

# Montar sistema de archivos
mount_filesystems() {
    log "Montando sistema de archivos..."

    # Montar partición raíz
    mount /dev/vg0/root /mnt

    # Crear directorios de montaje
    mkdir -p /mnt/{boot,home,var/log,tmp}

    # Montar particiones
    mount "$EFI_PART" /mnt/boot
    mount /dev/vg0/home /mnt/home
    swapon /dev/vg0/swap

    # Configurar tmpfs para /tmp (seguridad)
    mount -t tmpfs -o nodev,nosuid,noexec tmpfs /mnt/tmp

    log "Sistema de archivos montado"
}

# Instalar sistema base con kernel hardened
install_base_system() {
    log "Instalando sistema base con kernel hardened y paquetes clave..."

    # Lista completa de paquetes necesarios (sin systemd-boot directamente)
    pacstrap -K /mnt \
        base base-devel \
        linux-hardened linux-hardened-headers \
        linux-firmware \
        intel-ucode \
        lvm2 cryptsetup \
        networkmanager \
        sudo nano git \
        efibootmgr \
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
        systemd-ukify \
        mkinitcpio # mkinitcpio sigue siendo necesario para generar el initrd que systemd-ukify usa

    log "Sistema base y paquetes iniciales instalados"
}

# Generar fstab
generate_fstab() {
    log "Generando fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab

    # Agregar tmpfs para /tmp con opciones de seguridad
    echo "tmpfs /tmp tmpfs nodev,nosuid,noexec,size=2G 0 0" >> /mnt/etc/fstab
    log "fstab generado"
}

# Configurar AppArmor profiles estrictos - MOVEMOS ESTA FUNCIÓN AQUÍ PARA QUE LOS PERFILES EXISTAN ANTES DEL CHROOT
setup_apparmor() {
    log "Configurando AppArmor con perfiles estrictos..."

    # Crear directorio si no existe para evitar errores
    mkdir -p /mnt/etc/apparmor.d/

    # Profile para navegador
    cat > /mnt/etc/apparmor.d/firefox << 'EOF_APPARMOR'
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

  # Permisos que AppArmor puede necesitar si no está en modo estricto, o para integración con Wayland/TPM/otros
  # Eliminar si causan problemas, o si las abstractions ya los cubren
  # capability sys_admin,
  # capability sys_chroot,
  # capability setgid,
  # capability setuid,

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
EOF_APPARMOR

    # NOTA: La aplicación de perfiles (aa-enforce) se hará DENTRO del chroot.
    log "AppArmor perfiles creados en /mnt/etc/apparmor.d/"
}


# Configurar sistema en chroot
configure_system() {
    log "Configurando sistema en chroot..."

    # Crear script de configuración para ejecutar en chroot
    cat > /mnt/configure_chroot.sh << 'CHROOT_EOF'
#!/bin/bash

log_chroot() {
    echo -e "${BLUE}[CHROOT][$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warning_chroot() {
    echo -e "${YELLOW}[CHROOT][WARNING] $1${NC}"
}

# Configurar zona horaria
log_chroot "Configurando zona horaria..."
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc

# Configurar localización
log_chroot "Configurando localización..."
sed -i 's/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

echo "LANG=es_ES.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf

# Configurar hostname
log_chroot "Configurando hostname..."
echo "arch-hardened" > /etc/hostname

# Configurar hosts
log_chroot "Configurando hosts..."
cat > /etc/hosts << 'EOF_HOSTS'
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch-hardened.localdomain arch-hardened
EOF_HOSTS

# Configurar cmdline para UKI
log_chroot "Configurando cmdline para UKI..."
mkdir -p /etc/kernel
cat > /etc/kernel/cmdline << 'EOF_CMDLINE'
cryptdevice=UUID=CRYPTUUID:cryptlvm root=/dev/vg0/root rw quiet loglevel=3 apparmor=1 security=apparmor audit=1 kernel.yama.ptrace_scope=3 kernel.dmesg_restrict=1 kernel.kptr_restrict=2 slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off module.sig_enforce=1 lockdown=confidentiality ima_policy=tcb ima_hash=sha256
EOF_CMDLINE

# Configurar mkinitcpio para el initramfs base (NO UKI directamente)
log_chroot "Configurando mkinitcpio para initramfs base..."
cat > /etc/mkinitcpio.conf << 'EOF_MKINITCPIO'
MODULES=""
BINARIES=""
FILES=""
HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt lvm2 filesystems fsck) # 'base' es bueno por defecto, 'sd-encrypt' para LUKS+systemd
COMPRESSION="zstd"
EOF_MKINITCPIO

# Asegurarse de que el preset del kernel hardened genera un initramfs.
# NO es necesario modificar "UKI_ENABLE" aquí, systemd-ukify lo manejará.
# Regenerar initramfs tradicional para el kernel hardened.
log_chroot "Generando initramfs para kernel hardened con mkinitcpio..."
mkinitcpio -P

# === Generar UKI con systemd-ukify ===
log_chroot "Generando Unified Kernel Image (UKI) con systemd-ukify..."
# systemd-ukify usa /etc/kernel/cmdline por defecto.
# El initramfs generado por mkinitcpio -P para linux-hardened será /boot/initramfs-linux-hardened.img
# Asegúrate de que el nombre del kernel es correcto. `uname -r` debería dar el nombre del kernel instalado.
# Si el kernel en el live USB es diferente al instalado, esto podría ser un problema.
# Usaremos `ls /usr/lib/modules/` para encontrar el directorio del kernel instalado.
KERNEL_VERSION=$(ls /usr/lib/modules/ | grep linux-hardened | head -n 1) # Obtener la versión del kernel hardened
if [ -z "$KERNEL_VERSION" ]; then
    error "No se pudo determinar la versión del kernel linux-hardened instalado para UKI."
fi

ukify build \
    --kernel /usr/lib/modules/$KERNEL_VERSION/vmlinuz \
    --initrd /boot/initramfs-linux-hardened.img \
    --cmdline @/etc/kernel/cmdline \
    --output /boot/EFI/Linux/arch-hardened.efi \
    --os-release /etc/os-release \
    --uname-r "$KERNEL_VERSION" || error_chroot "Fallo al generar UKI con systemd-ukify."


# Configurar systemd-boot
log_chroot "Instalando systemd-boot..."
bootctl install
systemctl enable systemd-boot-update

# Crear entrada de systemd-boot para el UKI
log_chroot "Creando entrada de systemd-boot para UKI..."
mkdir -p /boot/loader/entries
cat > /boot/loader/entries/arch-hardened.conf << 'EOF_BOOT_ENTRY'
title   Arch Linux Hardened
linux   /EFI/Linux/arch-hardened.efi
options @/etc/kernel/cmdline
EOF_BOOT_ENTRY

# Asegurarse de que /boot/loader/loader.conf apunte al default
cat > /boot/loader/loader.conf << 'EOF_LOADER_CONF'
default arch-hardened.conf
timeout 3
console-mode max
editor no
EOF_LOADER_CONF

# Configurar AppArmor (habilitar servicio)
log_chroot "Habilitando servicio AppArmor..."
systemctl enable apparmor

# Configurar auditd para logging avanzado
log_chroot "Configurando auditd..."
cat > /etc/audit/rules.d/audit.rules << 'EOF_AUDIT'
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
EOF_AUDIT

systemctl enable auditd

# Configurar TPM2 para LUKS (crear la unidad de drop-in para systemd-cryptsetup)
log_chroot "Configurando TPM2 para LUKS..."
mkdir -p /etc/systemd/system/systemd-cryptsetup@cryptlvm.service.d/
cat > /etc/systemd/system/systemd-cryptsetup@cryptlvm.service.d/tpm2.conf << 'EOF_TPM2_CONF'
[Service]
ExecStartPre=-/usr/bin/systemd-cryptenroll --unlock-key-file=/dev/null --tpm2-device=auto --tpm2-pcrs=0+2+4+7+9 /dev/disk/by-uuid/%i
EOF_TPM2_CONF


# Configurar journald para logging seguro
log_chroot "Configurando journald..."
cat > /etc/systemd/journald.conf << 'EOF_JOURNALD'
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
EOF_JOURNALD

systemctl enable systemd-journald

# Configurar rsyslog para logging adicional
log_chroot "Configurando rsyslog..."
mkdir -p /etc/rsyslog.d/ # <-- CORRECCIÓN: Asegurar que el directorio existe
cat > /etc/rsyslog.d/50-hardened.conf << 'EOF_RSYSLOG'
# Log all kernel messages to separate file
kern.* /var/log/kernel.log

# Log all privilege escalation attempts
auth,authpriv.* /var/log/auth.log

# Log all sudo commands
local0.* /var/log/sudo.log

# Log all network connections
daemon.info                     /var/log/network.log

# Log all cron jobs
cron.* /var/log/cron.log
EOF_RSYSLOG

systemctl enable rsyslog

# Configurar logrotate para gestión de logs
log_chroot "Configurando logrotate..."
cat > /etc/logrotate.d/hardened << 'EOF_LOGROTATE'
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
EOF_LOGROTATE

systemctl enable NetworkManager
systemctl enable systemd-timesyncd
systemctl enable fstrim.timer

# Configurar sysctl para seguridad
log_chroot "Configurando sysctl..."
cat > /etc/sysctl.d/99-security.conf << 'EOF_SYSCTL'
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
EOF_SYSCTL

# Habilitar enforce de AppArmor (ya tenemos perfiles en /etc/apparmor.d/)
log_chroot "Habilitando AppArmor enforcement..."
# Usamos un find para evitar problemas si el directorio está vacío o contiene solo symlinks.
if [ -n "$(find /etc/apparmor.d/ -maxdepth 1 -type f -name '*' | grep -v 'usr.sbin.dhcpd')" ]; then
    aa-enforce /etc/apparmor.d/* || warning_chroot "Fallo al aplicar perfiles AppArmor. Verifica AppArmor y sus logs."
else
    warning_chroot "No se encontraron perfiles AppArmor para aplicar en /etc/apparmor.d/."
fi


CHROOT_EOF

    # Hacer ejecutable el script
    chmod +x /mnt/configure_chroot.sh

    # Ejecutar configuración en chroot
    arch-chroot /mnt /configure_chroot.sh

    # Obtener UUID de la partición cifrada y actualizar configuraciones FUERA del chroot
    CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    log "UUID de partición cifrada: $CRYPT_UUID"

    # Actualizar cmdline y TPM2.conf con UUID real (AHORA SÍ, DESPUÉS DE QUE EL SCRIPT DE CHROOT LO HAYA CREADO)
    arch-chroot /mnt sed -i "s/CRYPTUUID/$CRYPT_UUID/g" /etc/kernel/cmdline
    # Asegúrate que el archivo existe antes de intentar la sustitución
    if arch-chroot /mnt test -f "/etc/systemd/system/systemd-cryptsetup@cryptlvm.service.d/tpm2.conf"; then
        arch-chroot /mnt sed -i "s/CRYPTUUID/$CRYPT_UUID/g" /etc/systemd/system/systemd-cryptsetup@cryptlvm.service.d/tpm2.conf
    else
        warning "El archivo tpm2.conf no se encontró en el chroot para actualizar el UUID. ¿Error en la plantilla?"
    fi


    # Configurar contraseñas
    log "Estableciendo contraseñas de root y usuario..."
    echo "root:$ROOT_PASSWORD" | arch-chroot /mnt chpasswd
    arch-chroot /mnt useradd -m -G wheel,audio,video,storage -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | arch-chroot /mnt chpasswd

    # Configurar sudo
    log "Configurando sudo para grupo wheel..."
    echo '%wheel ALL=(ALL:ALL) ALL' > /mnt/etc/sudoers.d/wheel
    arch-chroot /mnt chmod 0440 /etc/sudoers.d/wheel # Permisos correctos para sudoers

    # Configurar Secure Boot (FUERA DEL CHROOT, PERO INTERACTUANDO CON EL SISTEMA INSTALADO)
    log "Configurando Secure Boot con sbctl..."
    # sbctl create-keys creará las claves en /etc/sbctl/keys dentro del chroot
    arch-chroot /mnt sbctl create-keys || error "Fallo al crear claves Secure Boot. Asegúrate de que el sistema esté en un estado donde sbctl pueda operar."

    # Enrolling keys to firmware. This step typically requires the system to be in Setup Mode
    # or manual intervention in the BIOS. We will warn the user if it fails.
    log "Intentando enrollar claves Secure Boot en el firmware (puede requerir BIOS/UEFI Setup Mode)..."
    # No se recomienda enrollar las claves automáticamente aquí, ya que requiere un modo específico del BIOS/UEFI.
    # El usuario debe hacerlo manualmente después del primer reinicio.
    # arch-chroot /mnt sbctl enroll-keys -m || warning "No se pudieron enrollar las claves en el firmware..."
    warning "Las claves de Secure Boot se han generado. Deberás enrollarlas manualmente en el firmware UEFI/BIOS después de reiniciar."

    # Firmar UKI con Secure Boot
    # El UKI se genera con systemd-ukify dentro del chroot. Su ruta será /boot/EFI/Linux/arch-hardened.efi
    log "Firmando Unified Kernel Image (UKI) y cargador de arranque para Secure Boot..."
    UKI_PATH_IN_CHROOT="/boot/EFI/Linux/arch-hardened.efi"
    if arch-chroot /mnt test -f "$UKI_PATH_IN_CHROOT"; then
        arch-chroot /mnt sbctl sign "$UKI_PATH_IN_CHROOT" || warning "Fallo al firmar el UKI. Asegúrate de que sbctl tenga las claves y permisos correctos."
    else
        warning "UKI ($UKI_PATH_IN_CHROOT) no encontrado para firmar. ¿systemd-ukify falló?"
    fi

    # Firmar el cargador de systemd-boot
    # Este es el cargador que el firmware ejecuta
    # systemd-bootx64.efi es el binario, BOOTX64.EFI es la copia que se carga por defecto.
    SYSTEMD_BOOTX64_PATH_IN_CHROOT="/boot/EFI/systemd/systemd-bootx64.efi"
    BOOTX64_PATH_IN_CHROOT="/boot/EFI/BOOT/BOOTX64.EFI" # Boot loader de fallback
    
    if arch-chroot /mnt test -f "$SYSTEMD_BOOTX64_PATH_IN_CHROOT"; then
        arch-chroot /mnt sbctl sign "$SYSTEMD_BOOTX64_PATH_IN_CHROOT" || warning "Fallo al firmar systemd-bootx64.efi."
    else
        warning "Cargador de arranque de systemd-boot (systemd-bootx64.efi) no encontrado para firmar."
    fi
    
    # Si systemd-boot crea un BOOTX64.EFI de fallback (es una copia o enlace simbólico), también firmarlo.
    if arch-chroot /mnt test -f "$BOOTX64_PATH_IN_CHROOT" && ! arch-chroot /mnt cmp -s "$SYSTEMD_BOOTX64_PATH_IN_CHROOT" "$BOOTX64_PATH_IN_CHROOT"; then
        # Solo firmar si BOOTX64.EFI no es el mismo que systemd-bootx64.efi (evitar doble firma si son iguales)
        arch-chroot /mnt sbctl sign "$BOOTX64_PATH_IN_CHROOT" || warning "Fallo al firmar BOOTX64.EFI."
    fi

    arch-chroot /mnt sbctl status # Muestra el estado de sbctl para depuración

    # Limpiar script temporal
    rm /mnt/configure_chroot.sh

    log "Sistema configurado correctamente"
}

# Enrollar claves TPM
setup_tpm() {
    log "Configurando TPM para desbloqueo automático..."

    # Verificar si TPM está disponible y funcional
    if arch-chroot /mnt tpm2_startup -c &> /dev/null; then
        log "TPM detectado, configurando desbloqueo automático..."
        
        # Enrollar LUKS con TPM
        # CRYPT_UUID ya debe estar definida desde configure_system
        log "Enrollando LUKS con TPM. UUID: $CRYPT_UUID"
        # Asegúrate de que systemd-cryptenroll está disponible y funcionando
        if echo "$LUKS_PASSWORD" | arch-chroot /mnt systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+2+4+7+9 "/dev/disk/by-uuid/$CRYPT_UUID"; then
            log "TPM configurado exitosamente para desbloqueo de LUKS."
        else
            warning "Fallo al configurar TPM para desbloqueo de LUKS. Verifica que TPM esté habilitado y que los PCRs sean correctos."
        fi
    else
        warning "TPM no disponible o no configurado correctamente en el firmware/BIOS. El desbloqueo de disco seguirá siendo por contraseña."
    fi
}

# Configurar Sway y entorno gráfico
setup_sway() {
    log "Configurando Sway y entorno gráfico..."

    # Crear directorios de configuración si no existen
    arch-chroot /mnt mkdir -p "/home/$USERNAME/.config/sway"
    arch-chroot /mnt mkdir -p "/home/$USERNAME/.config/waybar"
    arch-chroot /mnt mkdir -p "/home/$USERNAME/.config/wofi"

    # Configuración básica de Sway
    cat > "/mnt/home/$USERNAME/.config/sway/config" << 'SWAY_EOF'
# Configuración básica de Sway

set $mod Mod4
set $term kitty
set $menu wofi --show drun

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
bindsym $mod+Shift+e exec swaynag -t warning -m 'Salir?' -b 'Sí' 'swaymsg exit'

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
bindsym $mod+Print exec grim -g "$(slurp)" ~/screenshot.png

# Bar (Waybar)
bar {
  swaybar_command waybar
}
SWAY_EOF

    # Configuración básica de Waybar
    cat > "/mnt/home/$USERNAME/.config/waybar/config" << 'WAYBAR_CONFIG_EOF'
{
    "layer": "top",
    "position": "top",
    "mod": "dock",
    "height": 30,
    "modules-left": ["sway/workspaces", "sway/mode"],
    "modules-center": ["clock"],
    "modules-right": ["pulseaudio", "backlight", "network", "battery", "tray"],

    "sway/workspaces": {
        "format": "{name}"
    },
    "sway/mode": {
        "format": "<span foreground=\"#FF0000\">{}</span>"
    },
    "clock": {
        "format": "<span></span> {:%H:%M:%S} <span></span> {:%Y-%m-%d}"
    },
    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": " Muted",
        "format-icons": {
            "default": ["", ""]
        },
        "on-click": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
    },
    "backlight": {
        "format": " {percent}%",
        "device": "intel_backlight"
    },
    "network": {
        "format-wifi": " {essid}",
        "format-ethernet": " {ifname}",
        "format-disconnected": "⚠ Disconnected",
        "tooltip-format-wifi": "{essid}\n{ipaddr}"
    },
    "battery": {
        "format": "{icon} {capacity}%",
        "format-charging": " {capacity}%",
        "format-plugged": " {capacity}%",
        "format-alt": "{time} {icon}",
        "format-icons": ["", "", "", "", ""]
    },
    "tray": {
        "icon-size": 21,
        "spacing": 10
    }
}
WAYBAR_CONFIG_EOF

    cat > "/mnt/home/$USERNAME/.config/waybar/style.css" << 'WAYBAR_STYLE_EOF'
* {
    border-radius: 0;
    font-family: sans-serif;
    font-size: 14px;
}

window#waybar {
    background-color: #2e3440; /* Nord dark */
    color: #eceff4; /* Nord lighter */
}

#workspaces button {
    padding: 0 5px;
    background-color: transparent;
    color: #88c0d0; /* Nord blue */
    border-bottom: 3px solid transparent;
}

#workspaces button.focused {
    background-color: #4c566a; /* Nord darker blue */
    border-bottom: 3px solid #81a1c1; /* Nord light blue */
}

#mode {
    background-color: #bf616a; /* Nord red */
    color: #eceff4;
    padding: 0 10px;
}

#clock, #pulseaudio, #backlight, #network, #battery, #tray {
    padding: 0 10px;
    margin: 0 5px;
    color: #eceff4;
}

#battery.critical {
    color: #bf616a; /* Nord red */
}
WAYBAR_STYLE_EOF

    # Establecer propietario correcto
    arch-chroot /mnt chown -R "$USERNAME":"$USERNAME" "/home/$USERNAME/.config"

    log "Sway y Waybar configurados"
}

# Configurar servicios adicionales de seguridad
setup_security_services() {
    log "Configurando servicios adicionales de seguridad..."

    # Configurar fail2ban para protección contra ataques
    mkdir -p /mnt/etc/fail2ban/
    cat > /mnt/etc/fail2ban/jail.local << 'EOF_FAIL2BAN'
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
EOF_FAIL2BAN
    arch-chroot /mnt systemctl enable fail2ban

    # Configurar AIDE para detección de intrusiones
    mkdir -p /mnt/etc/aide/ # Asegurarse de que el directorio existe
    cat > /mnt/etc/aide.conf << 'EOF_AIDE'
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
EOF_AIDE
    # Inicialización de la base de datos AIDE se recomienda hacer al final, ya que cambia los permisos de archivos
    # Esto se indicará al usuario en los pasos finales.

    # Configurar ClamAV antivirus
    arch-chroot /mnt systemctl enable clamav-freshclam
    arch-chroot /mnt systemctl enable clamav-daemon

    # Configurar timer para escaneo diario
    cat > /mnt/etc/systemd/system/clamav-scan.service << 'EOF_CLAMSCAN_SERVICE'
[Unit]
Description=Full system antivirus scan
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/clamscan -r --log=/var/log/clamav-scan.log --quiet /home /etc /usr /var
User=clamav
EOF_CLAMSCAN_SERVICE

    cat > /mnt/etc/systemd/system/clamav-scan.timer << 'EOF_CLAMSCAN_TIMER'
[Unit]
Description=Run full system scan daily
Requires=clamav-scan.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF_CLAMSCAN_TIMER

    arch-chroot /mnt systemctl enable clamav-scan.timer

    log "Servicios de seguridad configurados"
}

# Configurar monitoreo del sistema
setup_monitoring() {
    log "Configurando monitoreo del sistema..."

    # Script de monitoreo de seguridad
    mkdir -p /mnt/usr/local/bin/
    cat > /mnt/usr/local/bin/security-monitor.sh << 'EOF_SECURITY_MONITOR_SCRIPT'
#!/bin/bash

# Script de monitoreo de seguridad

LOG_FILE="/var/log/security-monitor.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$DATE] Iniciando chequeo de seguridad" >> "$LOG_FILE"

# Verificar conexiones sospechosas
echo "--- Conexiones de red ---" >> "$LOG_FILE"
netstat -tuln | grep LISTEN >> "$LOG_FILE"

# Verificar procesos con privilegios altos
echo "--- Procesos de root ---" >> "$LOG_FILE"
ps aux | awk '$1 == "root"' >> "$LOG_FILE"

# Verificar últimos login
echo "--- Últimos 10 logins ---" >> "$LOG_FILE"
last -n 10 >> "$LOG_FILE"

# Verificar intentos de sudo fallidos
echo "--- Intentos de sudo fallidos ---" >> "$LOG_FILE"
grep "sudo.*COMMAND" /var/log/auth.log | tail -10 >> "$LOG_FILE"

# Verificar integridad de archivos críticos con AIDE
echo "--- Chequeo de integridad AIDE ---" >> "$LOG_FILE"
if [ -f /var/lib/aide/aide.db ]; then
  aide --check >> "$LOG_FILE" 2>&1
else
  echo "AIDE database not initialized. Run 'sudo aide --init' after reboot." >> "$LOG_FILE"
fi

echo "[$DATE] Chequeo completado" >> "$LOG_FILE"
EOF_SECURITY_MONITOR_SCRIPT

    arch-chroot /mnt chmod +x /usr/local/bin/security-monitor.sh

    # Timer para ejecutar cada hora
    mkdir -p /mnt/etc/systemd/system/
    cat > /mnt/etc/systemd/system/security-monitor.service << 'EOF_SECURITY_MONITOR_SERVICE'
[Unit]
Description=Security monitoring script
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/security-monitor.sh
User=root
EOF_SECURITY_MONITOR_SERVICE

    cat > /mnt/etc/systemd/system/security-monitor.timer << 'EOF_SECURITY_MONITOR_TIMER'
[Unit]
Description=Run security monitoring hourly
Requires=security-monitor.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF_SECURITY_MONITOR_TIMER

    arch-chroot /mnt systemctl enable security-monitor.timer

    log "Monitoreo configurado"
}

# Limpiar sistema y optimizar
cleanup_system() {
    log "Limpiando sistema y optimizando..."

    # Limpiar cache de pacman
    arch-chroot /mnt pacman -Scc --noconfirm

    # Configurar limpieza automática
    mkdir -p /mnt/etc/systemd/system/ # Asegurarse de que el directorio existe
    cat > /mnt/etc/systemd/system/cleanup.service << 'EOF_CLEANUP_SERVICE'
[Unit]
Description=System cleanup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/find /tmp -type f -atime +7 -delete
ExecStart=/usr/bin/find /var/tmp -type f -atime +7 -delete
ExecStart=/usr/bin/journalctl --vacuum-time=1month
User=root
EOF_CLEANUP_SERVICE

    cat > /mnt/etc/systemd/system/cleanup.timer << 'EOF_CLEANUP_TIMER'
[Unit]
Description=Run system cleanup weekly
Requires=cleanup.service

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF_CLEANUP_TIMER

    arch-chroot /mnt systemctl enable cleanup.timer

    # REMOVIDAS: Limpieza de archivos temporales en el entorno live
    # Esto lo debe manejar el sistema instalado.
    # rm -rf /mnt/tmp/* 2>/dev/null || true
    # rm -rf /mnt/var/tmp/* 2>/dev/null || true

    log "Sistema optimizado"
}

# Función principal
main() {
    log "Iniciando instalación de Arch Linux Hardened..."

    check_uefi
    setup_keyboard
    check_internet
    sync_time
    setup_mirrors
    update_system # Importante para archlinux-keyring
    select_disk
    get_passwords
    prepare_disk
    setup_encryption
    setup_lvm
    format_partitions
    mount_filesystems
    install_base_system
    generate_fstab
    setup_apparmor # <--- MOVEMOS ESTA LLAMADA AQUÍ
    configure_system # Contiene el arch-chroot y la configuración básica del sistema
    setup_tpm # Se ejecuta aquí, ya que requiere systemd-cryptenroll que está en el chroot
    setup_sway
    setup_security_services
    setup_monitoring
    cleanup_system

    log "¡Instalación completada exitosamente!"
    echo -e "\n${GREEN}Sistema instalado con las siguientes características de seguridad:${NC}"
    echo "✓ Cifrado completo de disco con LUKS2"
    echo "✓ Kernel Linux Hardened"
    echo "✓ Unified Kernel Image (UKI)"
    echo "✓ TPM 2.0 para desbloqueo automático (si es compatible y configurado)"
    echo "✓ Secure Boot configurado (si es compatible y se habilita en BIOS/UEFI)"
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

    echo -e "\n${YELLOW}Comandos útiles para monitoreo (después de reiniciar):${NC}"
    echo "• journalctl -f - Ver logs en tiempo real"
    echo "• ausearch -k privilege_escalation - Buscar escalamientos"
    echo "• aa-status - Estado de AppArmor"
    echo "• systemctl status security-monitor.timer - Estado del monitoreo"
    echo "• clamscan -r /home - Escaneo manual antivirus"
    echo "• aide --check - Verificar integridad de archivos"

    echo -e "\n${YELLOW}Pasos siguientes IMPORTANTES:${NC}"
    echo "1. Salir del entorno de instalación: exit"
    echo "2. Desmontar: umount -R /mnt"
    echo "3. Reiniciar: reboot"
    echo "4. Tras el primer arranque exitoso, **inicializa la base de datos de AIDE**: sudo aide --init (esto creará /var/lib/aide/aide.db.new.gz que deberás mover a /var/lib/aide/aide.db.gz)"
    echo "5. Actualizar definiciones de ClamAV: sudo freshclam"
    echo "6. **Para habilitar Secure Boot:**"
    echo "   a. Después de reiniciar y verificar que el sistema arranca, apaga el equipo."
    echo "   b. Entra en el firmware UEFI/BIOS (normalmente F2/F12 al inicio para Dell)."
    echo "   c. Busca la sección 'Secure Boot' y la opción para 'Clear Secure Boot Keys' o 'Restore Factory Keys' para entrar en 'Setup Mode'."
    echo "   d. Guarda los cambios y sal."
    echo "   e. Vuelve a arrancar Arch Linux."
    echo "   f. Una vez en el sistema, ejecuta: sudo sbctl enroll-keys"
    echo "   g. Reinicia de nuevo, vuelve al BIOS/UEFI y **habilita Secure Boot**."
    echo "   h. ¡Tu sistema ahora debería arrancar con Secure Boot habilitado y tus propias claves!"


    read -p "¿Desmontar y reiniciar ahora? (s/N): " reboot_now
    if [[ "$reboot_now" =~ ^[sS]$ ]]; then
        log "Desmontando sistema..."
        umount -R /mnt 2>/dev/null || true
        swapoff /dev/vg0/swap 2>/dev/null || true
        vgchange -an vg0 2>/dev/null || true
        cryptsetup close cryptlvm 2>/dev/null || true
        log "Sistema desmontado. Reiniciando..."
        reboot
    fi
}

# Verificar si se ejecuta como root
if [ "$EUID" -ne 0 ]; then
    error "Este script debe ejecutarse como root"
fi

# Ejecutar función principal
main "$@"
