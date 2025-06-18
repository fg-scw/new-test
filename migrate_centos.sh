#!/usr/bin/bash
set -euo pipefail

export LIBGUESTFS_BACKEND=direct

# Vérifier les paramètres
if [ $# -lt 2 ]; then
    echo "Usage: $0 <source.qcow2|source.ova> <destination.qcow2>"
    exit 1
fi

SOURCE="$1"
DEST="$2"

# Déterminer le type de source
if [[ "$SOURCE" == *.ova ]]; then
    SOURCE_TYPE="ova"
    SOURCE_NAME=$(basename "$SOURCE" .ova)
else
    SOURCE_TYPE="disk"
    SOURCE_NAME=$(basename "$SOURCE" .qcow2)
fi

V2VED_BASENAME="$SOURCE_NAME"
V2VED_QCOW="V2VED-${V2VED_BASENAME}"

BUILD_DIR="$(mktemp -d /var/tmp/v2v-build.XXXXXX)"
BACKUP_DIR="$(mktemp -d)"

cleanup() { rm -rf "$BUILD_DIR" "$BACKUP_DIR"; }
trap cleanup EXIT

chmod a+rx "$BUILD_DIR"

echo "=== Conversion avec virt-v2v ==="
echo "Source: $SOURCE (type: $SOURCE_TYPE)"
echo "Build dir: $BUILD_DIR"

# Virt-v2v conversion avec gestion des erreurs
if [ "$SOURCE_TYPE" = "ova" ]; then
    # Pour OVA, utiliser -i ova
    LIBGUESTFS_BACKEND=direct virt-v2v \
      -i ova "$SOURCE" \
      -o local \
      -on "$V2VED_QCOW" \
      -os "$BUILD_DIR" \
      -of qcow2 \
      --machine-readable \
      2>&1 | tee /tmp/v2v-log.txt || {
        echo "Warning: virt-v2v a retourné une erreur, vérification du résultat..."
        # Vérifier si le fichier de sortie existe malgré l'erreur
        if [ ! -f "$BUILD_DIR/${V2VED_QCOW}-sda" ] && [ ! -f "$BUILD_DIR/${V2VED_QCOW}" ]; then
            echo "Erreur: Aucun fichier de sortie trouvé"
            exit 1
        fi
    }
else
    # Pour QCOW2, utiliser -i disk
    LIBGUESTFS_BACKEND=direct virt-v2v \
      -i disk "$SOURCE" \
      -o qemu \
      -on "$V2VED_QCOW" \
      -os "$BUILD_DIR" \
      -of qcow2 \
      -oc qcow2 \
      2>&1 | tee /tmp/v2v-log.txt || {
        echo "Warning: virt-v2v a retourné une erreur, vérification du résultat..."
    }
fi

# Trouver le fichier de sortie
QCOW_OUT=""
if [ -f "$BUILD_DIR/${V2VED_QCOW}-sda" ]; then
    QCOW_OUT="$BUILD_DIR/${V2VED_QCOW}-sda"
elif [ -f "$BUILD_DIR/${V2VED_QCOW}" ]; then
    QCOW_OUT="$BUILD_DIR/${V2VED_QCOW}"
else
    # Chercher tout fichier qcow2 dans le répertoire
    QCOW_OUT=$(find "$BUILD_DIR" -name "*.qcow2" -type f | head -n1)
    if [ -z "$QCOW_OUT" ]; then
        echo "Erreur: Impossible de trouver le fichier qcow2 de sortie"
        ls -la "$BUILD_DIR"
        exit 1
    fi
fi

echo "Fichier de sortie trouvé: $QCOW_OUT"

chmod 666 "$QCOW_OUT" || true
chcon --type virt_image_t "$QCOW_OUT" 2>/dev/null || true

# Détection du mode de boot
echo "=== Détection du mode de boot ==="
BOOT_MODE="legacy"
if virt-ls -a "$QCOW_OUT" /boot/efi/EFI 2>/dev/null | grep -q .; then
    BOOT_MODE="uefi"
    echo "Mode UEFI détecté"
else
    echo "Mode Legacy BIOS détecté"
fi

# Backup des fichiers système
echo "=== Backup des fichiers système ==="
virt-copy-out -a "$QCOW_OUT" /etc/passwd /etc/shadow /etc/group /etc/gshadow "$BACKUP_DIR" || {
    echo "Warning: Impossible de sauvegarder certains fichiers système"
}

# Exécuter le script Python de migration
echo "=== Exécution du script de migration Python ==="
python3 migrate_centos.py "$QCOW_OUT"

# Restaurer les fichiers système
echo "=== Restauration des fichiers système ==="
for file in passwd shadow group gshadow; do
    if [ -f "$BACKUP_DIR/$file" ]; then
        virt-copy-in -a "$QCOW_OUT" "$BACKUP_DIR/$file" /etc || {
            echo "Warning: Impossible de restaurer /etc/$file"
        }
    fi
done

# Customisations finales avec virt-customize
echo "=== Customisations finales ==="
CUSTOMIZE_ARGS=(
    -a "$QCOW_OUT"
    --run-command "mkdir -p /etc/ssh/sshd_config.d"
    --run-command "bash -c 'printf \"PermitRootLogin yes\nPasswordAuthentication yes\n\" > /etc/ssh/sshd_config.d/99-rootpw.conf'"
    --run-command "sed -i 's|/dev/vda|/dev/sda|g' /etc/fstab 2>/dev/null || true"
)

# Ajouter les commandes spécifiques selon le mode de boot
if [ "$BOOT_MODE" = "uefi" ]; then
    CUSTOMIZE_ARGS+=(
        --run-command "sed -i 's|/dev/vda|/dev/sda|g' /etc/default/grub 2>/dev/null || true"
        --run-command "if command -v grub2-mkconfig >/dev/null 2>&1; then grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg || grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg || true; fi"
    )
else
    CUSTOMIZE_ARGS+=(
        --run-command "sed -i 's|/dev/vda|/dev/sda|g' /etc/default/grub 2>/dev/null || true"
        --run-command "if command -v grub2-mkconfig >/dev/null 2>&1; then grub2-mkconfig -o /boot/grub2/grub.cfg || true; fi"
        --run-command "if command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg || true; fi"
    )
fi

# Fixer les problèmes de disques multiples dans fstab
CUSTOMIZE_ARGS+=(
    --run-command "awk '!/^#/ && /^\/dev\// { device=\$1; if (system(\"test -e \" device) != 0) { print \"#\" \$0 \" # Commented by migration - device not found\" } else { print } } /^#/ || !/^\/dev\// { print }' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab"
    --selinux-relabel
)

virt-customize "${CUSTOMIZE_ARGS[@]}"

# Déplacer le fichier final
mv "$QCOW_OUT" "$DEST"

echo "=== Migration terminée ==="
echo "Image disponible : $DEST"
echo "Mode de boot : $BOOT_MODE"

# Afficher des instructions post-migration si nécessaire
if grep -q "backup\|data" /tmp/v2v-log.txt 2>/dev/null; then
    echo ""
    echo "⚠️  Attention: Des disques additionnels ont été détectés mais non migrés."
    echo "   Vérifiez /etc/fstab sur l'instance après le premier boot."
fi
