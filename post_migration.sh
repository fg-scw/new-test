#!/bin/bash
# Script de correction post-migration pour Scaleway
# À exécuter sur l'instance après le premier boot si nécessaire

set -euo pipefail

echo "=== Application des corrections post-migration Scaleway ==="

# Détection du mode de boot
BOOT_MODE="legacy"
if [ -d /boot/efi/EFI ] && [ -n "$(ls -A /boot/efi/EFI 2>/dev/null)" ]; then
    BOOT_MODE="uefi"
fi
echo "Mode de boot détecté : $BOOT_MODE"

# Détection de la distribution
DISTRO="unknown"
if [ -f /etc/redhat-release ]; then
    DISTRO="rhel"
elif [ -f /etc/centos-release ]; then
    DISTRO="centos"
fi
echo "Distribution détectée : $DISTRO"

# Fonction pour sauvegarder un fichier
backup_file() {
    local file="$1"
    if [ -f "$file" ] && [ ! -f "${file}.pre-fix" ]; then
        cp -p "$file" "${file}.pre-fix"
        echo "Sauvegarde créée : ${file}.pre-fix"
    fi
}

# 1. Corriger fstab
echo "=== Correction de /etc/fstab ==="
backup_file /etc/fstab

# Remplacer vda par sda
if grep -q "/dev/vda" /etc/fstab; then
    echo "Correction des entrées vda -> sda..."
    sed -i 's|/dev/vda|/dev/sda|g' /etc/fstab
fi

# Commenter les entrées pour les devices non existants
echo "Vérification des devices dans fstab..."
temp_fstab=$(mktemp)
while IFS= read -r line; do
    # Skip les lignes vides et commentaires
    if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        echo "$line" >> "$temp_fstab"
        continue
    fi

    # Parser la ligne fstab
    device=$(echo "$line" | awk '{print $1}')
    mountpoint=$(echo "$line" | awk '{print $2}')

    # Vérifier si c'est un device
    if [[ "$device" =~ ^/dev/ ]]; then
        # Extraire le device de base (sans numéro de partition)
        base_device=$(echo "$device" | sed 's/[0-9]*$//')

        # Vérifier si le device existe
        if [ ! -b "$device" ] && [ ! -b "$base_device" ]; then
            echo "Device non trouvé : $device (mountpoint: $mountpoint)"
            echo "# $line # Commented by post-migration fix - device not found" >> "$temp_fstab"
        else
            echo "$line" >> "$temp_fstab"
        fi
    else
        echo "$line" >> "$temp_fstab"
    fi
done < /etc/fstab

mv "$temp_fstab" /etc/fstab
chmod 644 /etc/fstab

# 2. Corriger GRUB
echo "=== Correction de GRUB ==="
backup_file /etc/default/grub

if [ -f /etc/default/grub ]; then
    # Remplacer vda par sda
    if grep -q "/dev/vda" /etc/default/grub; then
        echo "Correction des entrées vda -> sda dans GRUB..."
        sed -i 's|/dev/vda|/dev/sda|g' /etc/default/grub
    fi

    # S'assurer que la console série est configurée
    if ! grep -q "console=ttyS0,115200n8" /etc/default/grub; then
        echo "Ajout de la console série..."
        sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 console=ttyS0,115200n8"/' /etc/default/grub
    fi
fi

# Régénérer la configuration GRUB
echo "Régénération de la configuration GRUB..."
if [ "$BOOT_MODE" = "uefi" ]; then
    # UEFI
    if command -v grub2-mkconfig &> /dev/null; then
        # Trouver le bon chemin pour grub.cfg en UEFI
        if [ -d /boot/efi/EFI/redhat ]; then
            grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
        elif [ -d /boot/efi/EFI/centos ]; then
            grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg
        elif [ -d /boot/efi/EFI/rhel ]; then
            grub2-mkconfig -o /boot/efi/EFI/rhel/grub.cfg
        else
            echo "Warning: Impossible de trouver le répertoire EFI"
        fi
    fi
else
    # Legacy BIOS
    if command -v grub2-mkconfig &> /dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    elif command -v grub-mkconfig &> /dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
    fi
fi

# 3. Reconstruire initramfs
echo "=== Reconstruction de l'initramfs ==="
if command -v dracut &> /dev/null; then
    echo "Utilisation de dracut..."
    # Obtenir la version du kernel actuel
    KERNEL_VERSION=$(uname -r)
    dracut -f "/boot/initramfs-${KERNEL_VERSION}.img" "${KERNEL_VERSION}"
elif command -v mkinitramfs &> /dev/null; then
    echo "Utilisation de mkinitramfs..."
    update-initramfs -u -k all
fi

# 4. Vérifier et corriger NetworkManager
echo "=== Vérification de NetworkManager ==="
if [ -f /etc/NetworkManager/conf.d/00-scaleway.conf ]; then
    echo "Configuration Scaleway pour NetworkManager présente"
else
    echo "Ajout de la configuration Scaleway pour NetworkManager..."
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/00-scaleway.conf <<'EOF'
[connection]
# The value 0 stands for eui64 -- see nm-settings-nmcli(5)
ipv6.addr-gen-mode=0
EOF
fi

# 5. Vérifier qemu-guest-agent
echo "=== Vérification de qemu-guest-agent ==="
if systemctl is-enabled qemu-guest-agent &>/dev/null; then
    echo "qemu-guest-agent est activé"
else
    echo "Activation de qemu-guest-agent..."
    systemctl enable qemu-guest-agent || true
fi

# 6. Nettoyer les règles udev persistantes
echo "=== Nettoyage des règles udev ==="
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f /etc/udev/rules.d/75-persistent-net-generator.rules

# 7. Réinitialiser machine-id si nécessaire
if [ -f /etc/machine-id ] && [ -s /etc/machine-id ]; then
    echo "Machine-id présent, pas de modification"
else
    echo "Génération d'un nouveau machine-id..."
    systemd-machine-id-setup
fi

# 8. S'assurer que SELinux est correctement configuré
echo "=== Vérification SELinux ==="
if [ -f /etc/selinux/config ]; then
    current_mode=$(getenforce 2>/dev/null || echo "Disabled")
    echo "Mode SELinux actuel : $current_mode"

    # Si SELinux est en mode enforcing, forcer un relabel au prochain boot
    if [ "$current_mode" = "Enforcing" ]; then
        touch /.autorelabel
        echo "Relabel SELinux programmé au prochain redémarrage"
    fi
fi

# 9. Rapport final
echo ""
echo "=== Rapport de correction ==="
echo "Mode de boot : $BOOT_MODE"
echo "Distribution : $DISTRO"
echo ""
echo "Fichiers modifiés :"
for file in /etc/fstab /etc/default/grub; do
    if [ -f "${file}.pre-fix" ]; then
        echo "  - $file (sauvegarde : ${file}.pre-fix)"
    fi
done

echo ""
echo "=== Corrections appliquées avec succès ==="
echo "Un redémarrage est recommandé pour appliquer tous les changements."
echo ""
echo "Pour redémarrer : systemctl reboot"

# Optionnel : afficher les points de montage problématiques
if grep -q "^#.*device not found" /etc/fstab; then
    echo ""
    echo "⚠️  Attention : Des entrées fstab ont été désactivées car les devices n'existent pas."
    echo "Vérifiez ces entrées après avoir attaché tous les disques nécessaires :"
    grep "^#.*device not found" /etc/fstab
fi
