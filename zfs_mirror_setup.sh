#!/bin/bash

# Ubuntu 24.04 ZFS Root Installation Script - Enhanced & Cleaned Version
# Creates a ZFS mirror on two drives with full redundancy
# Supports: NVMe, SATA SSD, SATA HDD, SAS, and other drive types
# License: MIT
# Original Repository: https://github.com/csmarshall/ubuntu-zfs-mirror
# Enhanced Version: https://claude.ai - Production-ready fixes

set -euo pipefail

# Script metadata
readonly VERSION="6.5.2"
readonly SCRIPT_NAME="$(basename "$0")"
readonly ORIGINAL_REPO="https://github.com/csmarshall/ubuntu-zfs-mirror"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly PINK='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Configure logging with timestamp and proper file handling
LOG_FILE="/tmp/zfs-mirror-root-install-$(date +%Y%m%dT%H%M%S).log"

# Save original file descriptors FIRST
exec 3>&1 4>&2

# Then redirect with proper error handling
exec 1> >(tee -a "${LOG_FILE}" >&3)
exec 2> >(tee -a "${LOG_FILE}" >&4)

# Timestamp function for consistent logging
ts() {
    date +'%F %T'
}

# Enhanced logging functions with color and timestamps
log_info() {
    echo -e "${GREEN}$(ts) INFO:${NC} $*"
}

log_debug() {
    echo -e "${PINK}$(ts) DEBUG:${NC} $*"
}

log_error() {
    echo -e "${RED}$(ts) ERROR:${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}$(ts) WARNING:${NC} $*"
}

log_header() {
    echo -e "\n${BOLD}========================================${NC}"
    echo -e "${BOLD}$*${NC}"
    echo -e "${BOLD}========================================${NC}\n"
}

# Progress indicator with improved formatting
show_progress() {
    local current=$1
    local total=$2
    local task=$3
    local percent=$((current * 100 / total))
    
    printf "[%-50s] %d%% - %s\n" \
           "$(printf '#%.0s' $(seq 1 $((percent / 2))))" \
           "${percent}" \
           "${task}"
}

# ============================================================================
# UTILITY FUNCTIONS - All helper functions defined up front
# ============================================================================

# Countdown timer with CTRL+C abort capability
countdown_timer() {
    local seconds=${1:-10}
    local message=${2:-"Operation will begin"}

    echo ""
    echo -e "${YELLOW}${BOLD}⚠️  ${message} in ${seconds} seconds${NC}"
    echo -e "${BOLD}Press CTRL+C to cancel or any key to continue immediately...${NC}"
    echo ""

    # Set up trap to catch CTRL+C
    trap 'echo -e "\n${GREEN}Operation cancelled by user${NC}"; exit 0' INT

    while [[ $seconds -gt 0 ]]; do
        printf "\r${BOLD}Starting in: %2d seconds... ${NC}" "$seconds"

        # Check if user pressed any key (non-blocking)
        if read -t 1 -n 1 key 2>/dev/null; then
            echo ""
            echo -e "${GREEN}Continuing immediately...${NC}"
            echo ""
            break
        fi

        ((seconds--))
    done

    if [[ $seconds -eq 0 ]]; then
        printf "\r${BOLD}Starting now...                    ${NC}\n"
        echo ""
    fi

    # Reset trap
    trap - INT
}

# Get all possible partition paths for a disk
get_all_partitions() {
    local disk="$1"
    local partitions=()
    
    log_debug "Scanning for partitions on disk: ${disk}" >&2
    
    # Handle all partition naming schemes
    for pattern in "-part" "p" ""; do
        for num in {1..9}; do
            local part="${disk}${pattern}${num}"
            if [[ -b "${part}" ]]; then
                partitions+=("${part}")
                log_debug "Found partition: ${part}" >&2
            fi
        done
    done
    
    # Output each partition on separate line for safe consumption
    printf '%s\n' "${partitions[@]}"
}

# Clear all ZFS labels from disk and partitions
clear_zfs_labels() {
    local disk="$1"
    
    log_debug "Clearing ZFS labels from ${disk} and all partitions" >&2
    
    # Clear from all partitions using safe iteration
    while IFS= read -r part; do
        if [[ -n "${part}" ]]; then
            log_debug "Clearing ZFS label from partition: ${part}" >&2
            zpool labelclear -f "${part}" 2>/dev/null || true
        fi
    done < <(get_all_partitions "${disk}")
    
    # Clear from main disk
    log_debug "Clearing ZFS label from main disk: ${disk}" >&2
    zpool labelclear -f "${disk}" 2>/dev/null || true
}

# Destroy specific pool with comprehensive error handling
destroy_specific_pool() {
    local pool_name="$1"
        
    log_debug "Attempting to destroy pool: ${pool_name}" >&2
        
    # First check if pool exists
    if ! zpool list "${pool_name}" &>/dev/null; then
        log_debug "Pool ${pool_name} does not exist" >&2
        return 0
    fi
        
    # Try to destroy any datasets first
    log_debug "Destroying datasets in ${pool_name}" >&2
    zfs list -H -o name -r "${pool_name}" 2>/dev/null | tac | while read -r dataset; do
        if [[ "${dataset}" != "${pool_name}" ]]; then
            log_debug "Destroying dataset: ${dataset}" >&2
            zfs destroy -f "${dataset}" 2>/dev/null || true
        fi
    done
        
    # Unmount all datasets
    log_debug "Unmounting all datasets in ${pool_name}" >&2
    zfs unmount -a 2>/dev/null || true
        
    # Try normal destroy
    if zpool destroy -f "${pool_name}" 2>/dev/null; then
        log_info "Successfully destroyed pool ${pool_name}"
        return 0
    fi
        
    # Try export then destroy
    log_debug "Normal destroy failed, trying export first" >&2
    zpool export -f "${pool_name}" 2>/dev/null || true
        
    # Check if it's really gone
    if ! zpool list "${pool_name}" &>/dev/null; then
        log_info "Pool ${pool_name} successfully exported"
        return 0
    fi
        
    # Last resort - force import and destroy
    log_warning "Pool ${pool_name} still exists, trying force import and destroy"
    zpool import -f -N "${pool_name}" 2>/dev/null || true
    zpool destroy -f "${pool_name}" 2>/dev/null || true
        
    # Final check
    if zpool list "${pool_name}" &>/dev/null; then
        log_error "Failed to destroy pool ${pool_name} completely"
        return 1
    fi
        
    return 0
}

# Destroy all ZFS pools cleanly with proper error handling
destroy_all_pools() {
    log_debug "Destroying all existing ZFS pools" >&2
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
        
    if [[ -n "${pools}" ]]; then
        while IFS= read -r pool; do
            destroy_specific_pool "${pool}"
        done <<< "${pools}"
    else
        log_debug "No ZFS pools found to destroy" >&2
    fi
    
    # Export any remaining pools
    zpool export -a 2>/dev/null || true
}

# Basic ZFS cleanup for pool creation preparation
perform_basic_zfs_cleanup() {
    local pool_name="$1"
    local part1="$2"
    local part2="$3"
        
    log_info "Performing ZFS cleanup for ${pool_name}"
        
    # Try to destroy the specific pool if it exists
    destroy_specific_pool "${pool_name}"
        
    # Clear labels on the partitions
    log_debug "Clearing labels on ${part1}"
    zpool labelclear -f "${part1}" 2>/dev/null || true
        
    log_debug "Clearing labels on ${part2}"
    zpool labelclear -f "${part2}" 2>/dev/null || true
        
    # Force kernel to re-read partitions
    partprobe "${part1}" "${part2}" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
        
    # Brief wait for kernel to settle
    sleep 2
        
    log_info "ZFS cleanup completed for ${pool_name}"
}


# Stop services using a disk with comprehensive checks
stop_disk_services() {
    local disk="$1"
    local disk_basename
    disk_basename=$(basename "${disk}")
    
    log_debug "Stopping services using disk: ${disk}" >&2
    
    # Stop swap on all possible partitions using safe iteration
    while IFS= read -r part; do
        if [[ -n "${part}" ]]; then
            log_debug "Checking swap on partition: ${part}" >&2
            if grep -q "${part}" /proc/swaps 2>/dev/null; then
                log_info "Stopping swap on ${part}"
                swapoff "${part}" 2>/dev/null || true
            fi
        fi
    done < <(get_all_partitions "${disk}")
    
    # Stop MD arrays if present
    if [[ -f /proc/mdstat ]] && grep -q "${disk_basename}" /proc/mdstat 2>/dev/null; then
        log_warning "Stopping MD arrays on ${disk}"
        mdadm --stop /dev/md* 2>/dev/null || true
        mdadm --zero-superblock --force "${disk}" 2>/dev/null || true
    fi
    
    # Unmount any mounted filesystems on this disk
    while IFS= read -r part; do
        if [[ -n "${part}" ]] && mount | grep -q "^${part} "; then
            local mountpoint
            mountpoint=$(mount | grep "^${part} " | awk '{print $3}' | head -1)
            log_info "Unmounting ${part} from ${mountpoint}"
            umount "${part}" 2>/dev/null || umount -l "${part}" 2>/dev/null || true
        fi
    done < <(get_all_partitions "${disk}")
}

