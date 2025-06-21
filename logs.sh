#!/bin/bash

# Este script está diseñado para ser ejecutado en un entorno Arch Linux LiveUSB.
# Su propósito es facilitar la configuración inicial, la instalación de Arch Linux
# y, de manera crucial, recopilar logs detallados en una ubicación especificada por el usuario,
# sin persistir los cambios en los mirrorlists del LiveUSB.

# --- Configuración de Logs ---
LOG_FILE_PREFIX="arch_live_install_"
LOG_DIR="" # Se establecerá por el usuario

# Función para imprimir mensajes con marca de tiempo y redirigir a stderr para visibilidad inmediata
log_message() {
    local type="$1" # e.g., INFO, WARN, ERROR, DEBUG
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$timestamp [$type] $message" >&2
    echo "$timestamp [$type] $message" >> "$LOG_DIR/${LOG_FILE_PREFIX}main.log" 2>&1
}

# Función para manejar errores de forma robusta
handle_error() {
    local exit_code="$1"
    local command_failed="$2"
    local error_message="$3"
    log_message "ERROR" "Comando fallido: '$command_failed'. Error: '$error_message'. Código de salida: $exit_code."
    log_message "ERROR" "El script ha encontrado un error crítico y se detendrá."
    exit $exit_code
}

# --- Chequeos iniciales ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "Este script debe ser ejecutado como root."
        handle_error 1 "check_root" "Permisos insuficientes"
    fi
    log_message "INFO" "Comprobación de usuario root: OK."
}

# --- Configuración de la ruta de logs ---
configure_log_directory() {
    log_message "INFO" "Configurando el directorio de logs."
    while true; do
        read -rp "Por favor, introduce la ruta completa donde quieres guardar los logs (Ej: /mnt/my_logs o /home/user/logs): " user_log_path
        if [[ -z "$user_log_path" ]]; then
            log_message "WARN" "La ruta no puede estar vacía. Por favor, introduce una ruta válida."
            continue
        fi

        # Intentar crear el directorio si no existe
        if ! mkdir -p "$user_log_path" 2>/dev/null; then
            log_message "ERROR" "No se pudo crear el directorio de logs en '$user_log_path'. Verifica los permisos o si la ruta es válida."
            log_message "WARN" "Por favor, intenta de nuevo con una ruta diferente."
            continue
        fi

        # Comprobar si el directorio es escribible
        if [[ ! -w "$user_log_path" ]]; then
            log_message "ERROR" "El directorio '$user_log_path' no es escribible. Por favor, verifica los permisos."
            log_message "WARN" "Por favor, intenta de nuevo con una ruta diferente."
            continue
        fi

        # Si todo es correcto, asignamos la ruta y salimos del bucle
        LOG_DIR="$user_log_path"
        log_message "INFO" "Logs se guardarán en: $LOG_DIR"
        break
    done
}

# --- Funciones de Logging Avanzadas ---

# Captura la salida de un comando y la redirige a un archivo de log específico
# También imprime en stderr para visibilidad inmediata si el DEBUG está activado
run_and_log() {
    local cmd_description="$1"
    local command="$2"
    local log_suffix="$3" # Por ejemplo, "pacman_sync", "disk_part"
    local log_file="$LOG_DIR/${LOG_FILE_PREFIX}${log_suffix}.log"

    log_message "INFO" "Ejecutando: $cmd_description"

    # Redirigir stdout y stderr del comando al archivo de log
    # El tee redirige a stdout, que luego es redirigido a stderr por la función log_message,
    # manteniendo la visibilidad en la consola.
    if ! eval "$command" 2>&1 | tee -a "$log_file"; then
        handle_error $? "$command" "Error al ejecutar '$cmd_description'."
    else
        log_message "INFO" "'$cmd_description' completado exitosamente."
    fi
}

# --- Funciones principales del script ---

# Función para verificar la conectividad a Internet
check_internet_connectivity() {
    log_message "INFO" "Comprobando conectividad a internet..."
    if ! ping -c 3 archlinux.org &>> "$LOG_DIR/${LOG_FILE_PREFIX}internet_check.log"; then
        log_message "ERROR" "No se pudo establecer conexión a Internet. Por favor, verifica tu conexión (Ethernet/Wi-Fi)."
        log_message "ERROR" "Puedes intentar configurar Wi-Fi con 'iwctl' si es necesario."
        handle_error 1 "ping archlinux.org" "Sin conexión a internet"
    fi
    log_message "INFO" "Conexión a internet verificada exitosamente."
}

