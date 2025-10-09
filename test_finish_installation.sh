#!/bin/bash
# Test script to complete installation from GRUB sync step onwards
# Run this from Live USB with /mnt still mounted after installation failure
# This simulates everything from "Installing GRUB to all ZFS mirror drives" to the end

set -euo pipefail

echo "=========================================="
echo "Installation Completion Test"
echo "Starting from GRUB sync step"
echo "=========================================="
echo

# Check if running in the right environment
if ! mountpoint -q /mnt 2>/dev/null; then
    echo "ERROR: /mnt is not mounted."
    echo "Usage: Exit the installer leaving everything mounted, then run this script"
    exit 1
fi

echo "✓ Environment check passed (/mnt is mounted)"
echo

# Logging functions
log_info() { echo "$(date '+%F %T') INFO: $1"; }
log_warning() { echo "$(date '+%F %T') WARNING: $1"; }
log_error() { echo "$(date '+%F %T') ERROR: $1" >&2; }

# Copy the get_drive_identifier function from the main script
get_drive_identifier() {
    local disk_path="$1"
    local model_part=""
    local suffix_part=""

    if [[ "${disk_path}" =~ nvme-(.+)_([A-Za-z0-9-]{8,})$ ]]; then
        model_part="${BASH_REMATCH[1]}"
        suffix_part="${BASH_REMATCH[2]}"
    elif [[ "${disk_path}" =~ (ata|scsi)-(.+)_([A-Za-z0-9-]{8,})$ ]]; then
        model_part="${BASH_REMATCH[2]}"
        suffix_part="${BASH_REMATCH[3]}"
    else
        local dev_name=$(basename "${disk_path}")
        model_part="Disk"
        suffix_part="${dev_name}"
    fi

    # Strip redundant prefixes
    if [[ "${model_part}" =~ ^[Ss][Aa][Tt][Aa][-_](.+)$ ]]; then
        model_part="${BASH_REMATCH[1]}"
    elif [[ "${model_part}" =~ ^[Aa][Tt][Aa][-_](.+)$ ]]; then
        model_part="${BASH_REMATCH[1]}"
    fi

    # Clean up
    model_part="${model_part//_/-}"
    model_part="${model_part##-}"
    model_part="${model_part%%-}"
    while [[ "${model_part}" == *"--"* ]]; do
        model_part="${model_part//--/-}"
    done

    # Truncate to 15 chars
    if [[ ${#model_part} -gt 15 ]]; then
        model_part="${model_part:0:15}"
        model_part="${model_part%-}"
    fi

    # Get last 4 from suffix
    local last_four="${suffix_part: -4}"
    if [[ ${#last_four} -lt 4 ]]; then
        last_four=$(printf "%04s" "${last_four}" | tr ' ' '0')
    fi

    echo "${model_part}-${last_four}"
}

echo "=========================================="
echo "Step 1: Installing GRUB to all drives"
echo "=========================================="
echo

log_info "Getting EFI UUID from fstab..."
EFI_UUID=$(chroot /mnt awk '/\/boot\/efi/ && /^UUID=/ {gsub(/UUID=/, "", $1); print $1}' /etc/fstab 2>/dev/null || echo "")

if [[ -z "${EFI_UUID}" ]]; then
    log_error "Could not find EFI UUID in fstab"
    exit 1
fi
log_info "EFI UUID: $EFI_UUID"

log_info "Finding mounted EFI partition..."
MOUNTED_EFI=$(chroot /mnt mount | grep '/boot/efi' | awk '{print $1}')

if [[ -z "${MOUNTED_EFI}" ]]; then
    log_error "No EFI partition currently mounted at /boot/efi"
    exit 1
fi
log_info "Mounted EFI: $MOUNTED_EFI"

log_info "Finding all EFI partitions..."
mapfile -t EFI_PARTITIONS < <(blkid --output device --match-token UUID="${EFI_UUID}" 2>/dev/null || true)

if [[ ${#EFI_PARTITIONS[@]} -lt 2 ]]; then
    log_warning "Only ${#EFI_PARTITIONS[@]} EFI partition(s) found, expected 2+"
fi

log_info "Building partition->drive map..."
declare -A PARTITION_TO_DRIVE
for efi_part in "${EFI_PARTITIONS[@]}"; do
    # First, resolve device path to by-id path for stable naming
    base_drive=""

    if [[ "$efi_part" =~ ^(.+)-part[0-9]+$ ]]; then
        # Already a by-id path: /dev/disk/by-id/ata-DISK123-part1
        base_drive="${BASH_REMATCH[1]}"
    elif [[ "$efi_part" =~ ^(.+)p[0-9]+$ ]]; then
        # Device path: /dev/nvme0n1p1 -> need to find by-id equivalent
        device_base="${BASH_REMATCH[1]}"

        # Find the by-id link that points to this device base
        by_id_path=""
        for link in /dev/disk/by-id/*; do
            # Skip partition links
            [[ "$link" =~ -part[0-9]+$ ]] && continue
            [[ "$link" =~ p[0-9]+$ ]] && continue

            # Check if this link points to our device
            if [[ -L "$link" ]]; then
                target=$(readlink -f "$link")
                if [[ "$target" == "$device_base" ]]; then
                    by_id_path="$link"
                    break
                fi
            fi
        done

        if [[ -n "$by_id_path" ]]; then
            base_drive="$by_id_path"
            log_info "  Resolved: $efi_part -> $device_base -> $base_drive"
        else
            log_warning "  Could not find by-id path for $device_base, using device path"
            base_drive="$device_base"
        fi
    else
        log_warning "  Could not parse partition name: $efi_part (will skip)"
        continue
    fi

    PARTITION_TO_DRIVE["$efi_part"]="$base_drive"
    log_info "  Mapped: $efi_part -> $base_drive"
done

log_info "Found ${#EFI_PARTITIONS[@]} EFI partition(s) to sync"

# Install GRUB to each drive
INSTALL_COUNT=0
for efi_part in "${EFI_PARTITIONS[@]}"; do
    base_drive="${PARTITION_TO_DRIVE[$efi_part]:-}"
    if [[ -z "$base_drive" ]]; then
        log_warning "Could not determine base drive for $efi_part, skipping"
        continue
    fi

    DRIVE_ID=$(get_drive_identifier "$base_drive")
    log_info "Processing $efi_part (Drive: $base_drive, ID: Ubuntu-${DRIVE_ID})"

    if [[ "$efi_part" == "$MOUNTED_EFI" ]]; then
        log_info "  Installing to mounted partition..."
        if chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Ubuntu-${DRIVE_ID}" --recheck --no-floppy "$base_drive"; then
            log_info "  ✓ GRUB installed to mounted partition"
            ((INSTALL_COUNT++))
        else
            log_error "  ✗ Failed to install GRUB to mounted partition"
        fi
    else
        # Mount the other partition temporarily
        TEMP_MOUNT=$(mktemp -d)
        log_info "  Mounting $efi_part at $TEMP_MOUNT..."

        if mount "$efi_part" "$TEMP_MOUNT"; then
            log_info "  Installing to $TEMP_MOUNT..."
            if chroot /mnt grub-install --target=x86_64-efi --efi-directory="$TEMP_MOUNT" --bootloader-id="Ubuntu-${DRIVE_ID}" --recheck --no-floppy "$base_drive"; then
                log_info "  ✓ GRUB installed to $efi_part"
                ((INSTALL_COUNT++))
            else
                log_error "  ✗ Failed to install GRUB to $efi_part"
            fi
            umount "$TEMP_MOUNT"
        else
            log_error "  ✗ Failed to mount $efi_part"
        fi
        rmdir "$TEMP_MOUNT"
    fi
done

if [[ ${INSTALL_COUNT} -eq 0 ]]; then
    log_error "Failed to install GRUB to any drives"
    exit 1
fi

log_info "GRUB sync complete (installed to ${INSTALL_COUNT} partition(s))"
echo

echo "=========================================="
echo "Step 2: Syncing EFI partitions"
echo "=========================================="
echo

log_info "Running EFI partition sync..."
if chroot /mnt /usr/local/bin/sync-efi-partitions; then
    log_info "✓ EFI partition sync completed"
else
    log_warning "EFI sync had issues (check logs above)"
fi
echo

echo "=========================================="
echo "Step 3: Validation"
echo "=========================================="
echo

log_info "Checking GRUB configuration..."
if chroot /mnt grep -q "zfs_force=1" /boot/grub/grub.cfg; then
    FORCE_COUNT=$(chroot /mnt grep -c "zfs_force=1" /boot/grub/grub.cfg)
    log_info "✓ zfs_force=1 found ($FORCE_COUNT occurrence(s))"
else
    log_error "✗ zfs_force=1 NOT found in grub.cfg"
fi

log_info "Checking boot entries..."
if command -v efibootmgr &>/dev/null; then
    log_info "EFI boot entries:"
    efibootmgr | grep -i ubuntu || log_warning "No Ubuntu entries found"
else
    log_warning "efibootmgr not available (run from installed system to check)"
fi
echo

echo "=========================================="
echo "Step 4: Final status check"
echo "=========================================="
echo

log_info "Checking created scripts..."
SCRIPTS=(
    "/mnt/usr/local/bin/sync-grub-to-mirror-drives"
    "/mnt/usr/local/bin/sync-efi-partitions"
    "/mnt/usr/local/bin/sync-mirror-boot"
)

ALL_SCRIPTS_OK=true
for script in "${SCRIPTS[@]}"; do
    if [[ -x "$script" ]]; then
        log_info "✓ $script exists and is executable"
    else
        log_error "✗ $script missing or not executable"
        ALL_SCRIPTS_OK=false
    fi
done

log_info "Checking systemd services..."
SERVICES=(
    "zfs-firstboot-cleanup.service"
    "zfs-mirror-shutdown-sync.service"
)

for service in "${SERVICES[@]}"; do
    if chroot /mnt systemctl is-enabled "$service" &>/dev/null; then
        log_info "✓ $service is enabled"
    else
        log_warning "✗ $service is not enabled"
    fi
done
echo

echo "=========================================="
echo "Summary"
echo "=========================================="
echo "GRUB installations: $INSTALL_COUNT"
echo "EFI partitions: ${#EFI_PARTITIONS[@]}"
echo

if [[ ${INSTALL_COUNT} -eq ${#EFI_PARTITIONS[@]} && "$ALL_SCRIPTS_OK" == "true" ]]; then
    echo "✅ Installation completion test PASSED"
    echo ""
    echo "Next steps:"
    echo "1. Unmount everything: umount -R /mnt"
    echo "2. Reboot and remove installation media"
    echo "3. System should boot with 'Ubuntu - Force ZFS import first boot'"
    echo "4. After first boot, check: journalctl -u zfs-firstboot-cleanup"
    exit 0
else
    echo "⚠️  Some issues detected - review logs above"
    echo ""
    echo "You can still try to boot, but review the errors first"
    exit 1
fi
