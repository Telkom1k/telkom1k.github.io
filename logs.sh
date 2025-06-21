#!/bin/bash

# Este script habilita logs relevantes para la detección de malware en memoria,
# firmware y red en un entorno Arch Linux Live USB.

# Precaución: La habilitación extensiva de logs puede generar un gran volumen
# de datos y afectar el rendimiento. Adapta las configuraciones a tus necesidades.

echo "Iniciando configuración de logs para auditoría de malware en memoria, firmware y red..."

# 1. Configuración de rsyslog para mayor verbosidad y envío a un archivo específico
echo "Configurando rsyslog para mayor verbosidad..."
if ! grep -q "^daemon.*;mail.*;\
news.none;authpriv.none;cron.none\s\s\s\s-/var/log/syslog_malware.log" /etc/rsyslog.conf; then
    echo "daemon.*;mail.*;\
news.none;authpriv.none;cron.none         -/var/log/syslog_malware.log" | sudo tee -a /etc/rsyslog.conf > /dev/null
fi
sudo systemctl restart rsyslog

# 2. Habilitar logging detallado de la red (nf_conntrack y dmesg para errores de NIC)
echo "Habilitando logging detallado de la red..."

# Habilitar logging de nuevas conexiones (nf_conntrack) - ya suele estar en dmesg, pero se recalca
# No hay un "toggle" directo para más logs de nf_conntrack más allá de lo que kernel ya reporta.
# Sin embargo, podemos aumentar el nivel de log del kernel para ver más.
sudo sysctl -w kernel.printk="7 4 1 7" # Mayor verbosidad del kernel (incluye netfilter)

# Habilitar debugging para algunos drivers de red (si es posible, requiere módulos específicos)
# Esto es muy específico del hardware y no siempre es posible sin recompilar o instalar módulos debug.
# Ejemplo (solo si sabes qué módulo de red usas):
# echo "options <nombre_modulo_red> dyndbg=+p" | sudo tee /etc/modprobe.d/net_debug.conf
# sudo modprobe -r <nombre_modulo_red> && sudo modprobe <nombre_modulo_red>

# 3. Logs de auditoría del kernel (auditd)
echo "Configurando auditd para monitorear eventos críticos..."
sudo systemctl enable --now auditd

# Reglas básicas de auditd para monitorear archivos críticos, carga de módulos, y acceso a memoria
# Estas reglas son fundamentales para detectar actividades sospechosas.
AUDIT_RULES_FILE="/etc/audit/rules.d/malware_audit.rules"
echo "# Reglas de auditoría para rastreo de malware en memoria, firmware y red" | sudo tee $AUDIT_RULES_FILE
echo "-w /dev/mem -p rwxa -k mem_access # Acceso a memoria física" | sudo tee -a $AUDIT_RULES_FILE
echo "-w /dev/kmem -p rwxa -k kmem_access # Acceso a memoria del kernel" | sudo tee -a $AUDIT_RULES_FILE
echo "-w /dev/port -p rwxa -k port_access # Acceso a puertos de hardware" | sudo tee -a $AUDIT_RULES_FILE
echo "-w /lib/modules -p rwxa -k module_load # Carga de módulos del kernel" | sudo tee -a $AUDIT_RULES_FILE
echo "-w /etc/ld.so.preload -p rwxa -k ld_preload # Modificaciones a ld.so.preload" | sudo tee -a $AUDIT_RULES_FILE
echo "-w /etc/modprobe.d -p rwxa -k modprobe_conf # Modificaciones a modprobe.d" | sudo tee -a $AUDIT_RULES_FILE
echo "-w /boot -p rwxa -k boot_changes # Cambios en el directorio de arranque" | sudo tee -a $AUDIT_RULES_FILE
echo "-w /etc/init.d -p rwxa -k init_scripts # Cambios en scripts de inicio (para sistemas que lo usen)" | sudo tee -a $AUDIT_RULES_FILE
echo "-w /usr/lib/systemd -p rwxa -k systemd_changes # Cambios en unidades de systemd" | sudo tee -a $AUDIT_RULES_FILE
echo "-a always,exit -F arch=b64 -S mmap -S mprotect -S ptrace -k memory_syscalls # Llamadas a sistema relacionadas con memoria" | sudo tee -a $AUDIT_RULES_FILE
echo "-a always,exit -F arch=b64 -S create_module -S init_module -S delete_module -k kernel_modules # Carga/descarga de módulos" | sudo tee -a $AUDIT_RULES_FILE
echo "-a always,exit -F arch=b64 -S socket -S connect -S bind -S listen -S accept -S sendto -S recvfrom -k network_syscalls # Llamadas a sistema de red" | sudo tee -a $AUDIT_RULES_FILE
echo "-a always,exit -F arch=b64 -S ioperm -S iopl -k io_privileges # Permisos de E/S de bajo nivel" | sudo tee -a $AUDIT_RULES_FILE
echo "-a always,exit -F arch=b64 -S finit_module -k finit_module # Carga de módulos desde file descriptor" | sudo tee -a $AUDIT_RULES_FILE

sudo auditctl -R $AUDIT_RULES_FILE
sudo systemctl restart auditd

# 4. Logging de Systemd (journalctl)
echo "Configurando journalctl para mayor persistencia (si el USB lo permite) y tamaño..."
# Por defecto, en Live USB, journalctl es volátil. Para persistencia básica, crea el directorio
if [ ! -d "/var/log/journal" ]; then
    sudo mkdir -p /var/log/journal
    sudo chown root:systemd-journal /var/log/journal
    sudo chmod 2755 /var/log/journal
fi
# Configurar tamaño máximo de journalctl (ajusta según el espacio disponible en tu USB)
sudo sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
sudo sed -i 's/^#SystemKeepFree=.*/SystemKeepFree=100M/' /etc/systemd/journald.conf
sudo sed -i 's/^#Storage=.*/Storage=persistent/' /etc/systemd/journald.conf # Forzar persistencia si se crea el directorio

sudo systemctl restart systemd-journald

# 5. Logging de firmware y dispositivos PCI/USB (dmesg)
echo "Aumentando verbosidad de dmesg para firmware y hardware..."
# kernel.printk ya se estableció arriba, que afecta a dmesg.
# No hay una forma directa de hacer dmesg más "detallado" sobre firmware sin un kernel especial.
# Pero, dmesg por sí solo ya contendrá mucha información relevante sobre el arranque.

# 6. Logging de carga de módulos (modprobe)
# modprobe en sí no tiene un log de "todo lo que carga".
# Los logs de carga de módulos se verán en dmesg y journalctl.
# Auditd ya monitorea /lib/modules.

# 7. Logging de eventos de red a bajo nivel (si hay herramientas disponibles)
# tcpdump/tshark para capturar tráfico de red. No son "logs" persistentes del sistema, sino capturas.
# Se recomienda ejecutarlos manualmente cuando se sospeche de actividad.

echo "Configuración de logs completada. Los logs se guardarán en:"
echo " - /var/log/syslog_malware.log (rsyslog)"
echo " - /var/log/audit/audit.log (auditd)"
echo " - journalctl (para ver, usa 'journalctl' o 'journalctl -f')"
echo ""
echo "Recuerda que en un Live USB, estos logs pueden no persistir a menos que el USB sea persistente."
echo "Considera la posibilidad de guardar los logs en un disco externo o una partición persistente."
echo ""
echo "Para analizar los logs, consulta las herramientas y métodos sugeridos."