# Función para actualizar el reloj del sistema
update_system_clock() {
    log_message "INFO" "Actualizando el reloj del sistema con NTP..."
    run_and_log "Sincronización del reloj con NTP" "timedatectl set-ntp true" "ntp_sync"
    log_message "INFO" "Verificando estado del reloj del sistema..."
    run_and_log "Verificación del estado NTP" "timedatectl status" "ntp_status"
}

# NO PERSISTIR MIRRORLISTS:
# Las siguientes funciones no guardarán cambios permanentes en el LiveUSB.
# Si necesitas un mirrorlist optimizado para la instalación, se hace en RAM y luego se descarta.

# Función para generar y usar un mirrorlist temporal (no persistente)
generate_temp_mirrorlist() {
    log_message "INFO" "Generando un mirrorlist temporal para optimizar la velocidad de descarga..."
    log_message "INFO" "Nota: Este cambio NO es persistente en el LiveUSB. Al reiniciar, se restablecerá el mirrorlist predeterminado."
    # Asegurarse de que pacman-mirrors esté disponible, normalmente lo está en el LiveUSB
    if ! command -v reflector &> /dev/null; then
        log_message "WARN" "Reflector no encontrado. Instalándolo temporalmente (solo para esta sesión)."
        # Esto instalará reflector solo en el entorno RAM del LiveUSB.
        run_and_log "Instalando reflector temporalmente" "pacman -Sy --noconfirm reflector" "pacman_install_reflector"
    fi

    # Usar reflector para generar un mirrorlist temporal en /etc/pacman.d/mirrorlist
    # Se recomienda usar opciones como --country, --latest, --protocol, --sort
    # Puedes ajustar los países aquí según tu ubicación o preferencias.
    REFLECTOR_CMD="reflector --country 'United States' --country 'Canada' --country 'Mexico' --age 24 --protocol https --sort rate --save /etc/pacman.d/mirrorlist"
    log_message "INFO" "Ejecutando reflector con el siguiente comando: $REFLECTOR_CMD"
    run_and_log "Generación del mirrorlist temporal con reflector" "$REFLECTOR_CMD" "reflector_gen"

    log_message "INFO" "Contenido del mirrorlist temporal (primeras 10 líneas):"
    run_and_log "Verificando mirrorlist temporal" "head -n 10 /etc/pacman.d/mirrorlist" "mirrorlist_head"
    log_message "INFO" "Mirrorlist temporal generado y activado para esta sesión."
}

# Función para actualizar la base de datos de paquetes
sync_pacman_databases() {
    log_message "INFO" "Sincronizando las bases de datos de paquetes de Pacman..."
    run_and_log "Sincronización de Pacman" "pacman -Syy" "pacman_sync"
}

# --- Funciones de Particionamiento (Opcional, con Logging) ---
# Se recomienda encarecidamente usar fdisk, cfdisk o parted manualmente
# para evitar la pérdida accidental de datos. Este script solo mostrará la información.

list_disks() {
    log_message "INFO" "Listando discos disponibles y sus particiones..."
    run_and_log "Listado de bloques (lsblk)" "lsblk -f" "lsblk_output"
    run_and_log "Información de discos (fdisk -l)" "fdisk -l" "fdisk_output"
    log_message "WARN" "Se recomienda encarecidamente que particiones el disco manualmente usando 'fdisk', 'cfdisk' o 'parted'."
    log_message "WARN" "Este script no automatiza el particionamiento para evitar la pérdida accidental de datos."
}

