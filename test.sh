configure_bootloader() {
    echo "Configuring bootloader..."
    # ... (otras configuraciones si las hay)

    # Instalar systemd-boot
    bootctl install

    # Configurar systemd-boot para Unified Kernel Images (UKI)
    # Esto asume que tienes linux-hardened (o linux) y mkinitcpio
    # mkinitcpio ya debería haber generado el UKI si tienes la hook 'uki' o 'systemd' en mkinitcpio.conf
    # y si los paquetes systemd-ukify o systemd-stub están presentes
    # Si estás usando systemd-boot para UKI, no necesitas entries manuales en /boot/loader/entries/
    # systemd-boot buscará los UKI en la partición EFI
    # Asegúrate de que el archivo /etc/mkinitcpio.d/linux-hardened.preset (o linux.preset) tenga la línea 'UKI_ENABLE="yes"'
    # O que tu mkinitcpio.conf contenga la hook 'uki'

    # Habilitar el servicio de actualización de systemd-boot
    systemctl enable systemd-boot-update.service

    # --- Parte de Secure Boot con sbctl ---
    echo "Configuring Secure Boot with sbctl..."
    # Crea las claves de Secure Boot
    sbctl create-keys

    # Intenta enrollar las claves. Si Secure Boot está deshabilitado, esto advertirá pero no detendrá el proceso.
    # Si planeas habilitar Secure Boot después, necesitarás entrar en el BIOS.
    sbctl enroll-keys -m || echo "WARNING: Could not enroll keys to firmware. Secure Boot might be disabled or in User Mode. Manual intervention in BIOS may be required."

    # Firma los archivos necesarios para Secure Boot
    # Esto firma el Unified Kernel Image (UKI) y el cargador de arranque predeterminado (BOOTX64.EFI)
    sbctl sign --save /boot/EFI/Linux/arch-hardened.efi # Ajusta la ruta si tu UKI tiene otro nombre
    sbctl sign --save /boot/EFI/BOOT/BOOTX64.EFI
    sbctl sign --save /boot/EFI/systemd/systemd-bootx64.efi # Esto es redundante si BOOTX64.EFI es un symlink a este.

    # Verificar el estado de Secure Boot (opcional, para depuración)
    sbctl status
    echo "Secure Boot configuration finished."
}
