#!/usr/bin/env python3
import logging
import sys
from pathlib import Path
import guestfs

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(levelname)s:%(name)s:%(message)s")

BASES_DIR = Path(__file__).resolve().parent / "bases"

# Actions de base communes
BASE_ACTIONS = [
    ["copy_in", str(BASES_DIR), "/run"],
    ["sh", "chown -R 0:0 /run/bases"],
    ["cp_a", "/run/bases/root", "/"],
    ["cp_a", "/run/bases/etc", "/"],
    ["chmod", 448, "/root"],
    ["chmod", 448, "/root/.ssh"],
    ["chmod", 420, "/etc/sysconfig/qemu-ga.scaleway"],
    ["chmod", 420, "/etc/systemd/system/qemu-guest-agent.service.d/50-scaleway.conf"],
    ["chmod", 420, "/etc/NetworkManager/conf.d/00-scaleway.conf"],
    ["chmod", 436, "/root/.ssh/instance_keys"],
    ["chmod", 493, "/etc"],
    ["chmod", 493, "/etc/sysconfig"],
    ["chmod", 493, "/etc/systemd"],
    ["chmod", 493, "/etc/systemd/system"],
    ["chmod", 493, "/etc/systemd/system/qemu-guest-agent.service.d"],
    ["chmod", 493, "/etc/NetworkManager"],
    ["chmod", 493, "/etc/NetworkManager/conf.d"],
    ["sh", 'echo "timeout 5;" > /etc/dhcp/dhclient.conf'],
    ["sh", "rm -Rf /run/bases"],
    ["sh", "rm -f /etc/ld.so.cache"],
    ["sh", ": > /etc/machine-id"],
    ["sh", "grubby --args=console=ttyS0,115200n8 --update-kernel $(grubby --default-kernel)"],
    ["sh", "systemctl set-default multi-user.target"],
    ["sh", r"sed -ri '/^net.ipv4.conf.all.arp_ignore\s*=/{s/.*/net.ipv4.conf.all.arp_ignore = 1/}' /etc/sysctl.conf"],
]


def detect_boot_mode(g: guestfs.GuestFS) -> str:
    """Détecte le mode de boot (UEFI ou Legacy)"""
    # Vérifier si /boot/efi existe et est monté
    if g.exists("/boot/efi") and g.is_dir("/boot/efi"):
        # Vérifier si EFI directory existe
        if g.exists("/boot/efi/EFI"):
            logger.info("Mode de boot détecté : UEFI")
            return "uefi"

    # Vérifier la présence de grub legacy
    if g.exists("/boot/grub2/grub.cfg") or g.exists("/boot/grub/grub.cfg"):
        logger.info("Mode de boot détecté : Legacy BIOS")
        return "legacy"

    logger.warning("Mode de boot non déterminé, assumant Legacy BIOS")
    return "legacy"


def guest_mount(g: guestfs.GuestFS, single_disk_mode: bool = True) -> None:
    """Monte les systèmes de fichiers, avec option pour gérer un seul disque."""
    roots = g.inspect_os()
    if len(roots) != 1:
        raise RuntimeError(f"Impossible de gérer plusieurs racines : {roots}")
    root = roots[0]

    # Obtenir la liste des devices disponibles
    available_devices = set(g.list_devices())
    logger.info(f"Devices disponibles : {available_devices}")

    # Track mounted filesystems
    mounted = []

    for mountpoint, device in sorted(g.inspect_get_mountpoints(root).items()):
        # En mode single_disk, on ignore les points de montage des disques non disponibles
        if single_disk_mode:
            # Extraire le device de base (ex: /dev/sda1 -> /dev/sda)
            device_parts = device.split('/')
            if len(device_parts) >= 3:
                device_base = '/' + '/'.join(device_parts[1:3])
                device_base = device_base.rstrip('0123456789')

                # Vérifier si c'est un disque secondaire non disponible
                if device_base not in available_devices and any(skip_word in mountpoint.lower()
                    for skip_word in ['backup', 'data', 'storage']):
                    logger.warning(f"Skipping mount of {device} on {mountpoint} - disk not available")
                    continue

        try:
            g.mount(device, mountpoint)
            mounted.append(mountpoint)
            logger.info(f"Monté : {device} sur {mountpoint}")
        except Exception as e:
            logger.warning(f"Impossible de monter {device} sur {mountpoint}: {e}")
            # Continue avec les autres points de montage

    return mounted