# --- Funciones de Montaje del Sistema (Crítico) ---
mount_partitions() {
    log_message "INFO" "Montando las particiones..."
    read -rp "Introduce la ruta de la partición raíz (ej: /dev/sdaX): " ROOT_PARTITION
    read -rp "Introduce la ruta de la partición de arranque EFI (ej: /dev/sdaY - deja en blanco si no usas UEFI): " EFI_PARTITION
    read -rp "Introduce la ruta de la partición swap (ej: /dev/sdaZ - deja en blanco si no usas swap): " SWAP_PARTITION

    if [[ -z "$ROOT_PARTITION" ]]; then
        log_message "ERROR" "La partición raíz no puede estar vacía."
        handle_error 1 "mount_partitions" "Partición raíz no especificada"
    fi

    log_message "INFO" "Creando punto de montaje para la raíz: /mnt"
    if ! mkdir -p /mnt &>> "$LOG_DIR/${LOG_FILE_PREFIX}mount_prep.log"; then
        log_message "ERROR" "No se pudo crear el directorio /mnt."
        handle_error 1 "mkdir /mnt" "Creación de /mnt fallida"
    fi

    log_message "INFO" "Montando partición raíz '$ROOT_PARTITION' en /mnt..."
    run_and_log "Montaje de la partición raíz" "mount $ROOT_PARTITION /mnt" "mount_root"

    if [[ -n "$EFI_PARTITION" ]]; then
        log_message "INFO" "Creando punto de montaje para EFI: /mnt/boot/efi"
        if ! mkdir -p /mnt/boot/efi &>> "$LOG_DIR/${LOG_FILE_PREFIX}mount_prep.log"; then
            log_message "ERROR" "No se pudo crear el directorio /mnt/boot/efi."
            handle_error 1 "mkdir /mnt/boot/efi" "Creación de /mnt/boot/efi fallida"
        fi
        log_message "INFO" "Montando partición EFI '$EFI_PARTITION' en /mnt/boot/efi..."
        run_and_log "Montaje de la partición EFI" "mount $EFI_PARTITION /mnt/boot/efi" "mount_efi"
    fi

    if [[ -n "$SWAP_PARTITION" ]]; then
        log_message "INFO" "Activando partición swap '$SWAP_PARTITION'..."
        run_and_log "Activación de SWAP" "swapon $SWAP_PARTITION" "swapon"
    fi

    log_message "INFO" "Particiones montadas. Verificando montajes..."
    run_and_log "Verificación de montajes (findmnt)" "findmnt /mnt" "findmnt_mnt"
    if [[ -n "$EFI_PARTITION" ]]; then
        run_and_log "Verificación de montajes (findmnt /mnt/boot/efi)" "findmnt /mnt/boot/efi" "findmnt_efi"
    fi
}

# --- Instalación del Sistema Base ---
install_base_system() {
    log_message "INFO" "Instalando el sistema base de Arch Linux..."
    log_message "INFO" "Se instalarán los paquetes 'base', 'linux', y 'linux-firmware'."
    log_message "INFO" "Puedes añadir más paquetes si lo deseas, por ejemplo: 'base-devel', 'vim', 'networkmanager'."
    read -rp "Introduce paquetes adicionales a instalar (separados por espacio, ej: base-devel vim networkmanager): " ADDITIONAL_PACKAGES

    run_and_log "Instalación del sistema base" "pacstrap /mnt base linux linux-firmware $ADDITIONAL_PACKAGES" "pacstrap_base"

    log_message "INFO" "Generando el archivo fstab..."
    run_and_log "Generación de fstab" "genfstab -U /mnt >> /mnt/etc/fstab" "genfstab"
    log_message "INFO" "Contenido de /mnt/etc/fstab:"
    run_and_log "Verificación de fstab" "cat /mnt/etc/fstab" "cat_fstab"
}