# Get drive identifier for UEFI naming with hybrid model-suffix approach
# Creates unique identifiers in format: <Model15chars>-<Last4Suffix>
# This ensures drives can be distinguished even if identical models
get_drive_identifier() {
    local disk_path="$1"
    local model_part=""
    local suffix_part=""
    local full_id=""

    log_debug "Generating UEFI-compatible identifier for: ${disk_path}" >&2

    # Validate input
    if [[ -z "${disk_path}" ]]; then
        log_error "get_drive_identifier: Empty disk path provided" >&2
        return 1
    fi

    # Extract model and suffix from by-id path
    if [[ "${disk_path}" =~ nvme-(.+)_([A-Za-z0-9-]{8,})$ ]]; then
        model_part="${BASH_REMATCH[1]}"
        suffix_part="${BASH_REMATCH[2]}"
        log_debug "Extracted NVMe model: '${model_part}', suffix: '${suffix_part}'" >&2
    elif [[ "${disk_path}" =~ (ata|scsi)-(.+)_([A-Za-z0-9-]{8,})$ ]]; then
        model_part="${BASH_REMATCH[2]}"
        suffix_part="${BASH_REMATCH[3]}"
        log_debug "Extracted ${BASH_REMATCH[1]} model: '${model_part}', suffix: '${suffix_part}'" >&2
    else
        # Fallback to using lsblk with device name as suffix
        local dev_name
        dev_name=$(readlink -f "${disk_path}" 2>/dev/null | xargs basename 2>/dev/null || echo "")
        if [[ -n "${dev_name}" && -b "/dev/${dev_name}" ]]; then
            model_part=$(lsblk -ndo MODEL "/dev/${dev_name}" 2>/dev/null | sed 's/[[:space:]]*$//' | sed 's/ /_/g' || echo "")
            suffix_part="${dev_name}"
            log_debug "lsblk fallback model: '${model_part}', device suffix: '${suffix_part}'" >&2
        fi
    fi

    # If still no model, use generic one with unique device-based suffix
    if [[ -z "${model_part}" ]]; then
        local dev_name
        dev_name=$(basename "$(readlink -f "${disk_path}" 2>/dev/null)" 2>/dev/null || basename "${disk_path}")
        model_part="Disk"
        suffix_part="${dev_name}"
        log_debug "Generic fallback model: '${model_part}', device suffix: '${suffix_part}'" >&2
    fi

    # Clean up model part for UEFI compatibility
    # Strip common redundant prefixes (case insensitive)
    if [[ "${model_part}" =~ ^[Ss][Aa][Tt][Aa][-_](.+)$ ]]; then
        model_part="${BASH_REMATCH[1]}"
    elif [[ "${model_part}" =~ ^[Aa][Tt][Aa][-_](.+)$ ]]; then
        model_part="${BASH_REMATCH[1]}"
    fi

    # Convert underscores to dashes for consistency
    model_part="${model_part//_/-}"
    model_part="${model_part##-}"
    model_part="${model_part%%-}"

    # Remove consecutive dashes from model
    while [[ "${model_part}" == *"--"* ]]; do
        model_part="${model_part//--/-}"
    done

    # Truncate model to 15 characters to leave room for -XXXX suffix
    if [[ ${#model_part} -gt 15 ]]; then
        model_part="${model_part:0:15}"
        model_part="${model_part%-}"  # Remove trailing dash if any
        log_debug "Truncated model to 15 chars: '${model_part}'" >&2
    fi

    # Get last 4 characters from suffix for uniqueness (typically serial-like)
    last_four="${suffix_part: -4}"
    if [[ ${#last_four} -lt 4 ]]; then
        # Pad with zeros if suffix is too short
        last_four=$(printf "%04s" "${last_four}" | tr ' ' '0')
    fi

    # Construct final identifier: Model-Last4Suffix (max 20 chars: 15 + 1 + 4)
    full_id="${model_part}-${last_four}"

    # Final validation
    if [[ -z "${full_id}" || "${full_id}" == "-" ]]; then
        # Last resort: use device name with padding
        dev_name=$(basename "${disk_path}")
        full_id="Unknown-${dev_name: -4}"
        log_warning "Invalid identifier constructed, using device-based fallback: '${full_id}'" >&2
    fi

    log_debug "Final UEFI identifier: '${full_id}' (${#full_id} chars)" >&2
    echo "${full_id}"
    return 0
}

# Get network interface with improved detection and validation
get_network_interface() {
    local interfaces=()
    
    log_debug "Detecting network interfaces" >&2
    
    for iface in /sys/class/net/*; do
        local iface_name
        iface_name=$(basename "${iface}")
        # Skip virtual interfaces and loopback
        if [[ -d "${iface}/device" ]] && [[ "${iface_name}" != "lo" ]]; then
            interfaces+=("${iface_name}")
            log_debug "Found physical interface: ${iface_name}" >&2
        fi
    done
    
    local selected_interface
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        selected_interface="enp0s3"  # Default fallback
        log_warning "No physical interfaces found, using fallback: ${selected_interface}" >&2
    else
        selected_interface="${interfaces[0]}"  # Return first physical interface
        log_info "Selected network interface: ${selected_interface}" >&2
    fi
    
    echo "${selected_interface}"
    return 0
}

# Secure wipe function with comprehensive validation
secure_wipe_drive() {
    local disk="$1"
    local wipe_type="${2:-quick}"
    
    # Validate inputs
    if [[ -z "${disk}" ]]; then
        log_error "secure_wipe_drive: No disk specified"
        return 1
    fi
    
    if [[ ! -b "${disk}" ]]; then
        log_error "secure_wipe_drive: ${disk} is not a block device"
        return 1
    fi
    
    log_info "Performing ${wipe_type} wipe on ${disk}..."
    
    # Stop any services using the disk
    systemctl stop zed 2>/dev/null || true
    
    # Force kernel to drop caches for clean state
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    if [[ "${wipe_type}" == "full" ]]; then
        # Full security wipe with random data (slow but thorough)
        log_warning "Full wipe requested - this will take hours for large drives"
        dd if=/dev/urandom of="${disk}" bs=1M status=progress || {
            log_error "Full wipe failed on ${disk}"
            return 1
        }
    else
        # Quick wipe - critical areas only
        local disk_size
        disk_size=$(blockdev --getsize64 "${disk}" 2>/dev/null || echo "0")
        
        if [[ "${disk_size}" == "0" ]]; then
            log_error "Cannot determine size of ${disk}"
            return 1
        fi
        
        local disk_size_sectors=$((disk_size / 512))
        log_debug "Disk size: ${disk_size} bytes (${disk_size_sectors} sectors)" >&2
                
        # Wipe first 100MB (covers partition tables, boot sectors, ZFS labels)
        log_debug "Wiping first 100MB of ${disk}" >&2
        dd if=/dev/zero of="${disk}" bs=1M count=100 status=none 2>/dev/null || {
            log_warning "Failed to wipe beginning of ${disk}"
        }
                
        # Wipe last 100MB (covers GPT backup, ZFS labels at end)
        if [[ "${disk_size_sectors}" -gt 204800 ]]; then  # 204800 sectors = 100MB
            log_debug "Wiping last 100MB of ${disk}" >&2
            dd if=/dev/zero of="${disk}" bs=512 count=204800 \
               seek=$((disk_size_sectors - 204800)) status=none 2>/dev/null || {
                log_warning "Failed to wipe end of ${disk}"
            }
        fi
    fi
    
    # Force kernel to re-read partition table
    blockdev --rereadpt "${disk}" 2>/dev/null || true
    partprobe "${disk}" 2>/dev/null || true
    
    log_info "Wipe of ${disk} complete"
    return 0
}

# Generate deterministic Volume ID for EFI partitions
generate_efi_volume_id() {
    local hostname="$1"
    
    if [[ -z "${hostname}" ]]; then
        log_error "generate_efi_volume_id: No hostname provided"
        return 1
    fi
    
    local hostname_hash
    hostname_hash=$(echo -n "${hostname}" | sha256sum | cut -c1-8 2>/dev/null)
    
    if [[ -z "${hostname_hash}" ]]; then
        log_error "generate_efi_volume_id: Failed to generate hash from hostname"
        return 1
    fi
    
    # FAT32 volume ID is 32-bit hex (8 hex digits)
    local volume_id="${hostname_hash}"
    
    # Validate it's pure hex
    if [[ ! "${volume_id}" =~ ^[A-Fa-f0-9]{8}$ ]]; then
        log_error "generate_efi_volume_id: Invalid hex format: ${volume_id}"
        return 1
    fi
    
    echo "${volume_id}"
    return 0
}

# Validate required environment variables in chroot
validate_chroot_environment() {
    local required_vars=("DISK1" "DISK2" "EFI_VOLUME_ID" "ADMIN_USER" "ADMIN_PASS" "TIMEZONE")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("${var}")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        return 1
    fi
    
    return 0
}

# Robust GRUB_DEFAULT editing function
# Usage: set_grub_default "/path/to/grub" "entry_name_or_number"
set_grub_default() {
    local grub_file="$1"
    local default_value="$2"

    if [[ -z "${grub_file}" ]] || [[ -z "${default_value}" ]]; then
        log_error "set_grub_default: Missing required parameters"
        return 1
    fi

    if [[ ! -f "${grub_file}" ]]; then
        log_error "set_grub_default: GRUB file does not exist: ${grub_file}"
        return 1
    fi

    log_debug "Setting GRUB_DEFAULT to '${default_value}' in ${grub_file}"

    # Check if GRUB_DEFAULT line exists
    if grep -q "^GRUB_DEFAULT=" "${grub_file}"; then
        # Replace existing line
        if sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"${default_value}\"/" "${grub_file}"; then
            log_debug "Updated existing GRUB_DEFAULT to '${default_value}'"
            return 0
        else
            log_error "Failed to update GRUB_DEFAULT in ${grub_file}"
            return 1
        fi
    else
        # Add new line after GRUB_TIMEOUT if it exists, otherwise at end
        if grep -q "^GRUB_TIMEOUT=" "${grub_file}"; then
            if sed -i "/^GRUB_TIMEOUT=/a GRUB_DEFAULT=\"${default_value}\"" "${grub_file}"; then
                log_debug "Added GRUB_DEFAULT='${default_value}' after GRUB_TIMEOUT"
                return 0
            else
                log_error "Failed to add GRUB_DEFAULT after GRUB_TIMEOUT"
                return 1
            fi
        else
            # Add at end of file
            if echo "GRUB_DEFAULT=\"${default_value}\"" >> "${grub_file}"; then
                log_debug "Added GRUB_DEFAULT='${default_value}' at end of file"
                return 0
            else
                log_error "Failed to add GRUB_DEFAULT to ${grub_file}"
                return 1
            fi
        fi
    fi
}

# ============================================================================
# MAIN FUNCTIONS
# ============================================================================

# Usage information with improved formatting
usage() {
    echo -e "${BOLD}Ubuntu 24.04 ZFS Mirror Root Installer v${VERSION}${NC}"
    echo ""
    echo -e "${BOLD}Enhanced version with production fixes${NC}"
    echo -e "Original: ${ORIGINAL_REPO}"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo "  ${SCRIPT_NAME} [--prepare] [--timezone=TIMEZONE] <hostname> <disk1> <disk2>"
    echo "  ${SCRIPT_NAME} --wipe-only <disk1> <disk2>"
    echo ""
    echo -e "${BOLD}Description:${NC}"
    echo "  Creates a ZFS root mirror on two drives for Ubuntu 24.04 Server."
    echo "  Both drives will be bootable with automatic failover capability."
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --prepare              Wipe drives completely before installation (recommended)"
    echo "  --timezone=TIMEZONE    Set timezone (e.g., --timezone=America/New_York) to skip prompt"
    echo "                         Valid timezones: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"
    echo "  --wipe-only           Just wipe drives without installing"
    echo ""
    echo -e "${BOLD}Arguments:${NC}"
    echo "  hostname    Hostname for the new system (not needed for --wipe-only)"
    echo "  disk1       First drive (use /dev/disk/by-id/ path)"
    echo "  disk2       Second drive (use /dev/disk/by-id/ path)"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  ${SCRIPT_NAME} myserver \\"
    echo "      /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_EXAMPLE1234567 \\"
    echo "      /dev/disk/by-id/nvme-WD_BLACK_SN850X_1TB_EXAMPLE7654321"
    echo ""
    echo -e "${BOLD}Find your drives:${NC}"
    echo "  ls -la /dev/disk/by-id/ | grep -v part"
    echo ""
    echo -e "${BOLD}Requirements:${NC}"
    echo "  - Ubuntu 24.04 Live USB environment"
    echo "  - Two drives of similar size (±10% tolerance)"
    echo "  - Root privileges"
    echo "  - UEFI boot mode"
    echo ""
    echo -e "${BOLD}Safety:${NC}"
    echo -e "  ${RED}${BOLD}This script will DESTROY ALL DATA on the specified drives!${NC}"
    echo ""
    exit 1
}

# Wipe drives completely with enhanced validation
wipe_drives_completely() {
    local disk1="$1"
    local disk2="$2"
    
    # Validate inputs
    if [[ -z "${disk1}" || -z "${disk2}" ]]; then
        log_error "wipe_drives_completely: Both disk arguments required"
        return 1
    fi
    
    log_header "Drive Wipe Utility"
    
    log_warning "This will COMPLETELY DESTROY ALL DATA on:"
    echo -e "${RED}  - ${disk1}${NC}"
    echo -e "${RED}  - ${disk2}${NC}"
    echo ""
    echo -e "${YELLOW}This operation cannot be undone!${NC}"
    echo ""
    echo -e "${BOLD}Type 'DESTROY' to confirm: ${NC}"
    read -r confirmation
    
    if [[ "${confirmation}" != "DESTROY" ]]; then
        log_info "Wipe cancelled by user"
        exit 0
    fi
    
    log_info "Starting drive wipe process..."
    
    # Stop all services first
    stop_disk_services "${disk1}"
    stop_disk_services "${disk2}"
    
    # Destroy existing ZFS pools
    destroy_all_pools
    
    # Perform secure wipe on both drives
    if ! secure_wipe_drive "${disk1}" "quick"; then
        log_error "Failed to wipe ${disk1}"
        exit 1
    fi
    
    if ! secure_wipe_drive "${disk2}" "quick"; then
        log_error "Failed to wipe ${disk2}"
        exit 1
    fi
    
    log_info "Drives wiped successfully"
    exit 0
}

# Validate disk device with comprehensive checks
validate_disk_device() {
    local disk="$1"
    
    if [[ -z "${disk}" ]]; then
        log_error "validate_disk_device: No disk specified"
        return 1
    fi
    
    local disk_basename
    disk_basename=$(basename "${disk}")
    
    log_debug "Validating disk device: ${disk}" >&2
    
    # Check if device exists
    if [[ ! -b "${disk}" ]]; then
        log_error "Device ${disk} does not exist or is not a block device"
        return 1
    fi
    
    # Check if this is a partition using improved pattern matching
    if [[ "${disk}" =~ -part[0-9]+$ ]] || \
       [[ "${disk}" =~ p[0-9]+$ ]] || \
       [[ "${disk_basename}" =~ ^sd[a-z]+[0-9]+$ ]] || \
       [[ "${disk_basename}" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]] || \
       [[ "${disk_basename}" =~ ^vd[a-z]+[0-9]+$ ]]; then
        log_error "Device ${disk} appears to be a partition, not a whole disk"
        return 1
    fi
    
    # Verify it's a disk using lsblk with better error handling
    if command -v lsblk &>/dev/null; then
        local device_type
        device_type=$(lsblk -ndo TYPE "${disk}" 2>/dev/null | head -1 || echo "unknown")
        if [[ "${device_type}" != "disk" ]]; then
            log_error "Device ${disk} is type '${device_type}', not a disk"
            return 1
        fi
    fi
    
    log_debug "Device ${disk} validated successfully as a whole disk" >&2
    return 0
}

# Check prerequisites with enhanced validation
check_prerequisites() {
    local missing_tools=()
    
    log_info "Checking prerequisites..."
    
    # Check for required commands
    for tool in sgdisk mkdosfs zpool zfs debootstrap partprobe wipefs efibootmgr; do
        if ! command -v "${tool}" &> /dev/null; then
            missing_tools+=("${tool}")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_warning "Missing required tools: ${missing_tools[*]}"
        log_info "Installing missing prerequisites..."
                
        # Update and install required packages
        if ! apt-get update; then
            log_error "Failed to update package lists"
            return 1
        fi
        
        if ! apt-get install -y debootstrap gdisk zfsutils-linux dosfstools openssh-server efibootmgr; then
            log_error "Failed to install required packages"
            return 1
        fi
                
        log_info "All required tools installed successfully"
    fi
    
    log_info "All prerequisites satisfied"
    return 0
}

# Get drive size in bytes with enhanced error handling
get_drive_size() {
    local drive="$1"
    
    if [[ -z "${drive}" ]]; then
        log_error "get_drive_size: No drive specified" >&2
        return 1
    fi
    
    if [[ ! -b "${drive}" ]]; then
        log_error "get_drive_size: ${drive} is not a block device" >&2
        return 1
    fi
    
    local size
    size=$(blockdev --getsize64 "${drive}" 2>/dev/null || echo "0")
        
    if [[ "${size}" == "0" ]]; then
        log_error "Could not determine size for ${drive}" >&2
        return 1
    fi
        
    log_debug "Drive ${drive} size: ${size} bytes" >&2
    echo "${size}"
    return 0
}

# Detect disk type with improved detection and validation
detect_disk_type() {
    local disk="$1"
    
    if [[ -z "${disk}" ]]; then
        log_error "detect_disk_type: No disk specified" >&2
        return 1
    fi
    
    local disk_path
    local disk_name
    disk_path=$(readlink -f "${disk}" 2>/dev/null || echo "${disk}")
    disk_name=$(basename "${disk_path}")
    
    log_debug "Detecting disk type for: ${disk} (${disk_path})" >&2
    
    # Check for NVMe first
    if [[ "${disk}" =~ nvme ]] || [[ "${disk_path}" =~ nvme ]]; then
        log_debug "Detected NVMe drive" >&2
        echo "nvme"
        return 0
    fi
    
    # Check rotational status in sysfs
    local rotational="/sys/block/${disk_name}/queue/rotational"
    if [[ -f "${rotational}" ]]; then
        local is_rotational
        is_rotational=$(cat "${rotational}" 2>/dev/null || echo "1")
        if [[ "${is_rotational}" == "0" ]]; then
            log_debug "Detected SSD drive (non-rotational)" >&2
            echo "ssd"
        else
            log_debug "Detected HDD drive (rotational)" >&2
            echo "hdd"
        fi
    else
        log_debug "Cannot determine rotation status, defaulting to SSD" >&2
        echo "ssd"  # Default to SSD if unknown
    fi
    
    return 0
}

# Get partition naming with improved handling and validation
get_partition_name() {
    local disk="$1"
    local part_num="$2"
    
    if [[ -z "${disk}" || -z "${part_num}" ]]; then
        log_error "get_partition_name: Disk and partition number required" >&2
        return 1
    fi
    
    if ! [[ "${part_num}" =~ ^[1-9]$ ]]; then
        log_error "get_partition_name: Invalid partition number: ${part_num}" >&2
        return 1
    fi
    
    log_debug "Getting partition name for disk ${disk}, partition ${part_num}" >&2
    
    # For /dev/disk/by-id/ paths (most reliable)
    if [[ "${disk}" =~ ^/dev/disk/by- ]]; then
        echo "${disk}-part${part_num}"
        return 0
    fi
    
    # For direct device names
    if [[ "${disk}" =~ nvme[0-9]+n[0-9]+ ]]; then
        echo "${disk}p${part_num}"
    elif [[ "${disk}" =~ [sv]d[a-z]+$ ]] || [[ "${disk}" =~ vd[a-z]+$ ]]; then
        echo "${disk}${part_num}"
    else
        # Fallback to -part naming
        echo "${disk}-part${part_num}"
    fi
    
    return 0
}

# Interactive swap size configuration with smart default
prompt_swap_size() {
    local ram_gb swap_input result
    ram_gb=$(free --giga | awk '/^Mem:/ {print $2}')

    echo "=== Swap Partition Configuration ===" >&2
    echo "System RAM: ${ram_gb}GB" >&2
    echo "Recommended for headless servers: 8GB (provides emergency buffer without hibernation overhead)" >&2
    echo "" >&2
    echo -n "Swap size in GB [8]: " >&2
    read -r swap_input

    # Use default if empty, validate if provided
    if [[ -z "${swap_input}" ]]; then
        result="8G"
    elif [[ "${swap_input}" =~ ^[0-9]+$ ]] && [[ "${swap_input}" -gt 0 ]] && [[ "${swap_input}" -le 512 ]]; then
        result="${swap_input}G"
    else
        log_warning "Invalid swap size '${swap_input}'. Using default 8GB."
        result="8G"
    fi

    echo "${result}"
}

# Interactive timezone configuration using built-in tzselect
prompt_timezone() {
    local timezone_choice

    echo "=== Timezone Configuration ===" >&2
    echo "Please select your timezone to prevent interactive prompts during installation." >&2
    echo "Using tzselect - follow the prompts to select your timezone:" >&2
    echo "" >&2

    timezone_choice=$(tzselect)

    # Validate the selection
    if [[ -n "${timezone_choice}" ]] && [[ -f "/usr/share/zoneinfo/${timezone_choice}" ]]; then
        echo "${timezone_choice}"
    else
        log_warning "Invalid timezone selection. Using UTC as fallback."
        echo "UTC"
    fi
}

# Interactive additional dataset creation
prompt_additional_datasets() {
    local create_additional datasets custom_name custom_mount choice

    echo "=== Optional ZFS Datasets ===" >&2
    echo "The following datasets will be created by default:" >&2
    echo "  • rpool/root     → / (includes /boot)" >&2
    echo "  • rpool/var      → /var" >&2
    echo "  • rpool/var/log  → /var/log" >&2
    echo "" >&2
    echo -n "Would you like to create additional datasets? [y/N]: " >&2
    read -r create_additional

    if [[ "${create_additional,,}" != "y" ]]; then
        echo ""  # Return empty string for no additional datasets
        return
    fi

    echo "" >&2
    echo "Common additional datasets:" >&2
    echo "1) rpool/home        → /home (separate home directories)" >&2
    echo "2) rpool/opt         → /opt (third-party software)" >&2
    echo "3) rpool/srv         → /srv (service data)" >&2
    echo "4) rpool/tmp         → /tmp (temporary files on ZFS)" >&2
    echo "5) rpool/usr/local   → /usr/local (local installations)" >&2
    echo "6) Custom dataset" >&2
    echo "0) Done" >&2
    echo "" >&2

    datasets=""
    while true; do
        echo -n "Select datasets (1-6, 0 when done): " >&2
        read -r choice

        case $choice in
            1) datasets="${datasets}rpool/home:/home " ;;
            2) datasets="${datasets}rpool/opt:/opt " ;;
            3) datasets="${datasets}rpool/srv:/srv " ;;
            4) datasets="${datasets}rpool/tmp:/tmp " ;;
            5) datasets="${datasets}rpool/usr/local:/usr/local " ;;
            6)
                echo -n "Enter dataset name (e.g., rpool/data): " >&2
                read -r custom_name
                echo -n "Enter mount point (e.g., /data): " >&2
                read -r custom_mount
                if [[ -n "${custom_name}" && -n "${custom_mount}" ]]; then
                    datasets="${datasets}${custom_name}:${custom_mount} "
                fi
                ;;
            0) break ;;
            *) echo "Invalid choice. Please select 1-6 or 0." >&2 ;;
        esac
    done

    echo "${datasets% }"  # Remove trailing space
}

# Partition a disk with improved error handling and validation
partition_disk() {
    local disk="$1"
    local disk_type="$2"
    local swap_size="$3"

    if [[ -z "${disk}" || -z "${disk_type}" || -z "${swap_size}" ]]; then
        log_error "partition_disk: Disk, disk type, and swap size required"
        return 1
    fi

    log_info "Partitioning ${disk_type} disk: ${disk}"

    # Stop services and clear existing data
    stop_disk_services "${disk}"
    clear_zfs_labels "${disk}"

    # Wipe filesystem signatures
    log_debug "Wiping filesystem signatures on ${disk}"
    wipefs -a "${disk}" 2>/dev/null || true

    # Define partition sizes (3-partition layout)
    local efi_size="1G"  # Increased from 512M for better compatibility

    log_debug "Creating 3-partition layout on ${disk}:"
    log_debug "  Partition 1 (EFI): ${efi_size}"
    log_debug "  Partition 2 (Swap): ${swap_size}"
    log_debug "  Partition 3 (ZFS Root): Remaining space"

    # Create all partitions in one sgdisk call (3-partition layout)
    if ! sgdisk --zap-all "${disk}" \
           --new=1:1M:+${efi_size} --typecode=1:EF00 --change-name=1:"EFI System" \
           --new=2:0:+${swap_size} --typecode=2:8200 --change-name=2:"Linux Swap" \
           --new=3:0:0 --typecode=3:BF00 --change-name=3:"ZFS Root Pool" \
           "${disk}"; then
        log_error "Failed to create partitions on ${disk}"
        return 1
    fi

    # Inform kernel of changes
    log_debug "Informing kernel of partition table changes"
    partprobe "${disk}" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    # Wait for devices to settle based on disk type
    if [[ "${disk_type}" == "hdd" ]]; then
        log_debug "Waiting 5 seconds for HDD to settle"
        sleep 5
    else
        log_debug "Waiting 2 seconds for SSD/NVMe to settle"
        sleep 2
    fi

    # Verify partitions were created (3 partitions)
    local part1 part2 part3
    part1=$(get_partition_name "${disk}" 1)
    part2=$(get_partition_name "${disk}" 2)
    part3=$(get_partition_name "${disk}" 3)

    for part in "${part1}" "${part2}" "${part3}"; do
        if [[ ! -b "${part}" ]]; then
            log_error "Partition ${part} was not created successfully"
            return 1
        fi
    done

    log_info "Successfully partitioned ${disk} with 3-partition layout"
    return 0
}

# Console and system configuration with enhanced validation
configure_system_preferences() {
    log_header "System Configuration Preferences"
        
    # Detect if we're likely in a headless environment
    local is_headless=false
    if [[ ! -d /sys/class/graphics/fb0 ]] && [[ ! -f /dev/fb0 ]]; then
        is_headless=true
        log_info "No framebuffer detected - likely headless/server environment"
    fi
        
    # Ask user about console preferences
    if [[ "${is_headless}" == "true" ]]; then
        echo -e "${YELLOW}Headless environment detected.${NC}"
        echo -en "${BOLD}Configure serial console for remote management? (Y/n): ${NC}"
        read -r response
        if [[ ! "${response}" =~ ^[Nn]$ ]]; then
            USE_SERIAL_CONSOLE=true
        else
            USE_SERIAL_CONSOLE=false
        fi
    else
        echo -en "${BOLD}Configure serial console for server management? (y/N): ${NC}"
        read -r response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            USE_SERIAL_CONSOLE=true
        else
            USE_SERIAL_CONSOLE=false
        fi
    fi
        
    # Get serial port settings if needed
    if [[ "${USE_SERIAL_CONSOLE}" == "true" ]]; then
        echo -en "${BOLD}Serial port (default: ttyS1): ${NC}"
        read -r SERIAL_PORT
        [[ -z "${SERIAL_PORT}" ]] && SERIAL_PORT="ttyS1"
                
        echo -en "${BOLD}Baud rate (default: 115200): ${NC}"
        read -r SERIAL_SPEED
        [[ -z "${SERIAL_SPEED}" ]] && SERIAL_SPEED="115200"
                
        # Convert ttyS0 to unit 0, ttyS1 to unit 1, etc.
        if [[ "${SERIAL_PORT}" =~ ^ttyS([0-9]+)$ ]]; then
            SERIAL_UNIT="${BASH_REMATCH[1]}"
        else
            SERIAL_UNIT="1"  # Default fallback
            log_warning "Non-standard serial port name, using unit 1"
        fi
                
        log_info "Serial console will be configured:"
        log_info "  Port: ${SERIAL_PORT}"
        log_info "  Speed: ${SERIAL_SPEED}"
        log_info "  GRUB unit: ${SERIAL_UNIT}"
    else
        log_info "Local console only - no serial configuration"
    fi
        
    # Ask about AppArmor
    echo ""
    echo -e "${BOLD}Security Configuration:${NC}"
    echo -e "AppArmor provides mandatory access control (MAC) security."
    echo -e "Ubuntu has it ${GREEN}enabled by default${NC} for enhanced security."
    echo -e "Some environments disable it for compatibility or performance reasons."
    echo -en "${BOLD}Keep AppArmor enabled? (Y/n): ${NC}"
    read -r response
    if [[ "${response}" =~ ^[Nn]$ ]]; then
        USE_APPARMOR=false
        log_info "AppArmor will be disabled for maximum compatibility"
    else
        USE_APPARMOR=true
        log_info "AppArmor will remain enabled (Ubuntu default)"
    fi

    # Ask about performance tunables
    echo ""
    echo -e "${BOLD}Performance Configuration:${NC}"
    echo -e "Performance tunables can optimize the system for server workloads."
    echo -e "These include settings for swap behavior, network optimization, and ZFS."
    echo -e "Recommended for server environments, optional for desktop use."
    echo -en "${BOLD}Apply performance tunables? (Y/n): ${NC}"
    read -r response
    if [[ "${response}" =~ ^[Nn]$ ]]; then
        USE_PERFORMANCE_TUNABLES=false
        log_info "Using Ubuntu default system tunable values"
    else
        USE_PERFORMANCE_TUNABLES=true
        log_info "Performance tunables will be applied"
    fi
        
    export USE_SERIAL_CONSOLE SERIAL_PORT SERIAL_SPEED SERIAL_UNIT USE_APPARMOR USE_PERFORMANCE_TUNABLES
    return 0
}

# Create admin user with enhanced validation
create_admin_user() {
    log_header "Creating Administrative User"
    
    # Get username with validation
    while true; do
        echo -en "${BOLD}Enter username for admin account: ${NC}"
        read -r ADMIN_USER
                
        # Validate username format
        if [[ -z "${ADMIN_USER}" ]]; then
            log_error "Username cannot be empty"
            continue
        fi
        
        if [[ "${ADMIN_USER}" =~ ^[a-z][-a-z0-9_]*$ ]] && [[ ${#ADMIN_USER} -ge 2 ]] && [[ ${#ADMIN_USER} -le 32 ]]; then
            break
        else
            log_error "Invalid username format. Must be 2-32 chars, start with letter, lowercase only."
        fi
    done
    
    # Get password with validation
    while true; do
        echo -en "${BOLD}Enter password for ${ADMIN_USER}: ${NC}"
        read -rs ADMIN_PASS
        echo ""
                
        if [[ ${#ADMIN_PASS} -lt 8 ]]; then
            log_error "Password must be at least 8 characters"
            continue
        fi
                
        echo -en "${BOLD}Confirm password: ${NC}"
        read -rs ADMIN_PASS_CONFIRM
        echo ""
                
        if [[ "${ADMIN_PASS}" == "${ADMIN_PASS_CONFIRM}" ]]; then
            break
        else
            log_error "Passwords don't match"
        fi
    done
    
    # Optional SSH key with validation
    echo -en "${BOLD}Add an SSH public key? (y/N): ${NC}"
    read -r response
    
    if [[ "${response}" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Paste your SSH public key:${NC}"
        read -r SSH_KEY
        if [[ -n "${SSH_KEY}" ]] && [[ "${SSH_KEY}" =~ ^ssh- ]]; then
            USE_SSH_KEY=true
            log_info "SSH key accepted"
        else
            log_warning "Invalid SSH key format, skipping"
            USE_SSH_KEY=false
            SSH_KEY=""
        fi
    else
        USE_SSH_KEY=false
        SSH_KEY=""
    fi
    
    export ADMIN_USER ADMIN_PASS SSH_KEY USE_SSH_KEY
    log_info "Admin user configuration complete: ${ADMIN_USER}"
    return 0
}

# Enhanced pre-destruction analysis with risk-based confirmations
perform_pre_destruction_analysis() {
    echo ""
    log_warning "⚠️  PRE-DESTRUCTION ANALYSIS ⚠️"
    echo ""
    
    # Check if we're running from a ZFS root that we're trying to destroy
    local current_root
    current_root=$(findmnt -n -o SOURCE / 2>/dev/null || echo "unknown")
    if [[ "${current_root}" =~ ^rpool ]]; then
        log_error "CRITICAL: You appear to be running from a ZFS root system!"
        log_error "The installer cannot destroy pools that are currently in use as root."
        log_error "Please boot from a Live USB to run this installer."
        exit 1
    fi
    
    # Analyze what's currently on the drives
    local has_zfs_pools=false
    local has_mounted_fs=false
    local has_partitions=false
    local has_boot_signatures=false
    
    log_info "Analyzing current drive contents..."
    
    for disk in "${DISK1}" "${DISK2}"; do
        echo ""
        # Display disk with appropriate name
        if [[ "${disk}" == "${DISK1}" ]]; then
            echo -e "${BOLD}${disk} (${DISK1_NAME}):${NC}"
        else
            echo -e "${BOLD}${disk} (${DISK2_NAME}):${NC}"
        fi
                
        # Check for ZFS pools
        local disk_basename
        disk_basename=$(basename "$(readlink -f "${disk}" 2>/dev/null || echo "${disk}")")
        if zpool status 2>/dev/null | grep -q "${disk_basename}\|$(basename "${disk}")"; then
            echo -e "${RED}  ⚠ Contains active ZFS pool(s)${NC}"
            zpool status 2>/dev/null | grep -A3 -B1 "${disk_basename}\|$(basename "${disk}")" | head -5 | sed 's/^/    /'
            has_zfs_pools=true
        fi
                
        # Check for mounted filesystems
        if mount | grep -q "${disk}"; then
            echo -e "${RED}  ⚠ Has mounted filesystem(s)${NC}"
            mount | grep "${disk}" | while IFS= read -r line; do
                echo -e "    ${YELLOW}${line}${NC}"
            done
            has_mounted_fs=true
        fi
                
        # Check for partition table and partitions
        local part_info
        part_info=$(lsblk -n "${disk}" 2>/dev/null | tail -n +2 || echo "")
        if [[ -n "${part_info}" ]]; then
            local part_count
            part_count=$(echo "${part_info}" | wc -l)
            echo -e "${YELLOW}  • Contains partition table with ${part_count} partition(s)${NC}"
            echo "${part_info}" | head -5 | sed 's/^/    /'
            has_partitions=true
                        
            # Check for boot/EFI signatures
            while IFS= read -r part_line; do
                if [[ -z "${part_line}" ]]; then continue; fi
                local part_dev
                part_dev=$(echo "${part_line}" | awk '{print $1}' | sed 's/[├└─]//g' | xargs)
                if [[ -n "${part_dev}" ]]; then
                    local full_part="/dev/${part_dev}"
                    if [[ -b "${full_part}" ]]; then
                        local fs_type
                        fs_type=$(blkid -o value -s TYPE "${full_part}" 2>/dev/null || echo "")
                        if [[ "${fs_type}" == "vfat" ]]; then
                            echo -e "    ${YELLOW}→ EFI boot partition detected${NC}"
                            has_boot_signatures=true
                        elif [[ "${fs_type}" =~ ^ext[234]$ ]]; then
                            echo -e "    ${YELLOW}→ Linux filesystem detected${NC}"
                        fi
                    fi
                fi
            done <<< "${part_info}"
        else
            echo -e "${GREEN}  ✓ Clean - no existing partitions${NC}"
        fi
                
        # Check for any filesystem signatures
        local signatures
        signatures=$(wipefs -n "${disk}" 2>/dev/null || true)
        if [[ -n "${signatures}" ]] && [[ "${signatures}" != *"no known filesystems"* ]]; then
            echo -e "${YELLOW}  • Filesystem signatures detected${NC}"
        fi
    done
    
    echo ""
    
    # Risk-based confirmation
    if [[ "${has_zfs_pools}" == "true" ]]; then
        echo -e "${RED}${BOLD}🚨 CRITICAL: ACTIVE ZFS POOLS DETECTED! 🚨${NC}"
        echo -e "${RED}This system appears to have a functioning ZFS installation.${NC}"
        echo -e "${RED}All pools and data will be permanently destroyed.${NC}"
        echo ""
        echo -e "${BOLD}Final confirmation required:${NC}"
        echo -e "${BOLD}Type 'DESTROY-EXISTING-DATA' to confirm: ${NC}"
        read -r confirmation
        if [[ "${confirmation}" != "DESTROY-EXISTING-DATA" ]]; then
            log_info "Installation cancelled - ZFS pools preserved"
            exit 0
        fi
                
        echo -en "${BOLD}Type the target hostname '${HOSTNAME}' to double-confirm: ${NC}"
        read -r hostname_confirm
        if [[ "${hostname_confirm}" != "${HOSTNAME}" ]]; then
            log_info "Installation cancelled - hostname mismatch"
            exit 0
        fi
            
    elif [[ "${has_mounted_fs}" == "true" ]] || [[ "${has_boot_signatures}" == "true" ]]; then
        echo -e "${RED}${BOLD}⚠ CAUTION: BOOTABLE SYSTEM OR MOUNTED FILESYSTEMS DETECTED ⚠${NC}"
        echo -e "${RED}This appears to be a system drive with active data.${NC}"
        echo -e "${RED}All data will be permanently destroyed.${NC}"
        echo ""
        echo -e "${BOLD}Type 'DESTROY' to confirm data destruction: ${NC}"
        read -r confirmation
        if [[ "${confirmation}" != "DESTROY" ]]; then
            log_info "Installation cancelled by user"
            exit 0
        fi
            
    elif [[ "${has_partitions}" == "true" ]]; then
        echo -e "${YELLOW}${BOLD}Existing partitions detected but no active filesystems.${NC}"
        echo -e "${YELLOW}All partitions and data will be permanently destroyed.${NC}"
        echo ""
        echo -en "${BOLD}Type 'yes' to proceed: ${NC}"
        read -r confirmation
        if [[ "${confirmation}" != "yes" ]]; then
            log_info "Installation cancelled by user"
            exit 0
        fi
            
    else
        echo -e "${GREEN}${BOLD}✓ Drives appear clean - no active systems detected.${NC}"
        echo ""
        echo -en "${BOLD}Type 'yes' to proceed with installation: ${NC}"
        read -r confirmation
        if [[ "${confirmation}" != "yes" ]]; then
            log_info "Installation cancelled by user"
            exit 0
        fi
    fi
    
    echo ""
    log_info "User confirmation received - proceeding with data destruction"
    return 0
}

# Create ZFS configuration
setup_zfs_config() {
    log_header "Creating ZFS Configuration"
    log_info "ZFS configuration setup for reliable pool imports"

    # Create ZFS defaults file (will be updated with force import option later)
    cat > /mnt/etc/default/zfs << ZFS_DEFAULTS_EOF
# ZFS Configuration for Ubuntu ZFS Mirror Installation
# Default configuration for ZFS pool imports
ZFS_DEFAULTS_EOF

    log_info "ZFS configuration created"
    log_info "Force import configuration will be set up for first boot"
    return 0
}

# Create simplified EFI sync script
create_efi_sync_script() {
    cat << 'EFI_SYNC_SCRIPT' > /mnt/usr/local/bin/sync-efi-partitions
#!/bin/bash
# EFI Partition Sync Script for ZFS Mirror Drives
#
# CREATED BY: Ubuntu ZFS Mirror Root Installation Script (v${VERSION})
# PURPOSE: Sync EFI bootloader files between mirror drives for redundancy
# LOCATION: /usr/local/bin/sync-efi-partitions
#
# DESIGN PHILOSOPHY:
# - Each drive has its own EFI partition with its own drive-specific folder
# - Only ONE EFI partition is mounted at /boot/efi (whichever drive booted)
# - When GRUB/kernel updates happen, they only write to the mounted partition
# - This script syncs the FILE CONTENTS between drive-specific folders
# - Each folder keeps its own name but contains identical bootloader files
#
# EXAMPLE:
#   Booted from Drive 1 (Samsung):
#   - /boot/efi/EFI/Ubuntu-Samsung-SSD-990-363M/ (mounted, updated by system)
#   - Sync files → Drive 2: /EFI/Ubuntu-CT1000T500SSD8-5ADF/ (unmounted)
#
# RECOVERY:
#   If Drive 1 fails, UEFI boots from Drive 2's folder, which has the same
#   bootloader files. The grub.cfg just searches for ZFS UUID, so it works
#   regardless of which drive booted.
#
set -euo pipefail

log_message() {
    logger -t "efi-sync" "$*" 2>/dev/null || true
    echo "$(date '+%F %T') [efi-sync] $*"
}

# Get EFI UUID from fstab
EFI_UUID=$(awk '/\/boot\/efi/ && /^UUID=/ {gsub(/UUID=/, "", $1); print $1}' /etc/fstab 2>/dev/null || echo "")

if [[ -z "${EFI_UUID}" ]]; then
    log_message "ERROR: Could not find EFI UUID in fstab"
    exit 1
fi

# Get the currently mounted EFI partition (this is our source)
MOUNTED_EFI=$(mount | grep '/boot/efi' | awk '{print $1}')

if [[ -z "${MOUNTED_EFI}" ]]; then
    log_message "ERROR: No EFI partition currently mounted at /boot/efi"
    exit 1
fi

# Find all partitions with this UUID
mapfile -t EFI_PARTITIONS < <(blkid --output device --match-token UUID="${EFI_UUID}" 2>/dev/null || true)

if [[ ${#EFI_PARTITIONS[@]} -lt 2 ]]; then
    log_message "WARNING: Only ${#EFI_PARTITIONS[@]} EFI partition(s) found, expected 2+"
    exit 0
fi

# Find source Ubuntu folder on mounted partition
SOURCE_UBUNTU_FOLDER=$(find /boot/efi/EFI/ -maxdepth 1 -name "Ubuntu-*" -type d 2>/dev/null | head -1)
if [[ -z "${SOURCE_UBUNTU_FOLDER}" ]]; then
    log_message "ERROR: No Ubuntu-* folder found in mounted EFI partition"
    exit 1
fi

SOURCE_FOLDER_NAME=$(basename "${SOURCE_UBUNTU_FOLDER}")
log_message "Source folder: ${SOURCE_FOLDER_NAME} (from ${MOUNTED_EFI})"

# Sync to each unmounted EFI partition
SYNC_COUNT=0
for partition in "${EFI_PARTITIONS[@]}"; do
    if [[ "${partition}" == "${MOUNTED_EFI}" ]]; then
        continue
    fi

    log_message "Syncing to ${partition}..."

    TARGET_MOUNT=$(mktemp -d)

    if ! mount "${partition}" "${TARGET_MOUNT}"; then
        log_message "  ERROR: Failed to mount ${partition}"
        rmdir "${TARGET_MOUNT}"
        continue
    fi

    # Find the Ubuntu folder on this target partition (should have different name)
    TARGET_UBUNTU_FOLDER=$(find "${TARGET_MOUNT}/EFI/" -maxdepth 1 -name "Ubuntu-*" -type d 2>/dev/null | head -1)

    if [[ -z "${TARGET_UBUNTU_FOLDER}" ]]; then
        log_message "  WARNING: No Ubuntu-* folder found on ${partition}, skipping"
        umount "${TARGET_MOUNT}"
        rmdir "${TARGET_MOUNT}"
        continue
    fi

    TARGET_FOLDER_NAME=$(basename "${TARGET_UBUNTU_FOLDER}")
    log_message "  Target folder: ${TARGET_FOLDER_NAME}"

    # Sync bootloader files (shimx64.efi, grubx64.efi, grub.cfg, etc.)
    if rsync -av --delete "${SOURCE_UBUNTU_FOLDER}/" "${TARGET_UBUNTU_FOLDER}/" >/dev/null 2>&1; then
        log_message "  ✓ Files synced: ${SOURCE_FOLDER_NAME} → ${TARGET_FOLDER_NAME}"
        ((SYNC_COUNT++))
    else
        log_message "  ERROR: Failed to sync files to ${TARGET_FOLDER_NAME}"
    fi

    # Also sync /EFI/BOOT/ fallback bootloader
    if [[ -d /boot/efi/EFI/BOOT ]]; then
        mkdir -p "${TARGET_MOUNT}/EFI/BOOT"
        if rsync -av --delete /boot/efi/EFI/BOOT/ "${TARGET_MOUNT}/EFI/BOOT/" >/dev/null 2>&1; then
            log_message "  ✓ /EFI/BOOT/ fallback synced"
        fi
    fi

    umount "${TARGET_MOUNT}"
    rmdir "${TARGET_MOUNT}"
done

if [[ ${SYNC_COUNT} -eq 0 ]]; then
    log_message "WARNING: No partitions were synced"
    exit 1
fi

log_message "EFI sync completed successfully (${SYNC_COUNT} partition(s) synced)"
EFI_SYNC_SCRIPT

    chmod +x /mnt/usr/local/bin/sync-efi-partitions
    log_info "EFI sync script created"
    return 0
}

# Create single ZFS pool with GRUB2 compatibility and SSD optimization
# Single pool design eliminates dual-pool complexity and Ubuntu 24.04 systemd issues
create_zfs_pool() {
    local part1_root="$1"
    local part2_root="$2"
    local ashift="$3"
    local trim_enabled="$4"

    # Validate inputs
    local required_args=("$part1_root" "$part2_root" "$ashift" "$trim_enabled")
    for arg in "${required_args[@]}"; do
        if [[ -z "${arg}" ]]; then
            log_error "create_zfs_pool: Missing required argument"
            return 1
        fi
    done

    log_info "Creating ZFS root pool with ashift=${ashift}, autotrim=${trim_enabled}"

    # Build ZFS options dynamically for single pool with GRUB2 compatibility
    local pool_opts="-f -o ashift=${ashift}"
    [[ "${trim_enabled}" == "on" ]] && pool_opts="${pool_opts} -o autotrim=on"

    # Create single root pool with GRUB2 compatibility and SSD optimization
    log_info "Creating mirrored root pool (rpool) with GRUB2 compatibility..."
    # Note: Using 'eval' here safely because all variables are controlled
    if ! eval "zpool create ${pool_opts} -o compatibility=grub2 -O devices=off -O acltype=posixacl -O xattr=sa -O atime=off -O normalization=formD -O canmount=off -O mountpoint=/ -R /mnt rpool mirror '${part1_root}' '${part2_root}'"; then
        log_error "Failed to create root pool"
        return 1
    fi

    # Verify root pool was created
    if ! zpool list rpool &>/dev/null; then
        log_error "Root pool creation appeared to succeed but pool doesn't exist!"
        return 1
    fi

    log_info "Root pool created successfully with GRUB2 compatibility"

    # Configure pool for reliable import (no cache file issues)
    # Ubuntu Bug Reference: https://bugs.launchpad.net/ubuntu/+source/zfs-linux/+bug/1718761
    # Cache files can become corrupted or inconsistent in Ubuntu, causing import failures
    # Using cachefile=none forces scan-based import which is more reliable
    # This works with zfs-import-scan.service in Ubuntu 24.04
    log_info "Configuring pool for reliable import..."
    zpool set cachefile=none rpool
    log_info "Pool configured with cachefile=none for scan-based import (avoids Ubuntu cache file bug)"

    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Parse command-line arguments
if [[ $# -eq 0 ]]; then
    usage
fi

# Check for --prepare option
USE_PREPARE=false
if [[ "$1" == "--prepare" ]]; then
    USE_PREPARE=true
    shift  # Remove --prepare from arguments
fi

# Check for --timezone option
USER_TIMEZONE=""
if [[ "$1" == --timezone=* ]]; then
    USER_TIMEZONE="${1#--timezone=}"
    shift  # Remove --timezone from arguments
fi

# Check for wipe-only mode
if [[ "$1" == "--wipe-only" ]]; then
    if [[ $# -ne 3 ]]; then
        echo -e "${RED}Error: --wipe-only requires exactly 2 disk arguments${NC}"
        usage
    fi
    
    DISK1="$2"
    DISK2="$3"
    
    # Verify running as root
    if [[ ${EUID} -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Validate disks
    for disk in "${DISK1}" "${DISK2}"; do
        if [[ ! -e "${disk}" ]]; then
            log_error "Drive ${disk} not found"
            exit 1
        fi
                
        if ! validate_disk_device "${disk}"; then
            exit 1
        fi
    done
    
    wipe_drives_completely "${DISK1}" "${DISK2}"
fi

# Normal installation mode - validate argument count
if [[ $# -ne 3 ]]; then
    echo -e "${RED}Error: Normal installation requires exactly 3 arguments (hostname, disk1, disk2)${NC}"
    usage
fi

# Parse arguments for normal installation
HOSTNAME="$1"
DISK1="$2"
DISK2="$3"

# Validate hostname
if [[ ! "${HOSTNAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    log_error "Invalid hostname format: ${HOSTNAME}"
    log_error "Hostname must be 1-63 characters, alphanumeric with hyphens (not at start/end)"
    exit 1
fi

# Get drive identifiers with error checking
if ! DISK1_NAME=$(get_drive_identifier "${DISK1}"); then
    log_error "Failed to get identifier for ${DISK1}"
    exit 1
fi

if ! DISK2_NAME=$(get_drive_identifier "${DISK2}"); then
    log_error "Failed to get identifier for ${DISK2}"
    exit 1
fi

log_info "Drive identifiers:"
log_info "  Drive 1: ${DISK1_NAME}"
log_info "  Drive 2: ${DISK2_NAME}"

# Installation state tracking for cleanup
INSTALL_STATE="starting"
POOLS_CREATED=""
MOUNTS_ACTIVE=""
CHROOT_ACTIVE=""

# Cleanup function for proper error handling
cleanup_on_exit() {
    local exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]] && [[ "${INSTALL_STATE}" != "completed" ]]; then
        log_warning "Installation interrupted at state: ${INSTALL_STATE}"

        # Ask user whether to clean up or leave environment for debugging
        if [[ -t 0 ]] && [[ "${POOLS_CREATED}" == "yes" ]]; then
            echo ""
            echo -e "${YELLOW}Installation failed. Choose cleanup option:${NC}"
            echo "1) Clean up and exit (unmount everything)"
            echo "2) Leave environment mounted for debugging"
            read -p "Choice (1/2): " -r cleanup_choice
            case "$cleanup_choice" in
                2)
                    log_info "Leaving environment mounted at /mnt for debugging"
                    log_info "To clean up later run: sudo umount -lR /mnt && sudo zpool export -a"
                    log_info "To remount: sudo zpool import -f rpool && sudo zfs mount -a"
                    echo ""
                    log_error "Installation failed - check log: ${LOG_FILE}"
                    exit ${exit_code}
                    ;;
            esac
        fi

        # Cleanup chroot mounts
        if [[ "${CHROOT_ACTIVE}" == "yes" ]]; then
            log_debug "Cleaning up chroot mounts"
            umount /mnt/dev /mnt/proc /mnt/sys /mnt/run 2>/dev/null || true
        fi

        # Cleanup ZFS pools
        if [[ "${POOLS_CREATED}" == "yes" ]]; then
            log_debug "Cleaning up ZFS pools"
            zpool export -a 2>/dev/null || true
        fi

        # Cleanup temporary mounts
        if [[ "${MOUNTS_ACTIVE}" == "yes" ]]; then
            log_debug "Cleaning up temporary mounts"
            umount -lR /mnt 2>/dev/null || true
        fi

        echo ""
        log_error "Installation failed - check log: ${LOG_FILE}"
    fi
    
    exit ${exit_code}
}

# Set up signal handlers for clean exit
trap cleanup_on_exit EXIT
trap 'log_warning "Received interrupt signal"; exit 130' SIGINT SIGTERM

# Start installation with comprehensive logging
log_header "Ubuntu 24.04 ZFS Mirror Root Installer v${VERSION}"

log_info "Enhanced version with production fixes"
log_info "Original repository: ${ORIGINAL_REPO}"
log_info "Installation started at $(date)"
log_info "Configuration:"
log_info "  Hostname: ${HOSTNAME}"
log_info "  Disk 1: ${DISK1} (${DISK1_NAME})"
log_info "  Disk 2: ${DISK2} (${DISK2_NAME})"
log_info "  Log file: ${LOG_FILE}"
if [[ "${USE_PREPARE}" == "true" ]]; then
    log_info "  Mode: Prepare (will wipe drives before installation)"
fi

# Verify running as root
if [[ ${EUID} -ne 0 ]]; then
    log_error "This script must be run as root (UID 0)"
    exit 1
fi

# Validate inputs and check system readiness
log_info "Validating configuration and system readiness..."
if ! check_prerequisites; then
    exit 1
fi

if ! configure_system_preferences; then
    exit 1
fi

if ! create_admin_user; then
    exit 1
fi

log_header "Validating Drive Configuration"
INSTALL_STATE="validating"

# Verify drives exist and are valid
for disk in "${DISK1}" "${DISK2}"; do
    if [[ ! -e "${disk}" ]]; then
        log_error "Drive ${disk} not found"
        exit 1
    fi
    
    if ! validate_disk_device "${disk}"; then
        exit 1
    fi
    
    log_info "✓ Valid disk: ${disk}"
done

# Detect disk types and log information
if ! DISK1_TYPE=$(detect_disk_type "${DISK1}"); then
    log_error "Failed to detect type for ${DISK1}"
    exit 1
fi

if ! DISK2_TYPE=$(detect_disk_type "${DISK2}"); then
    log_error "Failed to detect type for ${DISK2}"
    exit 1
fi

log_info "Disk types:"
log_info "  Disk 1: ${DISK1_TYPE}"
log_info "  Disk 2: ${DISK2_TYPE}"

# Check and compare disk sizes
if ! DISK1_SIZE=$(get_drive_size "${DISK1}"); then
    log_error "Failed to get size for ${DISK1}"
    exit 1
fi

if ! DISK2_SIZE=$(get_drive_size "${DISK2}"); then
    log_error "Failed to get size for ${DISK2}"
    exit 1
fi

DISK1_SIZE_GB=$((DISK1_SIZE / 1024 / 1024 / 1024))
DISK2_SIZE_GB=$((DISK2_SIZE / 1024 / 1024 / 1024))

log_info "Disk sizes:"
log_info "  Disk 1: ${DISK1_SIZE_GB}GB (${DISK1_SIZE} bytes)"
log_info "  Disk 2: ${DISK2_SIZE_GB}GB (${DISK2_SIZE} bytes)"

# Calculate and validate size difference using floating point for precision
SIZE_DIFF=0
if [[ ${DISK1_SIZE} -gt ${DISK2_SIZE} ]]; then
    SIZE_DIFF=$(( (DISK1_SIZE - DISK2_SIZE) * 100 / DISK1_SIZE ))
else
    SIZE_DIFF=$(( (DISK2_SIZE - DISK1_SIZE) * 100 / DISK2_SIZE ))
fi

if [[ ${SIZE_DIFF} -gt 10 ]]; then
    log_error "Drive size mismatch too large: ${SIZE_DIFF}%"
    exit 1
fi

# Check minimum size requirement (16GB minimum)
MIN_SIZE=$((16 * 1024 * 1024 * 1024))  # 16GB in bytes
if [[ ${DISK1_SIZE} -lt ${MIN_SIZE} ]] || [[ ${DISK2_SIZE} -lt ${MIN_SIZE} ]]; then
    log_error "Drives too small. Minimum size is 16GB"
    exit 1
fi

# Pre-destruction analysis and risk-based confirmation
if ! perform_pre_destruction_analysis; then
    exit 1
fi

# ============================================================================
# CENTRALIZED CONFIGURATION COLLECTION
# ============================================================================
# Collect ALL user configuration before starting any destructive operations
log_header "Configuration Options"

# Get swap size from user
SWAP_SIZE=$(prompt_swap_size)
log_info "Swap size selected: ${SWAP_SIZE}"

# Get timezone from user (or use command-line argument)
if [[ -n "${USER_TIMEZONE}" ]]; then
    # Validate provided timezone
    if [[ -f "/usr/share/zoneinfo/${USER_TIMEZONE}" ]]; then
        TIMEZONE="${USER_TIMEZONE}"
        log_info "Using timezone from command line: ${TIMEZONE}"
    else
        log_warning "Invalid timezone '${USER_TIMEZONE}' provided. Will prompt for selection."
        TIMEZONE=$(prompt_timezone)
        log_info "Timezone selected: ${TIMEZONE}"
    fi
else
    TIMEZONE=$(prompt_timezone)
    log_info "Timezone selected: ${TIMEZONE}"
fi

# Get additional datasets from user
ADDITIONAL_DATASETS=$(prompt_additional_datasets)
if [[ -n "${ADDITIONAL_DATASETS}" ]]; then
    log_info "Additional datasets selected: ${ADDITIONAL_DATASETS}"
else
    log_info "Using default dataset layout only"
fi

log_info "All configuration collected. Installation will proceed non-interactively."
echo ""

# If --prepare was specified, wipe drives first
if [[ "${USE_PREPARE}" == "true" ]]; then
    log_header "Preparing Drives (--prepare mode)"
    log_info "Performing complete wipe of both drives..."

    # Final countdown before destructive operations
    countdown_timer 10 "Drive wipe will begin"

    # Stop all services first
    stop_disk_services "${DISK1}"
    stop_disk_services "${DISK2}"
        
    # Destroy existing ZFS pools
    destroy_all_pools
        
    # Perform secure wipe on both drives
    if ! secure_wipe_drive "${DISK1}" "quick"; then
        log_error "Failed to wipe ${DISK1}"
        exit 1
    fi
    
    if ! secure_wipe_drive "${DISK2}" "quick"; then
        log_error "Failed to wipe ${DISK2}"
        exit 1
    fi
        
    log_info "Drive preparation complete"
fi

# Begin destructive operations
log_header "Preparing Installation Environment"
INSTALL_STATE="preparing"

# Stop potentially interfering services
systemctl stop zed 2>/dev/null || true
swapoff -a 2>/dev/null || true

# Configuration collected earlier - proceeding with installation

log_header "Partitioning Drives"
INSTALL_STATE="partitioning"

show_progress 1 10 "Partitioning drives..."
if ! partition_disk "${DISK1}" "${DISK1_TYPE}" "${SWAP_SIZE}"; then
    log_error "Failed to partition ${DISK1}"
    exit 1
fi

if ! partition_disk "${DISK2}" "${DISK2_TYPE}" "${SWAP_SIZE}"; then
    log_error "Failed to partition ${DISK2}"
    exit 1
fi

log_header "Creating ZFS Pools"
INSTALL_STATE="pools_creating"

# Determine optimal ZFS settings based on drive types
ASHIFT=12  # Default for 4K sectors
TRIM_ENABLED="on"  # Default on for SSDs/NVMe

# Adjust settings for HDDs
if [[ "${DISK1_TYPE}" == "hdd" ]] || [[ "${DISK2_TYPE}" == "hdd" ]]; then
    log_info "HDD detected - adjusting ZFS settings for optimal HDD performance"
        
    # Check actual sector sizes
    SECTOR1=$(blockdev --getpbsz "${DISK1}" 2>/dev/null || echo "4096")
    SECTOR2=$(blockdev --getpbsz "${DISK2}" 2>/dev/null || echo "4096")
    
    # Use ashift=9 for 512 byte sectors
    if [[ "${SECTOR1}" == "512" ]] || [[ "${SECTOR2}" == "512" ]]; then
        ASHIFT=9
    fi
    
    # Disable TRIM for HDDs
    TRIM_ENABLED="off"
fi

log_info "ZFS pool settings:"
log_info "  ashift: ${ASHIFT}"
log_info "  autotrim: ${TRIM_ENABLED}"

# Get partition device paths with error checking
if ! PART1_EFI=$(get_partition_name "${DISK1}" 1); then
    log_error "Failed to get EFI partition name for ${DISK1}"
    exit 1
fi

if ! PART2_EFI=$(get_partition_name "${DISK2}" 1); then
    log_error "Failed to get EFI partition name for ${DISK2}"
    exit 1
fi

if ! PART1_SWAP=$(get_partition_name "${DISK1}" 2); then
    log_error "Failed to get swap partition name for ${DISK1}"
    exit 1
fi

if ! PART2_SWAP=$(get_partition_name "${DISK2}" 2); then
    log_error "Failed to get swap partition name for ${DISK2}"
    exit 1
fi

if ! PART1_ROOT=$(get_partition_name "${DISK1}" 3); then
    log_error "Failed to get root partition name for ${DISK1}"
    exit 1
fi

if ! PART2_ROOT=$(get_partition_name "${DISK2}" 3); then
    log_error "Failed to get root partition name for ${DISK2}"
    exit 1
fi

# Wait for partition devices to be available (3-partition layout)
log_debug "Waiting for partition devices to be ready"
for part in "${PART1_EFI}" "${PART2_EFI}" "${PART1_SWAP}" "${PART2_SWAP}" "${PART1_ROOT}" "${PART2_ROOT}"; do
    timeout=30
    while [[ ${timeout} -gt 0 ]] && [[ ! -b "${part}" ]]; do
        sleep 1
        ((timeout--))
    done
    if [[ ! -b "${part}" ]]; then
        log_error "Partition ${part} not available after 30 seconds"
        exit 1
    fi
done

show_progress 3 10 "Creating ZFS root pool..."

# Cleanup before root pool creation
perform_basic_zfs_cleanup "rpool" "${PART1_ROOT}" "${PART2_ROOT}"

# Create ZFS pool
log_header "Creating ZFS Pool"
INSTALL_STATE="pools_creating_datasets"
log_info "Creating mirrored ZFS root pool (force import will be configured for first boot)"

# Create single ZFS pool with GRUB2 compatibility
if ! create_zfs_pool "${PART1_ROOT}" "${PART2_ROOT}" "${ASHIFT}" "${TRIM_ENABLED}"; then
    log_error "Failed to create ZFS pool"
    exit 1
fi

POOLS_CREATED="yes"
log_info "ZFS pool created successfully!"

show_progress 4 10 "Creating ZFS datasets..."

# Create essential datasets (single pool)
zfs create -o mountpoint=/ -o devices=on -o exec=on rpool/root
zfs create -o mountpoint=/var rpool/var
zfs create -o mountpoint=/var/log rpool/var/log

# Create additional datasets if selected
if [[ -n "${ADDITIONAL_DATASETS}" ]]; then
    log_info "Creating additional datasets..."
    IFS=' ' read -ra datasets <<< "${ADDITIONAL_DATASETS}"
    for dataset_spec in "${datasets[@]}"; do
        if [[ "${dataset_spec}" =~ ^([^:]+):(.+)$ ]]; then
            dataset_name="${BASH_REMATCH[1]}"
            mount_point="${BASH_REMATCH[2]}"
            log_info "Creating dataset ${dataset_name} → ${mount_point}"
            zfs create -o mountpoint="${mount_point}" "${dataset_name}"
        fi
    done
fi

# Mount tmpfs for /run
mkdir -p /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock
MOUNTS_ACTIVE="yes"

# Pools created successfully - proceeding with base system installation
# (Hostid synchronization will be performed at end of installation)

show_progress 6 10 "Installing base system..."

# Install Ubuntu base system
log_info "Installing Ubuntu base system with debootstrap..."
if ! debootstrap noble /mnt; then
    log_error "Failed to install Ubuntu base system"
    exit 1
fi

# Create ZFS config directory (cache file not used with cachefile=none)
mkdir -p /mnt/etc/zfs

show_progress 7 10 "Configuring system..."
INSTALL_STATE="configuring_system"

# Configure hostname and network
echo "${HOSTNAME}" > /mnt/etc/hostname

cat << EOF > /mnt/etc/hosts
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# Configure network
if ! DEFAULT_INTERFACE=$(get_network_interface); then
    log_error "Failed to detect network interface"
    exit 1
fi

cat << EOF > /mnt/etc/netplan/01-netcfg.yaml
network:
  version: 2
  ethernets:
    ${DEFAULT_INTERFACE}:
      dhcp4: true
      optional: true
EOF

# Configure APT sources
cat << 'EOF' > /mnt/etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF

show_progress 8 10 "Configuring system in chroot..."
INSTALL_STATE="chroot_configuration"

# Bind mount essential filesystems for chroot
mount --make-private --rbind /dev /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys /mnt/sys
CHROOT_ACTIVE="yes"

# Generate EFI Volume ID for consistent filesystem creation
if ! EFI_VOLUME_ID=$(generate_efi_volume_id "${HOSTNAME}"); then
    log_error "Failed to generate EFI Volume ID"
    exit 1
fi

# Create clean fstab - we'll update with actual UUID after EFI creation
cat > /mnt/etc/fstab << 'FSTAB_EOF'
# ZFS Root Installation - /etc/fstab
# ZFS filesystems are handled automatically by ZFS services

# EFI System Partition - will be updated with actual UUID after creation
# PLACEHOLDER_EFI_UUID /boot/efi vfat defaults 0 1

# Swap partitions - using device paths for fast failure detection
PART1_SWAP_PLACEHOLDER none swap sw,discard,pri=1 0 0
PART2_SWAP_PLACEHOLDER none swap sw,discard,pri=1 0 0

# tmpfs for /tmp (recommended for ZFS systems)
tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0
FSTAB_EOF

# Update swap placeholders
sed -i "s|PART1_SWAP_PLACEHOLDER|${PART1_SWAP}|" /mnt/etc/fstab
sed -i "s|PART2_SWAP_PLACEHOLDER|${PART2_SWAP}|" /mnt/etc/fstab

# Create comprehensive chroot configuration script
cat << 'CHROOT_SCRIPT' > /mnt/tmp/configure_system.sh
#!/bin/bash
set -euo pipefail

# Logging in chroot
ts() { date +'%F %T'; }
log_info() { echo "$(ts) CHROOT INFO: $*"; }
log_error() { echo "$(ts) CHROOT ERROR: $*"; }

exec > >(tee -a /tmp/chroot_config.log)
exec 2>&1

log_info "Starting chroot system configuration"

# Environment variables validated by validate_chroot_environment() before chroot execution

# Update packages
apt-get update

# Configure locale and timezone non-interactively
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# Preseed timezone configuration to prevent interactive prompts
echo "tzdata tzdata/Areas select $(echo "${TIMEZONE}" | cut -d'/' -f1)" | debconf-set-selections
echo "tzdata tzdata/Zones/$(echo "${TIMEZONE}" | cut -d'/' -f1) select $(echo "${TIMEZONE}" | cut -d'/' -f2-)" | debconf-set-selections

# Preseed locale configuration
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
echo "locales locales/default_environment_locale select en_US.UTF-8" | debconf-set-selections

# Install packages non-interactively
apt-get install --yes locales tzdata

# Generate locale
locale-gen en_US.UTF-8
echo 'LANG=en_US.UTF-8' > /etc/default/locale

# Apply timezone setting non-interactively
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
dpkg-reconfigure --frontend noninteractive tzdata

# Install essential packages
apt-get install --yes \
    nano vim curl wget \
    openssh-server \
    sudo rsync \
    bsdextrautils \
    man-db \
    htop \
    software-properties-common \
    systemd-timesyncd \
    cron \
    util-linux \
    memtest86+ \
    zfsutils-linux \
    zsh

# Create EFI filesystems with identical volume IDs
apt-get install --yes dosfstools

log_info "Creating EFI filesystems with volume ID ${EFI_VOLUME_ID}"
mkdosfs -F 32 -s 1 -n "EFI" -i "${EFI_VOLUME_ID}" "${PART1_EFI}"
mkdosfs -F 32 -s 1 -n "EFI" -i "${EFI_VOLUME_ID}" "${PART2_EFI}"

# Get the actual UUID that will be used for mounting
EFI_UUID=$(blkid -s UUID -o value "${PART1_EFI}" 2>/dev/null || echo "")

if [[ -z "${EFI_UUID}" ]]; then
    log_error "Failed to get UUID from created EFI partition"
    exit 1
fi

# Verify both partitions have the same UUID
UUID2=$(blkid -s UUID -o value "${PART2_EFI}" 2>/dev/null || echo "")
if [[ "${EFI_UUID}" != "${UUID2}" ]]; then
    log_error "EFI UUID mismatch: ${EFI_UUID} vs ${UUID2}"
    exit 1
fi

log_info "EFI partitions created with matching UUID: ${EFI_UUID}"

# Update fstab with the actual UUID
sed -i "s|# PLACEHOLDER_EFI_UUID|UUID=${EFI_UUID}|" /etc/fstab

# Mount primary EFI partition
mkdir -p /boot/efi
mount "${PART1_EFI}" /boot/efi

# Install kernel and bootloader
DEBIAN_FRONTEND=noninteractive apt-get install --yes \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    linux-image-generic \
    linux-headers-generic \
    shim-signed \
    zfs-initramfs

# Configure swap
log_info "Configuring swap partitions"
mkswap -f "${PART1_SWAP}"
mkswap -f "${PART2_SWAP}"
swapon -a

# Create admin user
useradd -m -s /bin/bash -G sudo,adm,cdrom,dip,plugdev "${ADMIN_USER}"
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd

# Configure SSH key if provided
if [[ "${USE_SSH_KEY:-false}" == "true" ]] && [[ -n "${SSH_KEY:-}" ]]; then
    mkdir -p "/home/${ADMIN_USER}/.ssh"
    echo "${SSH_KEY}" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chmod 700 "/home/${ADMIN_USER}/.ssh"
    chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
fi

# Lock root account
passwd -l root

# Enable SSH service
systemctl enable ssh

# Configure tmpfs for /tmp
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

# Apply system optimizations if requested
if [[ "${USE_PERFORMANCE_TUNABLES:-false}" == "true" ]]; then
    log_info "Applying performance tunables"
    cat << 'SYSCTL_EOF' >> /etc/sysctl.conf

# ZFS and server performance optimizations
vm.swappiness=10
vm.min_free_kbytes=131072
kernel.sysrq=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion=bbr
net.ipv4.tcp_fastopen=3
SYSCTL_EOF
fi

# ZFS configuration will be set up after installation completes
log_info "Force import configuration will be set up after installation"

# Configure GRUB with console and AppArmor settings
if [[ "${USE_SERIAL_CONSOLE:-false}" == "true" ]]; then
    KERNEL_CMDLINE="console=tty1 console=${SERIAL_PORT:-ttyS1},${SERIAL_SPEED:-115200}"
    if [[ "${USE_APPARMOR:-true}" == "false" ]]; then
        KERNEL_CMDLINE="${KERNEL_CMDLINE} apparmor=0"
    fi
    KERNEL_CMDLINE="${KERNEL_CMDLINE} root=ZFS=rpool/root"
        
    cat << GRUB_SERIAL_EOF > /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_CMDLINE_LINUX="${KERNEL_CMDLINE}"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=${SERIAL_SPEED:-115200} --unit=${SERIAL_UNIT:-1} --word=8 --parity=no --stop=1"
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_DISABLE_OS_PROBER=true
GRUB_SERIAL_EOF
else
    KERNEL_CMDLINE="root=ZFS=rpool/root"
    if [[ "${USE_APPARMOR:-true}" == "false" ]]; then
        KERNEL_CMDLINE="apparmor=0 ${KERNEL_CMDLINE}"
    fi
        
    cat << GRUB_LOCAL_EOF > /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="${KERNEL_CMDLINE}"
GRUB_TERMINAL="console"
GRUB_DISABLE_OS_PROBER=true
GRUB_LOCAL_EOF
fi

# Update GRUB configuration
update-grub

# Install GRUB to both EFI partitions
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id="Ubuntu-${DISK1_NAME}" --recheck --no-floppy

mkdir -p /boot/efi2
mount "${PART2_EFI}" /boot/efi2
grub-install --target=x86_64-efi --efi-directory=/boot/efi2 \
    --bootloader-id="Ubuntu-${DISK2_NAME}" --recheck --no-floppy
umount /boot/efi2
rmdir /boot/efi2

# Create ZFS maintenance scripts
if [[ "${TRIM_ENABLED}" == "on" ]]; then
    cat << 'TRIM_EOF' > /etc/cron.weekly/zfs-trim
#!/bin/bash
for pool in $(zpool list -H -o name 2>/dev/null); do
    zpool trim "${pool}"
done
TRIM_EOF
    chmod +x /etc/cron.weekly/zfs-trim
fi

cat << 'SCRUB_EOF' > /etc/cron.monthly/zfs-scrub
#!/bin/bash
for pool in $(zpool list -H -o name 2>/dev/null); do
    zpool scrub "${pool}"
done
SCRUB_EOF
chmod +x /etc/cron.monthly/zfs-scrub

# Enable essential services using Ubuntu's built-in ZFS services
log_info "Enabling ZFS and system services"

# Ubuntu 24.04 bulletproof configuration: Use scan-based import only
# This avoids cache file corruption issues and ensures reliable first boot
systemctl enable zfs-import-scan.service
systemctl enable zfs-import.target
systemctl enable zfs-mount.service
systemctl enable zfs.target
systemctl enable systemd-timesyncd cron

# Update initramfs
update-initramfs -c -k all

log_info "Chroot configuration completed successfully"
CHROOT_SCRIPT

chmod +x /mnt/tmp/configure_system.sh

# Execute in chroot with all environment variables and validation
if ! validate_chroot_environment; then
    log_error "Invalid chroot environment"
    exit 1
fi

chroot /mnt /usr/bin/env \
    DISK1="${DISK1}" \
    DISK2="${DISK2}" \
    PART1_EFI="${PART1_EFI}" \
    PART2_EFI="${PART2_EFI}" \
    PART1_SWAP="${PART1_SWAP}" \
    PART2_SWAP="${PART2_SWAP}" \
    DISK1_NAME="${DISK1_NAME}" \
    DISK2_NAME="${DISK2_NAME}" \
    ADMIN_USER="${ADMIN_USER}" \
    ADMIN_PASS="${ADMIN_PASS}" \
    SSH_KEY="${SSH_KEY:-}" \
    USE_SSH_KEY="${USE_SSH_KEY:-false}" \
    EFI_VOLUME_ID="${EFI_VOLUME_ID}" \
    DEFAULT_INTERFACE="${DEFAULT_INTERFACE}" \
    TRIM_ENABLED="${TRIM_ENABLED}" \
    TIMEZONE="${TIMEZONE}" \
    USE_SERIAL_CONSOLE="${USE_SERIAL_CONSOLE:-false}" \
    SERIAL_PORT="${SERIAL_PORT:-ttyS1}" \
    SERIAL_SPEED="${SERIAL_SPEED:-115200}" \
    SERIAL_UNIT="${SERIAL_UNIT:-1}" \
    USE_APPARMOR="${USE_APPARMOR:-true}" \
    USE_PERFORMANCE_TUNABLES="${USE_PERFORMANCE_TUNABLES:-false}" \
    bash /tmp/configure_system.sh

if [[ $? -ne 0 ]]; then
    log_error "Chroot configuration failed!"
    exit 1
fi

show_progress 9 10 "Finalizing installation..."
INSTALL_STATE="finalizing"

# Create ZFS configuration
log_info "Creating ZFS configuration for reliable pool imports"

if ! setup_zfs_config; then
    log_error "Failed to setup ZFS configuration"
    exit 1
fi

# Create EFI sync script
if ! create_efi_sync_script; then
    log_error "Failed to create EFI sync script"
    exit 1
fi

# Create post-install test script
log_info "Creating post-install test script..."
create_post_install_test() {
    cat << 'TEST_SCRIPT' > /mnt/usr/local/bin/test-zfs-mirror
#!/bin/bash
# ZFS Mirror Installation Test Script
set -euo pipefail

echo "=== ZFS Mirror Installation Test ==="
echo "Generated on: $(date)"
echo ""

echo "1. Pool Status:"
zpool status | grep -E "(pool:|state:|scan:|errors:)" || echo "  ERROR: Could not get pool status"
echo ""

echo "2. Pool Health Summary:"
if zpool list rpool &>/dev/null; then
    status=$(zpool list -H -o health rpool 2>/dev/null || echo "UNKNOWN")
    echo "  rpool: $status"
else
    echo "  rpool: NOT FOUND"
fi
echo ""

echo "3. ZFS Dataset Usage:"
zfs list -o name,used,avail,refer,mountpoint | head -10
echo ""

echo "4. EFI Boot Entries:"
efibootmgr 2>/dev/null | grep -E "(Boot|Ubuntu-)" || echo "  ERROR: Could not read EFI boot entries"
echo ""

echo "5. EFI Partition Status:"
EFI_UUID=$(awk '/\/boot\/efi/ && /^UUID=/ {gsub(/UUID=/, "", $1); print $1}' /etc/fstab 2>/dev/null || echo "")
if [[ -n "$EFI_UUID" ]]; then
    echo "  EFI UUID: $EFI_UUID"
    mapfile -t EFI_PARTS < <(blkid --output device --match-token UUID="$EFI_UUID" 2>/dev/null || true)
    echo "  EFI Partitions found: ${#EFI_PARTS[@]}"
    for part in "${EFI_PARTS[@]}"; do
        echo "    $part"
    done
else
    echo "  ERROR: Could not find EFI UUID in fstab"
fi
echo ""

echo "6. Testing EFI Sync:"
if [[ -x /usr/local/bin/sync-efi-partitions ]]; then
    echo "  Running EFI sync test..."
    if /usr/local/bin/sync-efi-partitions; then
        echo "  ✓ EFI sync successful"
    else
        echo "  ✗ EFI sync failed"
    fi
else
    echo "  ✗ EFI sync script not found"
fi
echo ""

echo "7. System Information:"
echo "  Hostname: $(hostname)"
echo "  Kernel: $(uname -r)"
echo "  ZFS Version: $(zfs version 2>/dev/null | head -1 || echo "Unknown")"
echo "  Uptime: $(uptime | cut -d',' -f1)"
echo ""

echo "8. Drive Failure Simulation Test Commands:"
echo "  To test drive failure resilience, run these commands as root:"
echo ""
echo "  # Simulate drive 1 failure:"
mapfile -t RPOOL_DEVS < <(zpool status rpool | awk '/\/dev\// {print $1}' | head -2)
if [[ ${#RPOOL_DEVS[@]} -ge 2 ]]; then
    echo "  sudo zpool offline rpool ${RPOOL_DEVS[0]}"
    echo "  # Verify system still works, then bring it back online:"
    echo "  sudo zpool online rpool ${RPOOL_DEVS[0]}"
    echo ""
    echo "  # Simulate drive 2 failure:"
    echo "  sudo zpool offline rpool ${RPOOL_DEVS[1]}"
    echo "  sudo zpool online rpool ${RPOOL_DEVS[1]}"
else
    echo "  # Could not determine pool devices automatically"
    echo "  # Use: zpool status rpool"
    echo "  # Then: sudo zpool offline rpool /dev/DEVICE"
fi
echo ""

echo "=== Test Complete ==="
echo "For recovery information, see: /root/ZFS-RECOVERY-GUIDE.txt"
TEST_SCRIPT

    chmod +x /mnt/usr/local/bin/test-zfs-mirror
    log_info "Post-install test script created: /usr/local/bin/test-zfs-mirror"

# Create GRUB sync script for all ZFS mirror drives
log_info "Creating GRUB sync script for mirror drives..."
cat << 'GRUB_SYNC_SCRIPT' > /mnt/usr/local/bin/sync-grub-to-mirror-drives
#!/bin/bash
#
# sync-grub-to-mirror-drives
#
# CREATED BY: Ubuntu ZFS Mirror Root Installation Script (v${VERSION})
# PURPOSE: Install GRUB to all drives in the ZFS boot/root mirror for redundancy
# LOCATION: /usr/local/bin/sync-grub-to-mirror-drives
#
# This script discovers all drives participating in the ZFS boot and root
# pools and installs GRUB to each drive for full redundancy. It runs
# automatically during installation and can be run manually for maintenance.
#
# IMPORTANT: grub-install creates drive-specific EFI folders (Ubuntu-<DriveID>)
# on each drive's EFI partition. This ensures each drive has its own bootloader
# folder in its own EFI partition, enabling independent booting.
#

set -euo pipefail

# Set up logging functions
log_info() { logger -t "sync-grub-to-mirror-drives" -p user.info "$1"; echo "$1"; }
log_error() { logger -t "sync-grub-to-mirror-drives" -p user.err "$1"; echo "ERROR: $1" >&2; }
log_warning() { logger -t "sync-grub-to-mirror-drives" -p user.warning "$1"; echo "WARNING: $1"; }

# Get drive identifier for EFI folder naming (same logic as installation)
get_drive_identifier() {
    local disk_path="$1"
    local model_part=""
    local suffix_part=""

    # Extract model and suffix from by-id path
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

    # Clean up model part
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

log_info "Syncing GRUB to all ZFS mirror drives..."

# Get EFI UUID from fstab
EFI_UUID=$(awk '/\/boot\/efi/ && /^UUID=/ {gsub(/UUID=/, "", $1); print $1}' /etc/fstab 2>/dev/null || echo "")
if [[ -z "${EFI_UUID}" ]]; then
    log_error "Could not find EFI UUID in fstab"
    exit 1
fi

# Get currently mounted EFI partition
MOUNTED_EFI=$(mount | grep '/boot/efi' | awk '{print $1}')
if [[ -z "${MOUNTED_EFI}" ]]; then
    log_error "No EFI partition currently mounted at /boot/efi"
    exit 1
fi

# Find all EFI partitions with this UUID
mapfile -t EFI_PARTITIONS < <(blkid --output device --match-token UUID="${EFI_UUID}" 2>/dev/null || true)
if [[ ${#EFI_PARTITIONS[@]} -lt 2 ]]; then
    log_warning "Only ${#EFI_PARTITIONS[@]} EFI partition(s) found, expected 2+"
fi

# Build map of EFI partition -> base drive
declare -A PARTITION_TO_DRIVE
for efi_part in "${EFI_PARTITIONS[@]}"; do
    base_drive=""

    if [[ "$efi_part" =~ ^(.+)-part[0-9]+$ ]]; then
        # Already a by-id path: /dev/disk/by-id/ata-DISK123-part1
        base_drive="${BASH_REMATCH[1]}"
        log_info "  Mapped: $efi_part -> $base_drive"
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
        log_info "  Mapped: $efi_part -> $base_drive"
    else
        log_warning "  Could not parse partition name: $efi_part (will skip during install)"
    fi

    if [[ -n "$base_drive" ]]; then
        PARTITION_TO_DRIVE["$efi_part"]="$base_drive"
    fi
done

log_info "Found ${#EFI_PARTITIONS[@]} EFI partition(s) to sync"

# Process each EFI partition
INSTALL_COUNT=0
for efi_part in "${EFI_PARTITIONS[@]}"; do
    base_drive="${PARTITION_TO_DRIVE[$efi_part]:-}"
    if [[ -z "$base_drive" ]]; then
        log_warning "Could not determine base drive for $efi_part, skipping"
        continue
    fi

    DRIVE_ID=$(get_drive_identifier "$base_drive")
    log_info "Processing $efi_part (Drive: $base_drive, ID: Ubuntu-${DRIVE_ID})"

    # If this is the currently mounted partition, install directly
    if [[ "$efi_part" == "$MOUNTED_EFI" ]]; then
        log_info "  Installing to mounted partition..."
        if grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Ubuntu-${DRIVE_ID}" --recheck --no-floppy "$base_drive" >/dev/null 2>&1; then
            log_info "  ✓ GRUB installed to mounted partition"
            ((INSTALL_COUNT++))
        else
            log_error "  ✗ Failed to install GRUB to mounted partition"
        fi
    else
        # Mount the other partition temporarily and install there
        TEMP_MOUNT=$(mktemp -d)
        log_info "  Mounting $efi_part at $TEMP_MOUNT..."

        if mount "$efi_part" "$TEMP_MOUNT"; then
            log_info "  Installing to $TEMP_MOUNT..."
            if grub-install --target=x86_64-efi --efi-directory="$TEMP_MOUNT" --bootloader-id="Ubuntu-${DRIVE_ID}" --recheck --no-floppy "$base_drive" >/dev/null 2>&1; then
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
GRUB_SYNC_SCRIPT

chmod +x /mnt/usr/local/bin/sync-grub-to-mirror-drives
log_info "GRUB sync script created: /usr/local/bin/sync-grub-to-mirror-drives"

# Create unified mirror boot sync script (just runs GRUB sync which handles everything)
log_info "Creating unified mirror boot sync script..."
cat << 'MIRROR_BOOT_SYNC' > /mnt/usr/local/bin/sync-mirror-boot
#!/bin/bash
# Unified ZFS Mirror Boot Synchronization Script
# Installs GRUB to all mirror drives with drive-specific EFI folders
# Runs automatically on kernel/initramfs updates and manual update-grub

set -euo pipefail

log_info() { logger -t "sync-mirror-boot" -p user.info "$1" 2>/dev/null || true; echo "$(date '+%F %T') [sync-mirror-boot] INFO: $1"; }
log_error() { logger -t "sync-mirror-boot" -p user.err "$1" 2>/dev/null || true; echo "$(date '+%F %T') [sync-mirror-boot] ERROR: $1" >&2; }

log_info "=== ZFS Mirror Boot Sync Starting ==="

# Sync GRUB to all mirror drives (installs to each drive's EFI partition)
if [[ -x /usr/local/bin/sync-grub-to-mirror-drives ]]; then
    if /usr/local/bin/sync-grub-to-mirror-drives; then
        log_info "=== ZFS Mirror Boot Sync Completed Successfully ==="
        exit 0
    else
        log_error "GRUB sync failed"
        exit 1
    fi
else
    log_error "GRUB sync script not found at /usr/local/bin/sync-grub-to-mirror-drives"
    exit 1
fi
MIRROR_BOOT_SYNC

chmod +x /mnt/usr/local/bin/sync-mirror-boot
log_info "Unified mirror boot sync script created: /usr/local/bin/sync-mirror-boot"

# Create /etc/grub.d hook for automatic sync on update-grub
log_info "Creating /etc/grub.d/99-zfs-mirror-sync hook..."
cat << 'GRUB_D_HOOK' > /mnt/etc/grub.d/99-zfs-mirror-sync
#!/bin/sh
# ZFS Mirror Boot Sync Hook for update-grub
# Automatically syncs GRUB and EFI partitions when update-grub runs
# This ensures all mirror drives stay in sync even on manual updates

# Only run if the unified sync script exists
if [ -x /usr/local/bin/sync-mirror-boot ]; then
    # Run sync in background to avoid blocking update-grub
    # Output nothing to avoid polluting grub.cfg
    /usr/local/bin/sync-mirror-boot >/dev/null 2>&1 &
fi

# Exit cleanly with no output (won't affect grub.cfg generation)
exit 0
GRUB_D_HOOK

chmod +x /mnt/etc/grub.d/99-zfs-mirror-sync
log_info "GRUB hook created: /etc/grub.d/99-zfs-mirror-sync"

# Create kernel/initramfs hooks (symlinks to unified script)
log_info "Creating kernel and initramfs hooks..."
ln -sf /usr/local/bin/sync-mirror-boot /mnt/etc/kernel/postinst.d/zz-sync-mirror-boot
ln -sf /usr/local/bin/sync-mirror-boot /mnt/etc/kernel/postrm.d/zz-sync-mirror-boot

# Create initramfs hook directory if it doesn't exist
mkdir -p /mnt/etc/initramfs/post-update.d
ln -sf /usr/local/bin/sync-mirror-boot /mnt/etc/initramfs/post-update.d/zz-sync-mirror-boot
log_info "Kernel/initramfs hooks created (symlinked to /usr/local/bin/sync-mirror-boot)"

# Create shutdown sync service (belt-and-suspenders final sync before poweroff)
log_info "Creating shutdown sync service for final synchronization..."
cat << 'SHUTDOWN_SERVICE' > /mnt/etc/systemd/system/zfs-mirror-shutdown-sync.service
[Unit]
Description=ZFS Mirror Boot Sync on Shutdown - Final synchronization before poweroff
Documentation=https://github.com/csmarshall/ubuntu-zfs-mirror
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
After=umount.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-mirror-boot
RemainAfterExit=yes
TimeoutStartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=halt.target reboot.target shutdown.target
SHUTDOWN_SERVICE

chmod 644 /mnt/etc/systemd/system/zfs-mirror-shutdown-sync.service
chroot /mnt systemctl enable zfs-mirror-shutdown-sync.service
log_info "Shutdown sync service created and enabled"

# Remove old APT hook (replaced by grub.d and kernel hooks)
if [[ -f /mnt/etc/apt/apt.conf.d/99-sync-efi ]]; then
    rm -f /mnt/etc/apt/apt.conf.d/99-sync-efi
    log_info "Removed old APT hook (replaced by grub.d and kernel hooks)"
fi

# Document manual cleanup commands in recovery guide (no separate script needed)

# Create drive replacement script
log_info "Creating drive replacement script..."
cat << 'REPLACE_DRIVE_SCRIPT' > /mnt/usr/local/bin/replace-drive-in-zfs-boot-mirror
#!/bin/bash
#
# replace-drive-in-zfs-boot-mirror
#
# CREATED BY: Ubuntu ZFS Mirror Root Installation Script (v${VERSION})
# PURPOSE: Replace a failed drive in the ZFS boot/root mirror
# LOCATION: /usr/local/bin/replace-drive-in-zfs-boot-mirror
#
# This script automatically detects failed drives in the ZFS mirror and guides
# you through replacing them with a new drive. It handles partitioning, pool
# replacement using proper identifiers (GUIDs when needed), EFI synchronization,
# and GRUB installation for complete drive replacement with full redundancy.
#

set -euo pipefail

# Set up logging functions
log_info() { logger -t "replace-drive-in-zfs-boot-mirror" -p user.info "$1"; echo "$1"; }
log_error() { logger -t "replace-drive-in-zfs-boot-mirror" -p user.err "$1"; echo "ERROR: $1" >&2; }
log_warning() { logger -t "replace-drive-in-zfs-boot-mirror" -p user.warning "$1"; echo "WARNING: $1"; }

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <replacement_drive>"
    echo "Example: $0 /dev/disk/by-id/ata-WDC_WD1234567890_NEWSERIAL"
    echo ""
    echo "This script will:"
    echo "  1. Auto-detect failed drives in rpool"
    echo "  2. Partition the replacement drive to match the mirror"
    echo "  3. Replace failed drives using stable identifiers (GUIDs when needed)"
    echo "  4. Reinstall GRUB and sync EFI partitions"
    echo "  5. Wait for resilvering to complete"
    echo ""
    echo "Note: Use full /dev/disk/by-id/ path for replacement drive"
    exit 1
}

if [[ $# -ne 1 ]]; then
    usage
fi

REPLACEMENT_DRIVE="$1"

# Verify replacement drive exists
if [[ ! -b "$REPLACEMENT_DRIVE" ]]; then
    log_error "Replacement drive $REPLACEMENT_DRIVE does not exist"
    echo -e "${RED}Error: Replacement drive $REPLACEMENT_DRIVE does not exist${NC}"
    exit 1
fi

log_info "Starting drive replacement: $REPLACEMENT_DRIVE"
echo -e "${BLUE}Analyzing ZFS pool status for failed drives...${NC}"

# Function to detect failed devices in a pool
detect_failed_devices() {
    local pool="$1"
    local failed_devices=()

    if ! zpool status "$pool" &>/dev/null; then
        echo "Pool $pool not found"
        return 1
    fi

    # Check for devices in failed states (NOT ONLINE or DEGRADED)
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]+([^[:space:]]+)[[:space:]]+(FAULTED|UNAVAIL|REMOVED|OFFLINE) ]]; then
            device="${BASH_REMATCH[1]}"
            state="${BASH_REMATCH[2]}"
            failed_devices+=("$device:$state")
            echo "  Found failed device: $device (state: $state)"
        fi
    done < <(zpool status -v "$pool")

    # Also check for numeric GUIDs in failed states (indicates device path issues)
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]+([0-9]+)[[:space:]]+(FAULTED|UNAVAIL|REMOVED|OFFLINE) ]]; then
            guid="${BASH_REMATCH[1]}"
            state="${BASH_REMATCH[2]}"
            # Check if this is actually a GUID (long number)
            if [[ ${#guid} -gt 10 ]]; then
                failed_devices+=("$guid:$state")
                echo "  Found device with GUID: $guid (state: $state)"
            fi
        fi
    done < <(zpool status -v "$pool")

    printf '%s\n' "${failed_devices[@]}"
}

# Function to validate that resilvering has started successfully
validate_resilvering_started() {
    echo -e "${BLUE}Validating that resilvering has started...${NC}"

    # Wait a moment for ZFS to begin resilvering
    sleep 3

    # Check if resilvering is active
    if zpool status | grep -q "resilver\|replace"; then
        echo -e "${GREEN}✓ Resilvering has started successfully${NC}"
        echo ""
        echo "Current status:"
        zpool status
        return 0
    else
        echo -e "${RED}✗ Resilvering does not appear to have started${NC}"
        echo "Current pool status:"
        zpool status
        return 1
    fi
}

# Detect failed devices in rpool
echo "Checking rpool for failed devices..."
RPOOL_FAILED=($(detect_failed_devices "rpool"))

if [[ ${#RPOOL_FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}No failed devices detected in rpool.${NC}"
    echo ""
    echo "Current pool status:"
    zpool status
    echo ""
    echo -e "${YELLOW}${BOLD}Drive replacement is only allowed for failed drives.${NC}"
    echo -e "${YELLOW}This safety check prevents accidentally replacing healthy drives.${NC}"
    echo ""
    echo -e "${YELLOW}If you need to replace a working drive for other reasons:${NC}"
    echo -e "  1. Manually offline the drive: ${GREEN}zpool offline poolname device${NC}"
    echo -e "  2. Then run this script again"
    echo ""
    exit 0
fi

echo ""
echo -e "${RED}${BOLD}⚠️  SAFETY VERIFICATION ⚠️${NC}"
echo -e "${YELLOW}The following drives will be replaced with ${BOLD}${REPLACEMENT_DRIVE}${NC}:"

echo -e "${YELLOW}Failed devices summary:${NC}"
if [[ ${#RPOOL_FAILED[@]} -gt 0 ]]; then
    echo "  rpool: ${RPOOL_FAILED[*]}"
fi

echo -e "${RED}${BOLD}WARNING: This will completely wipe ${REPLACEMENT_DRIVE}${NC}"
echo -e "${YELLOW}Press Enter to continue, or Ctrl+C to abort...${NC}"
read -r

echo -e "${BLUE}Step 1: Preparing replacement drive...${NC}"
log_info "Step 1: Preparing replacement drive"

# Wipe the replacement drive
log_info "Wiping replacement drive: $REPLACEMENT_DRIVE"
sgdisk --zap-all "$REPLACEMENT_DRIVE"

# Copy partition table from a working drive
WORKING_DRIVE_RAW=$(zpool status rpool | grep -E '^[[:space:]]+.*-part[0-9]+' | grep ONLINE | head -1 | awk '{print $1}' | sed 's/-part[0-9]*$//')
if [[ "$WORKING_DRIVE_RAW" =~ ^/dev/disk/by-id/ ]]; then
    WORKING_DRIVE="$WORKING_DRIVE_RAW"
else
    WORKING_DRIVE="/dev/disk/by-id/$WORKING_DRIVE_RAW"
fi
if [[ -z "$WORKING_DRIVE" ]]; then
    log_error "Could not find a working drive to copy partition table from"
    echo -e "${RED}Error: Could not find a working drive to copy partition table from${NC}"
    exit 1
fi

log_info "Copying partition table from $WORKING_DRIVE to $REPLACEMENT_DRIVE"
echo "Copying partition table from $WORKING_DRIVE to $REPLACEMENT_DRIVE"
sgdisk "$WORKING_DRIVE" -R "$REPLACEMENT_DRIVE"
sgdisk -G "$REPLACEMENT_DRIVE"

echo -e "${BLUE}Step 2: Replacing failed drives in ZFS pools...${NC}"
log_info "Step 2: Replacing failed drives in ZFS pools"

# Replace in rpool if needed
if [[ ${#RPOOL_FAILED[@]} -gt 0 ]]; then
    log_info "Replacing failed device(s) in rpool: ${RPOOL_FAILED[*]}"
    for failed_device_info in "${RPOOL_FAILED[@]}"; do
        failed_device="${failed_device_info%:*}"
        log_info "Attempting rpool replacement: $failed_device -> ${REPLACEMENT_DRIVE}-part2"
        echo "Replacing $failed_device in rpool..."
        if zpool replace rpool "$failed_device" "${REPLACEMENT_DRIVE}-part2"; then
            log_info "rpool replacement initiated successfully"
            echo "  ✓ rpool replacement initiated"
            break
        else
            log_warning "rpool replacement failed for $failed_device"
            echo "  ✗ rpool replacement failed, trying alternative method..."
        fi
    done
fi

echo -e "${BLUE}Step 3: Installing GRUB and syncing EFI...${NC}"
log_info "Step 3: Installing GRUB and syncing EFI"

# Format EFI partition
log_info "Formatting EFI partition: ${REPLACEMENT_DRIVE}-part1"
mkfs.fat -F32 "${REPLACEMENT_DRIVE}-part1"

# Sync EFI partitions
if [[ -x /usr/local/bin/sync-efi-partitions ]]; then
    log_info "Syncing EFI partitions using sync script"
    echo "Syncing EFI partitions..."
    /usr/local/bin/sync-efi-partitions
else
    log_warning "EFI sync script not found, manual EFI sync required"
    echo -e "${YELLOW}Warning: EFI sync script not found, manual EFI sync required${NC}"
fi

# Install GRUB to replacement drive
log_info "Installing GRUB to replacement drive: $REPLACEMENT_DRIVE"
echo "Installing GRUB to replacement drive..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi "$REPLACEMENT_DRIVE"

echo -e "${BLUE}Step 4: Validating drive replacement...${NC}"

# Validate that resilvering started successfully
if ! validate_resilvering_started; then
    echo -e "${RED}Drive replacement may have failed. Please check the output above.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}Drive replacement initiated successfully!${NC}"
echo ""
echo -e "${YELLOW}${BOLD}Resilvering is now in progress.${NC}"
echo ""
echo -e "${YELLOW}Monitor progress with:${NC}"
echo -e "  ${GREEN}watch zpool status${NC}     # Live updates every 2 seconds"
echo -e "  ${GREEN}zpool status${NC}           # Check current status"
echo ""
echo -e "${YELLOW}Resilvering will complete automatically in the background.${NC}"
echo -e "${YELLOW}Your system remains fully functional during this process.${NC}"
echo ""
echo -e "${YELLOW}When resilvering completes:${NC}"
echo -e "  • Pool status will show all drives as ONLINE"
echo -e "  • No 'resilver' or 'replace' text in zpool status"
echo -e "  • Both drives will be fully synchronized"
echo ""
echo -e "${GREEN}Final verification commands:${NC}"
echo -e "  ${GREEN}zpool status${NC}                    # Verify all drives ONLINE"
echo -e "  ${GREEN}sudo /usr/local/bin/test-zfs-mirror${NC}  # Test system integrity"
echo ""

# Clear any remaining errors
log_info "Clearing pool errors"
# Single-pool architecture - only rpool exists
zpool clear rpool 2>/dev/null || true

log_info "Drive replacement process completed successfully!"
echo -e "${GREEN}Drive replacement process completed successfully!${NC}"
REPLACE_DRIVE_SCRIPT

chmod +x /mnt/usr/local/bin/replace-drive-in-zfs-boot-mirror
log_info "Drive replacement script created: /usr/local/bin/replace-drive-in-zfs-boot-mirror"
}

if ! create_post_install_test; then
    log_error "Failed to create post-install test script"
    exit 1
fi

# Create recovery documentation
log_info "Creating recovery documentation..."
create_recovery_guide() {
    cat << EOF > /mnt/root/ZFS-RECOVERY-GUIDE.txt
===============================================================================
ZFS MIRROR RECOVERY GUIDE
===============================================================================
Installation Date: $(date)
Hostname: ${HOSTNAME}
Drive 1: ${DISK1} (${DISK1_NAME})
Drive 2: ${DISK2} (${DISK2_NAME})
Admin User: ${ADMIN_USER}

===============================================================================
EMERGENCY BOOT PROCEDURES
===============================================================================

1. POOLS WON'T IMPORT ON BOOT:
   Boot from Ubuntu Live USB, then:

   sudo zpool import -f -R /mnt rpool
   sudo mount -t zfs rpool/root /mnt
   sudo mount -t zfs rpool/boot /mnt/boot
   sudo mount ${PART1_EFI} /mnt/boot/efi

   # Fix the issue, then:
   sudo umount -R /mnt
   sudo zpool export rpool

2. GRUB/EFI BOOT REPAIR:
   From live system with pools imported:

   sudo mount --bind /dev /mnt/dev
   sudo mount --bind /proc /mnt/proc
   sudo mount --bind /sys /mnt/sys
   sudo chroot /mnt

   grub-install --target=x86_64-efi --efi-directory=/boot/efi
   update-grub
   exit

3. SINGLE DRIVE FAILURE REPLACEMENT:

   Drive 1 (${DISK1}) failed:
   sudo zpool replace rpool ${PART1_ROOT} /dev/NEW-DRIVE-part3

   Drive 2 (${DISK2}) failed:
   sudo zpool replace rpool ${PART2_ROOT} /dev/NEW-DRIVE-part3

   After replacement, recreate EFI and swap:
   sudo mkdosfs -F 32 -s 1 -n "EFI" -i ${EFI_VOLUME_ID} /dev/NEW-DRIVE-part1
   sudo mkswap /dev/NEW-DRIVE-part2
   sudo /usr/local/bin/sync-efi-partitions

===============================================================================
USEFUL COMMANDS
===============================================================================

Check pool status:        sudo zpool status
Check dataset usage:      sudo zfs list
Test system:             sudo /usr/local/bin/test-zfs-mirror
Sync EFI partitions:     sudo /usr/local/bin/sync-efi-partitions
Sync GRUB to all drives: sudo /usr/local/bin/sync-grub-to-mirror-drives
Replace failed drive:    sudo /usr/local/bin/replace-drive-in-zfs-boot-mirror /dev/disk/by-id/NEW-DRIVE
Manual cleanup (if needed): sudo systemctl disable zfs-firstboot-cleanup.service && sudo sed -i 's/ zfs_force=1//g' /etc/default/grub && sudo update-grub
Check boot entries:      efibootmgr

Force import (emergency): sudo zpool import -f rpool

Scrub pools (monthly):    sudo zpool scrub rpool
Check scrub progress:     sudo zpool status

===============================================================================
PARTITION LAYOUT REFERENCE
===============================================================================

Each drive has 3 partitions:
  part1: EFI System Partition (1GB, FAT32, UUID=${EFI_VOLUME_ID})
  part2: Swap (${SWAP_SIZE})
  part3: Root Pool (Remaining space, ZFS with /boot)

Drive 1 partitions:
  ${PART1_EFI} (EFI)
  ${PART1_SWAP} (Swap)
  ${PART1_ROOT} (Root Pool)

Drive 2 partitions:
  ${PART2_EFI} (EFI)
  ${PART2_SWAP} (Swap)
  ${PART2_ROOT} (Root Pool)

===============================================================================
CONTACT AND SUPPORT
===============================================================================

Original script: ${ORIGINAL_REPO}
Installation log: ${LOG_FILE}

For ZFS documentation: https://openzfs.github.io/openzfs-docs/
For Ubuntu ZFS guide: https://ubuntu.com/tutorials/setup-zfs-storage-pool

===============================================================================
EOF

    chmod 600 /mnt/root/ZFS-RECOVERY-GUIDE.txt
    log_info "Recovery guide created: /root/ZFS-RECOVERY-GUIDE.txt"
}

if ! create_recovery_guide; then
    log_error "Failed to create recovery guide"
    exit 1
fi

# ================================================================
# FIRST-BOOT FORCE IMPORT CONFIGURATION
# ================================================================
# Configure first boot to use 'zfs_force=1' kernel parameter for reliable import.
# This tells the ZFS initramfs to use 'zpool import -f' for reliable import.
# After successful first boot, the system automatically removes this configuration
# and future boots use clean imports without force flags.

# Note: Using simplified /etc/default/grub approach - no complex backups needed

INSTALL_STATE="configuring_first_boot"

# Configure simplified force import for reliable first boot
log_info "Configuring first-boot force import for reliable ZFS pool access..."

# Use robust temporary GRUB script approach (no permanent system modifications)
log_info "Creating temporary GRUB script for reliable force import..."

# Create temporary GRUB script that generates force import menuentry
cat > /mnt/etc/grub.d/09_zfs_force_import << 'GRUB_FORCE_SCRIPT_EOF'
#!/bin/sh
set -e

# Only run if cleanup service exists and is enabled (first boot only)
# During installation, the service file exists but may not be enabled yet
if [ -f /etc/systemd/system/zfs-firstboot-cleanup.service ]; then
    # During first boot, check if service is enabled
    if systemctl is-enabled zfs-firstboot-cleanup.service >/dev/null 2>&1; then
        logger -t "grub-zfs-force" -p user.info "Cleanup service enabled, generating force import menuentry"
    else
        # During installation, service exists but not enabled yet - still generate
        logger -t "grub-zfs-force" -p user.info "Installation phase: generating force import menuentry"
    fi
else
    # No service file means cleanup completed or not a ZFS force import system
    logger -t "grub-zfs-force" -p user.info "No cleanup service found, skipping force import menuentry generation"
    exit 0
fi

logger -t "grub-zfs-force" -p user.info "Generating temporary ZFS force import menuentry for first boot"

# Source GRUB configuration
. /etc/default/grub

# Set up environment for GRUB functions
prefix="/usr"
datarootdir="/usr/share"
pkgdatadir="/usr/share/grub"
. "${datarootdir}/grub/grub-mkconfig_lib"

# Use standard GRUB_DISTRIBUTOR logic
if [ "x${GRUB_DISTRIBUTOR}" = "x" ] ; then
  OS=GNU/Linux
else
  case ${GRUB_DISTRIBUTOR} in
    Ubuntu*)
        OS="${GRUB_DISTRIBUTOR}"
        ;;
    *)
        OS="${GRUB_DISTRIBUTOR} GNU/Linux"
        ;;
  esac
fi

logger -t "grub-zfs-force" -p user.info "Using OS title: ${OS}"

# Generate CSS class from distributor
CLASS="--class $(echo ${GRUB_DISTRIBUTOR} | tr 'A-Z' 'a-z' | cut -d' ' -f1 | LC_ALL=C sed 's,[^[:alnum:]_],_,g') --class gnu-linux --class gnu --class os"

# Dynamic kernel detection using GRUB's built-in logic
list="$(for i in /boot/vmlinuz-* /vmlinuz-* /boot/kernel-*; do
    if grub_file_is_not_garbage "$i"; then
        echo -n "$i "
    fi
done)"
prepare_boot_cache="$(prepare_grub_to_access_device ${GRUB_DEVICE_BOOT} | grub_add_tab)"

# Find the default/latest kernel
kernel=""
for k in ${list}; do
    if [ -e "$k" ]; then
        kernel="$k"
        break
    fi
done

if [ -z "$kernel" ]; then
    # Fallback: find any vmlinuz
    kernel="$(ls /boot/vmlinuz-* 2>/dev/null | head -1)"
    logger -t "grub-zfs-force" -p user.warning "Using fallback kernel detection"
fi

if [ -n "$kernel" ]; then
    logger -t "grub-zfs-force" -p user.info "Found kernel: ${kernel}"
    # Extract version and find initrd
    version="$(basename "$kernel" | sed 's/vmlinuz-//')"

    # Look for initrd in multiple locations
    initrd=""
    for i in "/boot/initrd.img-${version}" "/boot/initrd-${version}.img" "/boot/initrd-${version}.gz" "/boot/initrd-${version}"; do
        if [ -e "$i" ]; then
            initrd="$i"
            break
        fi
    done

    if [ -n "$initrd" ]; then
        logger -t "grub-zfs-force" -p user.info "Found initrd: ${initrd}"
        # Build complete kernel command line
        CMDLINE="root=ZFS=\"rpool/root\" ro"
        if [ -n "$GRUB_CMDLINE_LINUX_DEFAULT" ]; then
            CMDLINE="$CMDLINE $GRUB_CMDLINE_LINUX_DEFAULT"
        fi
        if [ -n "$GRUB_CMDLINE_LINUX" ]; then
            CMDLINE="$CMDLINE $GRUB_CMDLINE_LINUX"
        fi
        CMDLINE="$CMDLINE zfs_force=1"

        logger -t "grub-zfs-force" -p user.info "Generated force import menuentry for kernel ${version} with zfs_force=1"
        # Generate menuentry
        echo "menuentry '$(echo "${OS}" | grub_quote)' ${CLASS} \${menuentry_id_option} 'gnulinux-zfs-force-${version}' {"
        echo "\trecordfail"
        echo "\tload_video"
        echo "\tgfxmode \${linux_gfx_mode}"
        echo "\tinsmod gzio"
        echo "\tif [ x\${grub_platform} = xxen ]; then insmod xzio; insmod lzopio; fi"
        echo "\tinsmod part_gpt"
        echo "\tinsmod zfs"

        # Dynamic boot device access
        echo "${prepare_boot_cache}"

        echo "\techo\t'$(gettext_printf "Loading Linux %s ..." "${version}")'"
        echo "\tlinux\t$(make_system_path_relative_to_its_root "${kernel}") ${CMDLINE}"
        echo "\techo\t'$(gettext_printf "Loading initial ramdisk ...")'"
        echo "\tinitrd\t$(make_system_path_relative_to_its_root "${initrd}")"
        echo "}"
    else
        logger -t "grub-zfs-force" -p user.error "No initrd found for kernel ${version}"
    fi
else
    logger -t "grub-zfs-force" -p user.error "No kernel found for force import menuentry generation"
fi
GRUB_FORCE_SCRIPT_EOF

chmod +x /mnt/etc/grub.d/09_zfs_force_import

# Set GRUB_DISTRIBUTOR for the temporary script to use
if ! grep -q "^GRUB_DISTRIBUTOR=" /mnt/etc/default/grub; then
    echo 'GRUB_DISTRIBUTOR="Ubuntu - Force ZFS import first boot"' >> /mnt/etc/default/grub
else
    # Backup original for restoration
    CURRENT_DISTRIBUTOR=$(grep "^GRUB_DISTRIBUTOR=" /mnt/etc/default/grub | cut -d'=' -f2-)
    echo "GRUB_DISTRIBUTOR_BACKUP=$CURRENT_DISTRIBUTOR" > /mnt/etc/default/grub.zfs-backup
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Ubuntu - Force ZFS import first boot"/' /mnt/etc/default/grub
fi

# Create comprehensive cleanup script with validation and reboot
cat > /mnt/usr/local/bin/zfs-firstboot-cleanup << 'CLEANUP_SCRIPT_EOF'
#!/bin/bash
# ZFS First-Boot Cleanup with Validation and Controlled Reboot
# Removes force import configuration after validating successful boot

set -euo pipefail

# Logging functions
log_info() { logger -t "zfs-firstboot-cleanup" -p user.info "$1"; echo "INFO: $1"; }
log_error() { logger -t "zfs-firstboot-cleanup" -p user.err "$1"; echo "ERROR: $1" >&2; }
log_warning() { logger -t "zfs-firstboot-cleanup" -p user.warning "$1"; echo "WARNING: $1"; }

log_info "=== ZFS First-Boot Cleanup Service Starting ==="
log_info "System hostname: $(hostname)"
log_info "Boot time: $(uptime -s)"

# Validate that ZFS imported successfully
log_info "Validating ZFS pool import status..."
if ! zpool status rpool >/dev/null 2>&1; then
    log_error "CRITICAL: rpool not found or not imported - aborting cleanup"
    exit 1
fi

POOL_STATUS=$(zpool status -x rpool)
if [[ "$POOL_STATUS" != "pool 'rpool' is healthy" ]]; then
    log_warning "Pool status: $POOL_STATUS"
    log_warning "Proceeding with cleanup despite pool health issues"
else
    log_info "Pool status: healthy"
fi

# Validate that required filesystems are mounted
log_info "Validating filesystem mounts..."
if ! mountpoint -q /; then
    log_error "CRITICAL: Root filesystem not properly mounted - aborting cleanup"
    exit 1
fi

if ! mountpoint -q /boot/efi; then
    log_warning "EFI partition not mounted - this may indicate boot issues"
else
    log_info "EFI partition properly mounted"
fi

# Validate that we can write to critical locations
log_info "Validating write access to critical directories..."
if ! touch /tmp/zfs-cleanup-test 2>/dev/null; then
    log_error "CRITICAL: Cannot write to /tmp - filesystem may be read-only"
    exit 1
fi
rm -f /tmp/zfs-cleanup-test

log_info "All validation checks passed - proceeding with cleanup"

# Remove temporary force import GRUB script
log_info "Removing temporary force import GRUB script..."

# Remove the temporary GRUB script (this is the key to clean rollback)
if [[ -f /etc/grub.d/09_zfs_force_import ]]; then
    rm -f /etc/grub.d/09_zfs_force_import
    log_info "✓ Temporary GRUB script removed: /etc/grub.d/09_zfs_force_import"
else
    log_warning "Temporary GRUB script not found (may have been removed already)"
fi

# Restore original GRUB_DISTRIBUTOR if we have a backup
if [[ -f /etc/default/grub.zfs-backup ]]; then
    BACKUP_DISTRIBUTOR_LINE=$(grep "^GRUB_DISTRIBUTOR_BACKUP=" /etc/default/grub.zfs-backup || echo "")
    if [[ -n "$BACKUP_DISTRIBUTOR_LINE" ]]; then
        BACKUP_DISTRIBUTOR=$(echo "$BACKUP_DISTRIBUTOR_LINE" | cut -d'=' -f2-)
        sed -i "s/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR=$BACKUP_DISTRIBUTOR/" /etc/default/grub
        log_info "Restored GRUB_DISTRIBUTOR to: $BACKUP_DISTRIBUTOR"
    fi
    rm -f /etc/default/grub.zfs-backup
    log_info "✓ GRUB_DISTRIBUTOR restored from backup"
else
    # Fallback: restore default GRUB_DISTRIBUTOR
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR=`lsb_release -i -s 2> \/dev\/null || echo Debian`/' /etc/default/grub
    log_info "✓ GRUB_DISTRIBUTOR restored to default (backup not found)"
fi

# Update GRUB configuration
log_info "Updating GRUB configuration to remove force import parameters..."
if update-grub >/dev/null 2>&1; then
    log_info "GRUB configuration updated successfully"
else
    log_error "Failed to update GRUB configuration"
fi

# Validate GRUB was updated correctly
if ! grep -q "zfs_force=1" /boot/grub/grub.cfg 2>/dev/null; then
    log_info "Verified: zfs_force=1 parameter removed from GRUB configuration"
else
    log_warning "zfs_force=1 parameter still present in GRUB configuration"
fi

# Sync EFI partitions to ensure changes are applied to both drives
log_info "Syncing EFI partitions after cleanup..."
if [[ -x /usr/local/bin/sync-efi-partitions ]]; then
    if /usr/local/bin/sync-efi-partitions >/dev/null 2>&1; then
        log_info "✓ EFI partition sync completed successfully"
    else
        log_warning "EFI partition sync failed - drives may have inconsistent content"
    fi
else
    log_warning "EFI sync script not found - partitions may be out of sync"
fi

# Disable this service
if systemctl disable zfs-firstboot-cleanup.service >/dev/null 2>&1; then
    log_info "Disabled first-boot cleanup service"
else
    log_warning "Failed to disable first-boot cleanup service"
fi

log_info "First-boot cleanup completed successfully"
log_info "System will reboot in 10 seconds to apply clean configuration"
log_info "Future boots will use standard ZFS import without force flags"

# Controlled reboot with delay for log viewing
log_info "REBOOT: Initiating automatic reboot to complete first-boot process"
sleep 10
systemctl reboot

CLEANUP_SCRIPT_EOF

chmod +x /mnt/usr/local/bin/zfs-firstboot-cleanup

# Create early-boot systemd service for immediate cleanup and reboot
# IMPORTANT: Must be created BEFORE running update-grub so GRUB script can detect it
cat > /mnt/etc/systemd/system/zfs-firstboot-cleanup.service << 'EOF'
[Unit]
Description=ZFS first-boot cleanup - remove force import configuration and reboot
After=zfs-mount.service local-fs.target
Before=multi-user.target graphical.target systemd-user-sessions.service
# Service runs if enabled, auto-disables after successful cleanup
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zfs-firstboot-cleanup
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

# Enable cleanup service NOW so GRUB script can detect it during update-grub
chroot /mnt systemctl enable zfs-firstboot-cleanup.service

log_info "✓ First-boot force import configured"
log_info "✓ Automatic cleanup will remove configuration after successful boot"

show_progress 10 10 "Installation complete!"

# Generate GRUB configuration with zfs_force=1 parameter
log_info "Updating GRUB configuration with force import parameter..."
chroot /mnt update-grub

# Validate that temporary GRUB script was created
log_info "Validating force import configuration..."
if [[ -f /mnt/etc/grub.d/09_zfs_force_import && -x /mnt/etc/grub.d/09_zfs_force_import ]]; then
    log_info "✓ Temporary GRUB script created: /etc/grub.d/09_zfs_force_import"
else
    log_error "CRITICAL: Temporary GRUB script not found or not executable!"
    log_error "Force import setup failed"
    exit 1
fi

# Validate that force import entry appears in GRUB configuration
if chroot /mnt grep -q "zfs_force=1" /boot/grub/grub.cfg; then
    log_info "✓ Force import parameter confirmed in GRUB configuration"
else
    log_error "CRITICAL: zfs_force=1 parameter not found in GRUB configuration!"
    log_error "Temporary script may not be working properly"
    exit 1
fi

# Validate menu title was updated
MENU_TITLE=$(chroot /mnt grep "menuentry.*Force ZFS import" /boot/grub/grub.cfg | head -1 | cut -d"'" -f2 || echo "")
if [[ "$MENU_TITLE" == *"Force ZFS import"* ]]; then
    log_info "✓ Menu title updated: $MENU_TITLE"
else
    log_warning "Custom menu title not found, checking for any force import entry..."
    if chroot /mnt grep -q "gnulinux-zfs-force" /boot/grub/grub.cfg; then
        log_info "✓ Force import entry found in GRUB configuration"
    else
        log_error "No force import entry found in GRUB configuration"
        exit 1
    fi
fi

# Final summary of the simplified force import approach
log_info "📋 Summary: First-boot force import configured via kernel parameter"
log_info "🔄 First boot will show 'Ubuntu - Force ZFS import first boot' and use zfs_force=1"

# Use the sync script to ensure GRUB is installed on all ZFS mirror drives
log_info "Installing GRUB to all ZFS mirror drives for redundancy..."
chroot /mnt /usr/local/bin/sync-grub-to-mirror-drives
log_info "✓ GRUB updated and installed on all ZFS mirror drives with first-boot configuration"

# The comprehensive cleanup script and service were already created and enabled above
log_info "✓ First boot configured with force import and automatic cleanup"
log_info "✓ Pool will import reliably with zfs_force=1 parameter"
log_info "✓ Cleanup service will remove force import after successful first boot"

# ================================================================
# MANUAL RECOVERY INSTRUCTIONS
# ================================================================
# Document manual recovery steps in case the automatic force import fails

log_header "First Boot Recovery Information"
echo ""
echo -e "${YELLOW}${BOLD}If you encounter boot issues on first boot:${NC}"
echo -e "${CYAN}1. From initramfs prompt, run these commands:${NC}"
echo -e "   ${GREEN}zpool import -f rpool${NC}"
echo -e "   ${GREEN}# Single-pool architecture - only rpool import needed${NC}"
echo -e "   ${GREEN}exit${NC}"
echo ""
echo -e "${CYAN}2. After successful boot, the system will automatically remove${NC}"
echo -e "   ${CYAN}the force import configuration for future boots.${NC}"
echo ""
echo -e "${CYAN}3. If automatic cleanup fails, manually run the cleanup script:${NC}"
echo -e "   ${GREEN}sudo /usr/local/bin/zfs-firstboot-cleanup${NC}"
echo ""

show_progress 10 10 "Installation complete!"

# Final summary of the simplified kernel parameter approach
log_info "📋 Summary: First-boot force import configured via GRUB kernel parameter"
log_info "🔄 First boot will show 'Ubuntu - Force ZFS import first boot' with zfs_force=1"

# Mark installation as completed
INSTALL_STATE="completed"

log_header "🎉 Installation Successfully Completed! 🎉"

echo ""
echo -e "${GREEN}${BOLD}✅ Ubuntu 24.04 with ZFS mirror root installed successfully!${NC}"
echo ""
echo -e "${BOLD}System Configuration:${NC}"
echo -e "  • Hostname: ${GREEN}${HOSTNAME}${NC}"
echo -e "  • Admin User: ${GREEN}${ADMIN_USER}${NC}"
echo -e "  • ZFS Pool: ${GREEN}rpool (single pool with GRUB2 compatibility)${NC}"
echo -e "  • Disk 1: ${GREEN}${DISK1} (${DISK1_NAME})${NC}"
echo -e "  • Disk 2: ${GREEN}${DISK2} (${DISK2_NAME})${NC}"
echo -e "  • EFI Boot: ${GREEN}UUID-based redundant mounting${NC}"
echo -e "  • EFI Volume ID: ${GREEN}${EFI_VOLUME_ID}${NC}"
echo -e "  • ZFS Services: ${GREEN}Ubuntu built-in (no custom units)${NC}"

if [[ "${USE_SERIAL_CONSOLE:-false}" == "true" ]]; then
    echo -e "  • Serial Console: ${GREEN}${SERIAL_PORT:-ttyS1} @ ${SERIAL_SPEED:-115200} baud${NC}"
else
    echo -e "  • Console: ${YELLOW}Local only${NC}"
fi

echo ""
# Prepare log file name for copying to installed system
INSTALLED_LOG_NAME="zfs-mirror-setup_${VERSION}_$(date +%Y%m%dT%H%M%S).log"

echo -en "${BOLD}Unmount and prepare for reboot? (Y/n): ${NC}"
read -r response

if [[ ! "${response}" =~ ^[Nn]$ ]]; then
    log_info "Performing clean shutdown sequence..."

    # Copy installation log to the installed system for future reference
    cp "${LOG_FILE}" "/mnt/var/log/${INSTALLED_LOG_NAME}"
    log_info "Installation log copied to: /var/log/${INSTALLED_LOG_NAME}"

    sync
    fuser -km /mnt 2>/dev/null || true
    sleep 2
        
    # Restore output to original file descriptors
    exec 1>&3 2>&4
        
    # Unmount chroot bind mounts
    umount -l /mnt/dev /mnt/proc /mnt/sys /mnt/run 2>/dev/null || true
    sleep 2
        
    # Unmount any remaining mounts
    umount -lR /mnt 2>/dev/null || true
        
    # Export pools cleanly
    # Single-pool architecture - only rpool exists
    zpool export rpool 2>/dev/null || zpool export -f rpool 2>/dev/null || true

    echo ""
    echo -e "${GREEN}${BOLD}✅ System ready for reboot!${NC}"
    echo ""
    echo -e "${YELLOW}${BOLD}Next Steps:${NC}"
    echo -e "${YELLOW}1. Remove installation USB${NC}"
    echo -e "${YELLOW}2. Type: reboot${NC}"
    echo -e "${YELLOW}3. System boots from either drive${NC}"
    echo ""
    echo -e "${BOLD}Login: ${GREEN}${ADMIN_USER}${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}Key Features:${NC}"
    echo -e "  ✓ True EFI redundancy with UUID-based mounting"
    echo -e "  ✓ Ubuntu's built-in ZFS services (no custom units)"
    echo -e "  ✓ Automatic first-boot force import with cleanup"
    echo -e "  ✓ Both drives fully bootable and synchronized"
    echo -e "  ✓ Comprehensive test and recovery tools included"
    echo ""
    echo -e "${YELLOW}${BOLD}First Boot:${NC}"
    echo -e "  • Force import flag will be automatically removed"
    echo -e "  • Manual cleanup (if needed): ${GREEN}sudo systemctl disable zfs-firstboot-cleanup.service && sudo sed -i 's/ zfs_force=1//g' /etc/default/grub && sudo update-grub${NC}"
    echo ""
    echo -e "${YELLOW}${BOLD}Post-Install Recommendations:${NC}"
    echo -e "${GREEN}1. Test the installation:${NC}"
    echo -e "   ${GREEN}sudo /usr/local/bin/test-zfs-mirror${NC}"
    echo ""
    echo -e "${GREEN}2. Review recovery procedures:${NC}"
    echo -e "   ${GREEN}sudo cat /root/ZFS-RECOVERY-GUIDE.txt${NC}"
    echo ""
    echo -e "${GREEN}3. Test drive failure resilience:${NC}"
    echo -e "   ${GREEN}# See commands in test script output${NC}"
    echo ""
    echo -e "${GREEN}4. Verify EFI sync is working:${NC}"
    echo -e "   ${GREEN}sudo /usr/local/bin/sync-efi-partitions${NC}"
    echo ""
    echo -e "${GREEN}5. Schedule regular maintenance:${NC}"
    echo -e "   ${GREEN}# Monthly scrubs and weekly trims are pre-configured${NC}"
    echo ""
    echo -e "${YELLOW}${BOLD}Utility Scripts Created:${NC}"
    echo -e "  • ${GREEN}/usr/local/bin/test-zfs-mirror${NC} - Test system functionality"
    echo -e "  • ${GREEN}/usr/local/bin/sync-efi-partitions${NC} - Sync EFI between drives"
    echo -e "  • ${GREEN}/usr/local/bin/sync-grub-to-mirror-drives${NC} - Install GRUB to all drives"
    echo -e "  • ${GREEN}/usr/local/bin/replace-drive-in-zfs-boot-mirror${NC} - Replace failed drives"
    echo -e "  • Manual cleanup commands documented in recovery guide (rarely needed)"
else
    echo -e "${YELLOW}System remains mounted at /mnt${NC}"
fi

echo ""
echo -e "${BOLD}Installation logs:${NC}"
echo -e "  Live USB: ${GREEN}${LOG_FILE}${NC}"
echo -e "  Installed system: ${GREEN}/var/log/${INSTALLED_LOG_NAME}${NC}"
echo -e "${BOLD}Original repository: ${GREEN}${ORIGINAL_REPO}${NC}"