def fix_fstab_for_scaleway(g: guestfs.GuestFS, single_disk_mode: bool = True) -> None:
    """Corrige les entrées fstab pour Scaleway"""
    try:
        fstab_content = g.cat("/etc/fstab")
        original_content = fstab_content

        # Remplacer vda par sda si nécessaire
        if "/dev/vda" in fstab_content:
            fstab_content = fstab_content.replace("/dev/vda", "/dev/sda")
            logger.info("Fixed /etc/fstab entries from vda to sda")

        # En mode single disk, commenter les lignes pour les disques non disponibles
        if single_disk_mode:
            lines = fstab_content.split('\n')
            new_lines = []
            available_devices = set(g.list_devices())

            for line in lines:
                # Skip empty lines and comments
                if not line.strip() or line.strip().startswith('#'):
                    new_lines.append(line)
                    continue

                # Parse fstab line
                parts = line.split()
                if len(parts) >= 2:
                    device = parts[0]
                    mountpoint = parts[1]

                    # Check if it's a device entry
                    if device.startswith('/dev/'):
                        # Extract base device
                        device_base = device.rstrip('0123456789')

                        # Check if device exists
                        if device_base not in available_devices and any(skip_word in mountpoint.lower()
                            for skip_word in ['backup', 'data', 'storage']):
                            logger.info(f"Commenting out fstab entry for missing device: {device} -> {mountpoint}")
                            new_lines.append(f"# {line} # Commented by migration - disk not available")
                        else:
                            new_lines.append(line)
                    else:
                        new_lines.append(line)
                else:
                    new_lines.append(line)

            fstab_content = '\n'.join(new_lines)

        # Write new fstab if changed
        if fstab_content != original_content:
            # Backup du fstab original
            g.mv("/etc/fstab", "/etc/fstab.bak.migration")

            # Écrire le nouveau fstab
            g.write("/etc/fstab", fstab_content)
            logger.info("Updated /etc/fstab")

    except Exception as e:
        logger.error(f"Erreur lors de la correction du fstab : {e}")


def fix_grub_for_scaleway(g: guestfs.GuestFS) -> None:
    """Corrige les entrées GRUB pour Scaleway (vda -> sda)"""
    try:
        # Corriger /etc/default/grub si nécessaire
        if g.exists("/etc/default/grub"):
            grub_content = g.cat("/etc/default/grub")
            if "/dev/vda" in grub_content:
                fixed_content = grub_content.replace("/dev/vda", "/dev/sda")
                g.write("/etc/default/grub", fixed_content)
                logger.info("Fixed /etc/default/grub entries from vda to sda")

        # Corriger grub.cfg si accessible
        grub_cfg_paths = ["/boot/grub2/grub.cfg", "/boot/grub/grub.cfg"]
        for grub_cfg in grub_cfg_paths:
            if g.exists(grub_cfg):
                try:
                    grub_cfg_content = g.cat(grub_cfg)
                    if "/dev/vda" in grub_cfg_content:
                        fixed_content = grub_cfg_content.replace("/dev/vda", "/dev/sda")
                        g.write(grub_cfg, fixed_content)
                        logger.info(f"Fixed {grub_cfg} entries from vda to sda")
                except Exception as e:
                    logger.warning(f"Could not fix {grub_cfg}: {e}")

    except Exception as e:
        logger.error(f"Erreur lors de la correction de GRUB : {e}")


def main(qcow_path: str, debug: bool = False) -> None:
    g = guestfs.GuestFS(python_return_dict=True)
    g.backend = "direct"
    g.set_trace(debug)
    g.set_verbose(debug)

    logger.info("Ajout du disque : %s", qcow_path)
    g.add_drive_opts(qcow_path, format="qcow2", readonly=False)
    g.set_network(True)
    g.launch()

    # Monter avec support single disk
    mounted_points = guest_mount(g, single_disk_mode=True)

    # Détecter le mode de boot
    boot_mode = detect_boot_mode(g)

    # Corriger fstab et grub AVANT les autres actions
    fix_fstab_for_scaleway(g, single_disk_mode=True)
    fix_grub_for_scaleway(g)

    # Préparer les actions selon le mode de boot
    actions = BASE_ACTIONS.copy()

    # Ajouter umount /boot/efi seulement si UEFI et monté
    if boot_mode == "uefi" and "/boot/efi" in mounted_points:
        actions.append(["umount", "/boot/efi"])

    # Ajouter les actions SELinux
    actions.extend([
        ["selinux_relabel", "/etc/selinux/targeted/contexts/files/file_contexts", "/boot"],
        ["selinux_relabel", "/etc/selinux/targeted/contexts/files/file_contexts", "/"],
    ])

    # Exécuter les actions
    for action in actions:
        mname, *args = action
        if not isinstance(mname, str):
            raise TypeError(f"Entrée mal formée dans ACTIONS : {action!r}")

        try:
            ret = getattr(g, mname)(*args)
            if isinstance(ret, int) and ret != 0:
                raise RuntimeError(f"{mname} a renvoyé le code d'erreur {ret}")
        except Exception as e:
            logger.warning(f"Erreur lors de l'exécution de {mname}: {e}")
            # Continue avec les autres actions pour certaines erreurs non critiques
            if mname not in ["umount", "selinux_relabel"]:
                raise

    # Fermer proprement
    g.shutdown()
    g.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"Usage : {sys.argv[0]} <image.qcow2>")
    main(sys.argv[1])
