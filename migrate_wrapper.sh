#!/bin/bash
# Wrapper script pour la migration Scaleway
# Gère automatiquement les cas OVA multi-disques et les erreurs courantes

set -euo pipefail

# Couleurs pour l'output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Fonction d'aide
usage() {
    echo "Usage: $0 <source> <destination>"
    echo ""
    echo "Options:"
    echo "  source       : Fichier source (*.ova ou *.qcow2)"
    echo "  destination  : Fichier de destination (*.qcow2)"
    echo ""
    echo "Exemples:"
    echo "  $0 vm-export.ova /root/vm-migrated.qcow2"
    echo "  $0 vm-original.qcow2 /root/vm-migrated.qcow2"
    echo ""
    echo "Note: Pour les OVA multi-disques, seul le disque système sera migré."
    exit 1
}

# Vérification des paramètres
if [ $# -ne 2 ]; then
    usage
fi

SOURCE="$1"
DEST="$2"

# Vérification de l'existence du fichier source
if [ ! -f "$SOURCE" ]; then
    echo -e "${RED}Erreur: Le fichier source '$SOURCE' n'existe pas${NC}"
    exit 1
fi

# Vérification des prérequis
echo -e "${GREEN}=== Vérification des prérequis ===${NC}"
MISSING_TOOLS=""

for tool in virt-v2v python3 virt-ls virt-customize virt-copy-in virt-copy-out; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    echo -e "${RED}Erreur: Les outils suivants sont manquants:${MISSING_TOOLS}${NC}"
    echo "Installez-les avec: dnf install virt-v2v python3-libguestfs"
    exit 1
fi

# Vérifier la présence du script Python
if [ ! -f "migrate_centos.py" ]; then
    echo -e "${RED}Erreur: migrate_centos.py non trouvé dans le répertoire courant${NC}"
    exit 1
fi

# Vérifier la présence du répertoire bases
if [ ! -d "bases" ]; then
    echo -e "${YELLOW}Warning: Répertoire 'bases' non trouvé. Exécution de create_bases.sh...${NC}"
    if [ -f "create_bases.sh" ]; then
        bash create_bases.sh
    else
        echo -e "${RED}Erreur: create_bases.sh non trouvé${NC}"
        exit 1
    fi
fi

# Créer un répertoire de travail temporaire
WORK_DIR=$(mktemp -d /var/tmp/scaleway-migration.XXXXXX)
echo -e "${GREEN}Répertoire de travail: $WORK_DIR${NC}"

# Fonction de nettoyage
cleanup() {
    echo -e "${YELLOW}Nettoyage...${NC}"
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Détection du type de source et extraction d'informations
echo -e "${GREEN}=== Analyse de la source ===${NC}"
if [[ "$SOURCE" == *.ova ]]; then
    echo "Type détecté: OVA"

    # Extraire les informations sur les disques dans l'OVA
    echo "Extraction des métadonnées OVA..."
    cd "$WORK_DIR"
    tar -tf "$SOURCE" | grep -E '\.(vmdk|ovf)$' > ova_contents.txt || true

    # Afficher le contenu
    echo "Contenu de l'OVA:"
    cat ova_contents.txt

    # Compter les disques
    DISK_COUNT=$(grep -c '\.vmdk$' ova_contents.txt || echo 0)
    echo -e "${YELLOW}Nombre de disques détectés: $DISK_COUNT${NC}"

    if [ "$DISK_COUNT" -gt 1 ]; then
        echo -e "${YELLOW}⚠️  Attention: OVA multi-disques détecté. Seul le disque système sera migré.${NC}"
        echo "Les autres disques devront être migrés séparément si nécessaire."
    fi

    cd - > /dev/null
else
    echo "Type détecté: Image disque (qcow2/vmdk)"
fi

# Exécution de la migration
echo -e "${GREEN}=== Démarrage de la migration ===${NC}"
echo "Source: $SOURCE"
echo "Destination: $DEST"

# Créer un fichier de log
LOG_FILE="$WORK_DIR/migration.log"
echo "Log complet disponible dans: $LOG_FILE"

# Exécuter le script de migration avec gestion d'erreur améliorée
if bash migrate_centos.sh "$SOURCE" "$DEST" 2>&1 | tee "$LOG_FILE"; then
    echo -e "${GREEN}✓ Migration terminée avec succès${NC}"
else
    EXIT_CODE=$?
    echo -e "${YELLOW}⚠️  La migration a retourné un code d'erreur: $EXIT_CODE${NC}"

    # Vérifier si le fichier de destination existe malgré l'erreur
    if [ -f "$DEST" ]; then
        echo -e "${GREEN}✓ Le fichier de destination a été créé malgré l'erreur${NC}"
        echo "Cela peut arriver avec les OVA multi-disques ou les systèmes sans EFI."
    else
        echo -e "${RED}✗ Échec de la migration - aucun fichier de sortie${NC}"
        echo ""
        echo "Dernières lignes du log:"
        tail -n 20 "$LOG_FILE"
        exit 1
    fi
fi

# Vérifications post-migration
if [ -f "$DEST" ]; then
    echo -e "${GREEN}=== Vérifications post-migration ===${NC}"

    # Vérifier la taille du fichier
    SIZE=$(du -h "$DEST" | cut -f1)
    echo "Taille du fichier de destination: $SIZE"

    # Essayer de détecter le mode de boot
    echo -n "Mode de boot détecté: "
    if virt-ls -a "$DEST" /boot/efi/EFI 2>/dev/null | grep -q .; then
        echo "UEFI"
    else
        echo "Legacy BIOS"
    fi

    # Vérifier fstab pour les problèmes potentiels
    echo ""
    echo "Vérification de /etc/fstab:"
    if virt-cat -a "$DEST" /etc/fstab 2>/dev/null | grep -E '^[^#]*(/backup|/data)' | grep -v '^#'; then
        echo -e "${YELLOW}⚠️  Des points de montage pour des disques additionnels ont été trouvés.${NC}"
        echo "   Ils ont été commentés dans fstab pour éviter des problèmes au boot."
    else
        echo -e "${GREEN}✓ Pas de points de montage problématiques détectés${NC}"
    fi

    # Créer le script de post-migration si nécessaire
    if [ -f "post_migration_fix.sh" ]; then
        cp post_migration_fix.sh "$WORK_DIR/post_migration_fix.sh"
        echo ""
        echo -e "${YELLOW}Script de correction post-migration disponible:${NC}"
        echo "  $WORK_DIR/post_migration_fix.sh"
        echo "  À exécuter sur l'instance après le premier boot si nécessaire."
    fi
fi

# Instructions finales
echo ""
echo -e "${GREEN}=== Migration terminée ===${NC}"
echo ""
echo "Prochaines étapes:"
echo "1. Télécharger l'image sur Scaleway:"
echo "   scw instance image create name=<nom> arch=x86_64 file=$DEST"
echo ""
echo "2. Créer une instance avec cette image"
echo ""
echo "3. Si nécessaire, exécuter le script de correction après le premier boot:"
echo "   $WORK_DIR/post_migration_fix.sh"
echo ""

if [ "$DISK_COUNT" -gt 1 ] 2>/dev/null; then
    echo -e "${YELLOW}Note: Pour migrer les disques de données additionnels:${NC}"
    echo "1. Extraire les VMDK de l'OVA: tar -xf $SOURCE"
    echo "2. Convertir chaque disque: qemu-img convert -f vmdk -O qcow2 disk.vmdk disk.qcow2"
    echo "3. Créer des volumes Scaleway et y copier les données"
fi

# Conserver le log et le script post-migration
cp "$LOG_FILE" "$(dirname "$DEST")/migration-$(date +%Y%m%d-%H%M%S).log"
if [ -f "$WORK_DIR/post_migration_fix.sh" ]; then
    cp "$WORK_DIR/post_migration_fix.sh" "$(dirname "$DEST")/"
fi

echo ""
echo -e "${GREEN}✓ Terminé!${NC}"