# --- Configuración del Sistema Instalado (chroot) ---
chroot_and_configure() {
    log_message "INFO" "Entrando en el entorno chroot para configurar el sistema instalado..."
    log_message "INFO" "Se ejecutará un script dentro del chroot para la configuración inicial."

    # Crear un script temporal dentro del chroot para ejecutar las configuraciones
    cat <<EOF > /mnt/chroot_config_script.sh
#!/bin/bash

# Configuración de zona horaria
log_message "INFO" "Configurando la zona horaria..."
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudo configurar la zona horaria."
hwclock --systohc &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudo configurar el reloj del hardware."
log_message "INFO" "Verificando zona horaria."
timedatectl &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log"

# Localización (locale)
log_message "INFO" "Configurando la localización (locale)..."
sed -i 's/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log"
locale-gen &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudo generar locale."
echo "LANG=es_ES.UTF-8" > /etc/locale.conf
log_message "INFO" "Verificando locale."
cat /etc/locale.conf &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log"

# Configuración de red
log_message "INFO" "Configurando el nombre de host..."
read -rp "Introduce el nombre de host para el nuevo sistema: " HOSTNAME
echo "$HOSTNAME" > /etc/hostname
log_message "INFO" "Nombre de host establecido a: $HOSTNAME"
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts
log_message "INFO" "Contenido de /etc/hosts:"
cat /etc/hosts &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log"

# Contraseña de root
log_message "INFO" "Estableciendo la contraseña de root..."
passwd &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudo establecer la contraseña de root."

# Instalación de GRUB (ejemplo para UEFI)
log_message "INFO" "Instalando y configurando GRUB..."
# Asegurarse de tener los paquetes necesarios
pacman -Sy --noconfirm grub efibootmgr os-prober &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudieron instalar paquetes de arranque."

if [ -d "/sys/firmware/efi" ]; then
    log_message "INFO" "Detectado modo UEFI. Instalando GRUB para UEFI..."
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchLinux --recheck &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "ERROR" "Fallo al instalar GRUB UEFI."
else
    log_message "INFO" "No detectado modo UEFI. Asumiendo BIOS. Instalando GRUB para BIOS..."
    read -rp "Introduce el disco donde instalar GRUB (ej: /dev/sda - NO la partición): " GRUB_DISK
    grub-install --target=i386-pc "$GRUB_DISK" &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "ERROR" "Fallo al instalar GRUB BIOS."
fi

grub-mkconfig -o /boot/grub/grub.cfg &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "ERROR" "Fallo al generar la configuración de GRUB."
log_message "INFO" "GRUB instalado y configurado."

# Crear usuario normal (opcional)
read -rp "¿Quieres crear un usuario normal? (y/n): " CREATE_USER
if [[ "$CREATE_USER" =~ ^[Yy]$ ]]; then
    read -rp "Introduce el nombre de usuario: " NEW_USERNAME
    useradd -m -g users -G wheel "$NEW_USERNAME" &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudo crear el usuario."
    log_message "INFO" "Estableciendo contraseña para $NEW_USERNAME..."
    passwd "$NEW_USERNAME" &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudo establecer la contraseña del usuario."
    log_message "INFO" "Habilitando sudo para el grupo wheel..."
    # Descomentar la línea %wheel ALL=(ALL:ALL) ALL en /etc/sudoers
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudo habilitar sudo para el grupo wheel."
    log_message "INFO" "Usuario '$NEW_USERNAME' creado y configurado."
fi

# Habilitar NetworkManager (o tu gestor de red preferido)
# Asume que NetworkManager fue instalado como paquete adicional
if pacman -Qq networkmanager &>/dev/null; then
    log_message "INFO" "Habilitando NetworkManager..."
    systemctl enable NetworkManager &>> "$LOG_DIR/${LOG_FILE_PREFIX}chroot_config.log" || log_message "WARN" "No se pudo habilitar NetworkManager."
else
    log_message "WARN" "NetworkManager no está instalado. Asegúrate de configurar la red manualmente si es necesario."
fi

log_message "INFO" "Configuración básica del sistema completada en chroot."
EOF
    chmod +x /mnt/chroot_config_script.sh

    # Entrar al chroot y ejecutar el script. Redirigir la salida a un archivo específico.
    # Nota: Los logs del script interno usarán la variable LOG_DIR que es global desde el script principal.
    run_and_log "Ejecutando script de configuración en chroot" "arch-chroot /mnt /chroot_config_script.sh" "chroot_execution"

    # Eliminar el script temporal del chroot
    rm /mnt/chroot_config_script.sh &>> "$LOG_DIR/${LOG_FILE_PREFIX}cleanup.log" || log_message "WARN" "No se pudo eliminar /mnt/chroot_config_script.sh"
    log_message "INFO" "Saliendo del entorno chroot."
}

# --- Post-Instalación ---
unmount_all() {
    log_message "INFO" "Desmontando todas las particiones..."
    run_and_log "Desmontaje de /mnt/boot/efi (si existe)" "umount -R /mnt/boot/efi" "umount_efi" # -R para recursivo
    run_and_log "Desmontaje de /mnt" "umount -R /mnt" "umount_root" # -R para recursivo

    # Desactivar swap si estaba activada
    if [[ -n "$SWAP_PARTITION" ]]; then
        log_message "INFO" "Desactivando SWAP..."
        run_and_log "Desactivación de SWAP" "swapoff $SWAP_PARTITION" "swapoff"
    fi

    log_message "INFO" "Todas las particiones desmontadas."
    log_message "INFO" "El proceso de instalación de Arch Linux ha finalizado."
    log_message "INFO" "Puedes reiniciar tu sistema (reboot) y remover el USB Live."
}

# --- Main execution flow ---
main() {
    check_root
    configure_log_directory

    # Redirigir la salida completa del script a un log principal también
    exec &>> "$LOG_DIR/${LOG_FILE_PREFIX}main.log"

    log_message "INFO" "Iniciando script de instalación de Arch Linux LiveUSB."
    log_message "INFO" "Hora de inicio: $(date)"

    check_internet_connectivity
    update_system_clock
    generate_temp_mirrorlist # Esto NO persiste en el LiveUSB
    sync_pacman_databases

    list_disks # Solo para informar al usuario
    log_message "IMPORTANT" "Por favor, particiona tu disco manualmente si aún no lo has hecho."
    read -rp "Presiona [Enter] una vez que hayas terminado de particionar y formatear tus discos..."

    mount_partitions
    install_base_system
    chroot_and_configure
    unmount_all

    log_message "INFO" "Script de instalación de Arch Linux LiveUSB finalizado con éxito."
    log_message "INFO" "Hora de finalización: $(date)"
    log_message "INFO" "Todos los logs se encuentran en: $LOG_DIR"
    log_message "INFO" "Recuerda reiniciar y remover el USB Live."
}

# Ejecutar la función principal
main "$@"
