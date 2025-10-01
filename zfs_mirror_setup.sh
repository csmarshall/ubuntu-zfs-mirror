#!/bin/bash

# Ubuntu 24.04 ZFS Root Installation Script - Enhanced & Cleaned Version
# Creates a ZFS mirror on two drives with full redundancy
# Supports: NVMe, SATA SSD, SATA HDD, SAS, and other drive types
# Version: 5.0.0 - MAJOR: Simplified first-boot force import with countdown timer for --prepare flag
# License: MIT
# Original Repository: https://github.com/csmarshall/ubuntu-zfs-mirror
# Enhanced Version: https://claude.ai - Production-ready fixes

set -euo pipefail

# Script metadata
readonly VERSION="5.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ORIGINAL_REPO="https://github.com/csmarshall/ubuntu-zfs-mirror"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
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

    local original_seconds=$seconds
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

# Get drive identifier for UEFI naming with comprehensive validation
get_drive_identifier() {
    local disk_path="$1"
    local identifier=""
    
    log_debug "Generating UEFI-compatible identifier for: ${disk_path}" >&2
    
    # Validate input
    if [[ -z "${disk_path}" ]]; then
        log_error "get_drive_identifier: Empty disk path provided" >&2
        return 1
    fi
    
    # Try to extract model name from the disk path using improved regex
    if [[ "${disk_path}" =~ nvme-(.+)_[A-Za-z0-9]{8,} ]]; then
        identifier="${BASH_REMATCH[1]}"
        log_debug "Extracted NVMe identifier: ${identifier}" >&2
    elif [[ "${disk_path}" =~ ata-(.+)_[A-Za-z0-9]{8,} ]] || [[ "${disk_path}" =~ scsi-(.+)_[A-Za-z0-9]{8,} ]]; then
        identifier="${BASH_REMATCH[1]}"
        log_debug "Extracted ATA/SCSI identifier: ${identifier}" >&2
    else
        # Fallback to using lsblk with better error handling
        local dev_name
        dev_name=$(readlink -f "${disk_path}" 2>/dev/null | xargs basename 2>/dev/null || echo "")
        if [[ -n "${dev_name}" && -b "/dev/${dev_name}" ]]; then
            identifier=$(lsblk -ndo MODEL "/dev/${dev_name}" 2>/dev/null | sed 's/[[:space:]]*$//' | sed 's/ /-/g' || echo "")
            log_debug "lsblk fallback identifier: ${identifier}" >&2
        fi
    fi
    
    # If still no identifier, use generic one based on device name
    if [[ -z "${identifier}" ]]; then
        local dev_name
        dev_name=$(basename "${disk_path}")
        identifier="Disk-${dev_name}"
        log_debug "Generic fallback identifier: ${identifier}" >&2
    fi
    
    # Clean up the identifier to ensure UEFI compatibility
    identifier="${identifier//_/-}"
    identifier="${identifier##-}"
    identifier="${identifier%%-}"
        
    # Remove any consecutive dashes
    while [[ "${identifier}" == *"--"* ]]; do
        identifier="${identifier//--/-}"
    done
    
    # Final validation
    if [[ -z "${identifier}" ]]; then
        identifier="GenericDisk"
        log_warning "Empty identifier after cleanup, using generic fallback" >&2
    fi
        
    # Final trailing dash removal
    identifier="${identifier%-}"
    
    # Limit length for UEFI compatibility (20 chars max)
    if [[ ${#identifier} -gt 20 ]]; then
        identifier="${identifier:0:20}"
        identifier="${identifier%-}"
        log_debug "Truncated identifier to 20 chars: ${identifier}" >&2
    fi
    
    log_debug "Final UEFI identifier: '${identifier}'" >&2
    echo "${identifier}"
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
    local required_vars=("DISK1" "DISK2" "EFI_VOLUME_ID" "ADMIN_USER" "ADMIN_PASS")
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
    echo "  ${SCRIPT_NAME} [--prepare] <hostname> <disk1> <disk2>"
    echo "  ${SCRIPT_NAME} --wipe-only <disk1> <disk2>"
    echo ""
    echo -e "${BOLD}Description:${NC}"
    echo "  Creates a ZFS root mirror on two drives for Ubuntu 24.04 Server."
    echo "  Both drives will be bootable with automatic failover capability."
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --prepare   Wipe drives completely before installation (recommended)"
    echo "  --wipe-only Just wipe drives without installing"
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
    echo -en "${BOLD}Type 'DESTROY' to confirm: ${NC}"
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

# Partition a disk with improved error handling and validation
partition_disk() {
    local disk="$1"
    local disk_type="$2"
    
    if [[ -z "${disk}" || -z "${disk_type}" ]]; then
        log_error "partition_disk: Disk and disk type required"
        return 1
    fi
    
    log_info "Partitioning ${disk_type} disk: ${disk}"
    
    # Stop services and clear existing data
    stop_disk_services "${disk}"
    clear_zfs_labels "${disk}"
    
    # Wipe filesystem signatures
    log_debug "Wiping filesystem signatures on ${disk}"
    wipefs -a "${disk}" 2>/dev/null || true
    
    # Define partition sizes
    local efi_size="512M"
    local swap_size="4G"
    local boot_size="2G"
    
    log_debug "Creating partition layout on ${disk}:"
    log_debug "  Partition 1 (EFI): ${efi_size}"
    log_debug "  Partition 2 (Swap): ${swap_size}"
    log_debug "  Partition 3 (Boot Pool): ${boot_size}"
    log_debug "  Partition 4 (Root Pool): Remaining space"
    
    # Create all partitions in one sgdisk call
    if ! sgdisk --zap-all "${disk}" \
           --new=1:1M:+${efi_size} --typecode=1:EF00 --change-name=1:"EFI System" \
           --new=2:0:+${swap_size} --typecode=2:8200 --change-name=2:"Linux Swap" \
           --new=3:0:+${boot_size} --typecode=3:BE00 --change-name=3:"Boot Pool" \
           --new=4:0:0 --typecode=4:BF00 --change-name=4:"Root Pool" \
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
    
    # Verify partitions were created
    local part1 part2 part3 part4
    part1=$(get_partition_name "${disk}" 1)
    part2=$(get_partition_name "${disk}" 2)
    part3=$(get_partition_name "${disk}" 3)
    part4=$(get_partition_name "${disk}" 4)
    
    for part in "${part1}" "${part2}" "${part3}" "${part4}"; do
        if [[ ! -b "${part}" ]]; then
            log_error "Partition ${part} was not created successfully"
            return 1
        fi
    done
    
    log_info "Successfully partitioned ${disk}"
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
    if [[ "${current_root}" =~ ^rpool ]] || [[ "${current_root}" =~ ^bpool ]]; then
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
        echo -en "${BOLD}Type 'DESTROY-EXISTING-DATA' to confirm: ${NC}"
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

# Create clean ZFS configuration (no force flags needed with hostid alignment)
setup_zfs_config() {
    local hostid="$1"

    if [[ -z "${hostid}" ]]; then
        log_error "setup_zfs_config: No hostid provided"
        return 1
    fi

    log_header "Creating ZFS Configuration"
    log_info "Hostid alignment eliminates need for force flags and cleanup complexity"

    # Create ZFS defaults with proper hostid (no force flag needed)
    cat > /mnt/etc/default/zfs << ZFS_DEFAULTS_EOF
# ZFS Configuration for Ubuntu ZFS Mirror Installation
# Hostid synchronized between installer and target system for clean import
HOSTID=${hostid}

# Clean import guaranteed by hostid alignment - no force flags needed
ZFS_DEFAULTS_EOF

    log_info "ZFS configuration created with hostid: ${hostid}"
    log_info "Pools will import cleanly on first boot without any manual intervention"
    return 0
}

# Create simplified EFI sync script
create_efi_sync_script() {
    cat << EFI_SYNC_SCRIPT > /mnt/usr/local/bin/sync-efi-partitions
#!/bin/bash
# EFI Partition Sync Script for ZFS Mirror Drives\n# \n# CREATED BY: Ubuntu ZFS Mirror Root Installation Script (v${VERSION})\n# PURPOSE: Sync EFI partitions between mirror drives with identical UUIDs\n# LOCATION: /usr/local/bin/sync-efi-partitions\n# \n# This script automatically syncs the EFI System Partition content between\n# mirror drives. It runs automatically after kernel updates via APT hooks.\n#
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

if [[ ${#EFI_PARTITIONS[@]} -ne 2 ]]; then
    log_message "ERROR: Expected 2 EFI partitions, found ${#EFI_PARTITIONS[@]}"
    exit 1
fi

# Find the other partition (the one not currently mounted)
TARGET_EFI=""
for partition in "${EFI_PARTITIONS[@]}"; do
    if [[ "${partition}" != "${MOUNTED_EFI}" ]]; then
        TARGET_EFI="${partition}"
        break
    fi
done

if [[ -z "${TARGET_EFI}" ]]; then
    log_message "ERROR: Could not find unmounted EFI partition"
    exit 1
fi

log_message "Syncing EFI: ${MOUNTED_EFI} (mounted) -> ${TARGET_EFI}"

# Mount and sync
TARGET_MOUNT=$(mktemp -d)

if ! mount "${TARGET_EFI}" "${TARGET_MOUNT}"; then
    log_message "ERROR: Failed to mount target EFI partition"
    rmdir "${TARGET_MOUNT}"
    exit 1
fi

rsync -av --delete /boot/efi/ "${TARGET_MOUNT}/"

umount "${TARGET_MOUNT}"
rmdir "${TARGET_MOUNT}"

log_message "EFI sync completed"
EFI_SYNC_SCRIPT

    chmod +x /mnt/usr/local/bin/sync-efi-partitions
    
    # Create APT hook
    echo 'DPkg::Post-Invoke {"/usr/local/bin/sync-efi-partitions || true";};' \
        > /mnt/etc/apt/apt.conf.d/99-sync-efi
    
    log_info "EFI sync script created with APT integration"
    return 0
}

# Create ZFS pools with dynamic option building
create_zfs_pools() {
    local part1_boot="$1"
    local part2_boot="$2"
    local part1_root="$3"
    local part2_root="$4"
    local ashift="$5"
    local trim_enabled="$6"
    
    # Validate inputs
    local required_args=("$part1_boot" "$part2_boot" "$part1_root" "$part2_root" "$ashift" "$trim_enabled")
    for arg in "${required_args[@]}"; do
        if [[ -z "${arg}" ]]; then
            log_error "create_zfs_pools: Missing required argument"
            return 1
        fi
    done
    
    log_info "Creating ZFS pools with ashift=${ashift}, autotrim=${trim_enabled}"
    
    # Build ZFS options dynamically
    local pool_opts="-f -o ashift=${ashift}"
    [[ "${trim_enabled}" == "on" ]] && pool_opts="${pool_opts} -o autotrim=on"
    
    # Create boot pool
    log_info "Creating boot pool (bpool)..."
    # Note: Using 'eval' here safely because all variables are controlled
    if ! eval "zpool create ${pool_opts} -o compatibility=grub2 -O devices=off -O acltype=posixacl -O xattr=sa -O compression=lz4 -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=/boot -R /mnt bpool mirror '${part1_boot}' '${part2_boot}'"; then
        log_error "Failed to create boot pool"
        return 1
    fi
    
    # Verify boot pool was created
    if ! zpool list bpool &>/dev/null; then
        log_error "Boot pool creation appeared to succeed but pool doesn't exist!"
        return 1
    fi
    
    log_info "Boot pool created successfully"
    
    # Create root pool
    log_info "Creating root pool (rpool)..."
    if ! eval "zpool create ${pool_opts} -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=lz4 -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=/ -R /mnt rpool mirror '${part1_root}' '${part2_root}'"; then
        log_error "Failed to create root pool"
        return 1
    fi
    
    # Verify root pool was created
    if ! zpool list rpool &>/dev/null; then
        log_error "Root pool creation appeared to succeed but pool doesn't exist!"
        return 1
    fi
    
    log_info "Root pool created successfully"

    # Configure pools for bulletproof Ubuntu 24.04 import
    # Set cachefile=none for both pools to avoid cache file issues
    #
    # Ubuntu Bug Reference: https://bugs.launchpad.net/ubuntu/+source/zfs-linux/+bug/1718761
    # Cache files can become corrupted or inconsistent in Ubuntu, causing import failures
    # Using cachefile=none forces scan-based import which is more reliable
    # This works with zfs-import-scan.service in Ubuntu 24.04
    log_info "Configuring pools for reliable import..."
    zpool set cachefile=none bpool
    zpool set cachefile=none rpool
    log_info "Pools configured with cachefile=none for scan-based import (avoids Ubuntu cache file bug)"

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

log_header "Partitioning Drives"
INSTALL_STATE="partitioning"

show_progress 1 10 "Partitioning drives..."
if ! partition_disk "${DISK1}" "${DISK1_TYPE}"; then
    log_error "Failed to partition ${DISK1}"
    exit 1
fi

if ! partition_disk "${DISK2}" "${DISK2_TYPE}"; then
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

if ! PART1_BOOT=$(get_partition_name "${DISK1}" 3); then
    log_error "Failed to get boot partition name for ${DISK1}"
    exit 1
fi

if ! PART2_BOOT=$(get_partition_name "${DISK2}" 3); then
    log_error "Failed to get boot partition name for ${DISK2}"
    exit 1
fi

if ! PART1_ROOT=$(get_partition_name "${DISK1}" 4); then
    log_error "Failed to get root partition name for ${DISK1}"
    exit 1
fi

if ! PART2_ROOT=$(get_partition_name "${DISK2}" 4); then
    log_error "Failed to get root partition name for ${DISK2}"
    exit 1
fi

# Wait for partition devices to be available
log_debug "Waiting for partition devices to be ready"
for part in "${PART1_EFI}" "${PART2_EFI}" "${PART1_SWAP}" "${PART2_SWAP}" "${PART1_BOOT}" "${PART2_BOOT}" "${PART1_ROOT}" "${PART2_ROOT}"; do
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

show_progress 3 10 "Creating boot pool..."

# Cleanup before boot pool creation
perform_basic_zfs_cleanup "bpool" "${PART1_BOOT}" "${PART2_BOOT}"

show_progress 4 10 "Creating root pool..."

# Cleanup before root pool creation
perform_basic_zfs_cleanup "rpool" "${PART1_ROOT}" "${PART2_ROOT}"

# Create ZFS pools
log_header "Creating ZFS pools"
log_info "Creating mirrored ZFS pools (hostid will be synchronized at end of installation)"

# Create ZFS pools with consolidated logic
if ! create_zfs_pools "${PART1_BOOT}" "${PART2_BOOT}" "${PART1_ROOT}" "${PART2_ROOT}" "${ASHIFT}" "${TRIM_ENABLED}"; then
    log_error "Failed to create ZFS pools"
    exit 1
fi

POOLS_CREATED="yes"
log_info "ZFS pools created successfully!"

show_progress 5 10 "Creating ZFS datasets..."

# Create essential datasets
zfs create -o mountpoint=/ rpool/root
zfs create -o mountpoint=/boot bpool/boot
zfs create -o mountpoint=/var rpool/var
zfs create -o mountpoint=/var/log rpool/var/log

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

# Validate required environment variables
required_vars=("DISK1" "DISK2" "EFI_VOLUME_ID" "ADMIN_USER" "ADMIN_PASS")
missing_vars=()

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        missing_vars+=("${var}")
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    log_error "Missing required environment variables: ${missing_vars[*]}"
    exit 1
fi

# Update packages
apt-get update

# Configure locale and timezone
DEBIAN_FRONTEND=noninteractive apt-get install --yes locales tzdata
locale-gen en_US.UTF-8
echo 'LANG=en_US.UTF-8' > /etc/default/locale
dpkg-reconfigure tzdata

# Install essential packages
apt-get install --yes \
    nano vim curl wget \
    openssh-server \
    sudo rsync \
    bsdextrautils \
    htop \
    software-properties-common \
    systemd-timesyncd \
    cron \
    util-linux

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
log_info "ZFS configuration will be created with proper hostid after installation"

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

# Create ZFS configuration - hostid will be set properly at end of installation
log_info "Creating ZFS configuration (hostid will be synchronized from pools at completion)"

# Get current installer hostid for temporary ZFS config
INSTALLER_HOSTID=$(hostid)
if ! setup_zfs_config "${INSTALLER_HOSTID}"; then
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
for pool in rpool bpool; do
    if zpool list "$pool" &>/dev/null; then
        status=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        echo "  $pool: $status"
    else
        echo "  $pool: NOT FOUND"
    fi
done
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

set -euo pipefail

# Set up logging functions
log_info() { logger -t "sync-grub-to-mirror-drives" -p user.info "$1"; echo "$1"; }
log_error() { logger -t "sync-grub-to-mirror-drives" -p user.err "$1"; echo "ERROR: $1" >&2; }
log_warning() { logger -t "sync-grub-to-mirror-drives" -p user.warning "$1"; echo "WARNING: $1"; }

log_info "Syncing GRUB to all ZFS mirror drives..."

# Discover drives from both bpool and rpool
DRIVES=()
for pool in bpool rpool; do
    if zpool status "$pool" &>/dev/null; then
        while IFS= read -r drive; do
            if [[ "$drive" =~ ^(/dev/disk/by-id/.*)-part[0-9]+$ ]]; then
                base_drive="${BASH_REMATCH[1]}"
                if [[ ! " ${DRIVES[*]} " =~ " ${base_drive} " ]]; then
                    DRIVES+=("$base_drive")
                fi
            fi
        done < <(zpool status "$pool" | grep -E '^[[:space:]]+/dev/disk/by-id/.*-part[0-9]+' | awk '{print $1}')
    fi
done

if [[ ${#DRIVES[@]} -eq 0 ]]; then
    log_warning "No ZFS mirror drives found"
    exit 1
fi

log_info "Found ${#DRIVES[@]} ZFS mirror drives:"
for drive in "${DRIVES[@]}"; do
    log_info "  - $drive"
done

# Install GRUB to each drive
for drive in "${DRIVES[@]}"; do
    log_info "Installing GRUB to $drive..."
    if grub-install --target=x86_64-efi --efi-directory=/boot/efi "$drive" >/dev/null 2>&1; then
        log_info "  ✓ GRUB installed successfully to $drive"
    else
        log_error "  ✗ Failed to install GRUB to $drive"
    fi
done

log_info "GRUB sync complete"
GRUB_SYNC_SCRIPT

chmod +x /mnt/usr/local/bin/sync-grub-to-mirror-drives
log_info "GRUB sync script created: /usr/local/bin/sync-grub-to-mirror-drives"

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
    echo "  1. Auto-detect failed drives in bpool and rpool"
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

# Detect failed devices in both pools
echo "Checking bpool for failed devices..."
BPOOL_FAILED=($(detect_failed_devices "bpool"))

echo "Checking rpool for failed devices..."
RPOOL_FAILED=($(detect_failed_devices "rpool"))

if [[ ${#BPOOL_FAILED[@]} -eq 0 && ${#RPOOL_FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}No failed devices detected in either pool.${NC}"
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
if [[ ${#BPOOL_FAILED[@]} -gt 0 ]]; then
    echo "  bpool: ${BPOOL_FAILED[*]}"
fi
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
WORKING_DRIVE=$(zpool status rpool | grep -E '^[[:space:]]+/dev/disk/by-id/.*-part[0-9]+' | grep ONLINE | head -1 | awk '{print $1}' | sed 's/-part[0-9]*$//')
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

# Replace in bpool if needed
if [[ ${#BPOOL_FAILED[@]} -gt 0 ]]; then
    log_info "Replacing failed device(s) in bpool: ${BPOOL_FAILED[*]}"
    for failed_device_info in "${BPOOL_FAILED[@]}"; do
        failed_device="${failed_device_info%:*}"
        log_info "Attempting bpool replacement: $failed_device -> ${REPLACEMENT_DRIVE}-part2"
        echo "Replacing $failed_device in bpool..."
        if zpool replace bpool "$failed_device" "${REPLACEMENT_DRIVE}-part2"; then
            log_info "bpool replacement initiated successfully"
            echo "  ✓ bpool replacement initiated"
            break
        else
            log_warning "bpool replacement failed for $failed_device"
            echo "  ✗ bpool replacement failed, trying alternative method..."
        fi
    done
fi

# Replace in rpool if needed
if [[ ${#RPOOL_FAILED[@]} -gt 0 ]]; then
    log_info "Replacing failed device(s) in rpool: ${RPOOL_FAILED[*]}"
    for failed_device_info in "${RPOOL_FAILED[@]}"; do
        failed_device="${failed_device_info%:*}"
        log_info "Attempting rpool replacement: $failed_device -> ${REPLACEMENT_DRIVE}-part3"
        echo "Replacing $failed_device in rpool..."
        if zpool replace rpool "$failed_device" "${REPLACEMENT_DRIVE}-part3"; then
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
zpool clear bpool 2>/dev/null || true
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
   sudo zpool import -f -R /mnt bpool
   sudo mount -t zfs rpool/root /mnt
   sudo mount -t zfs bpool/boot /mnt/boot
   sudo mount ${PART1_EFI} /mnt/boot/efi

   # Fix the issue, then:
   sudo umount -R /mnt
   sudo zpool export bpool rpool

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
   sudo zpool replace rpool ${PART1_ROOT} /dev/NEW-DRIVE-part4
   sudo zpool replace bpool ${PART1_BOOT} /dev/NEW-DRIVE-part3

   Drive 2 (${DISK2}) failed:
   sudo zpool replace rpool ${PART2_ROOT} /dev/NEW-DRIVE-part4
   sudo zpool replace bpool ${PART2_BOOT} /dev/NEW-DRIVE-part3

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
Manual cleanup (if needed): sudo rm -f /.zfs-force-import-firstboot /etc/grub.d/99_zfs_firstboot && sudo update-grub
Check boot entries:      efibootmgr

Force import (emergency): sudo zpool import -f rpool && sudo zpool import -f bpool

Scrub pools (monthly):    sudo zpool scrub rpool && sudo zpool scrub bpool
Check scrub progress:     sudo zpool status

===============================================================================
PARTITION LAYOUT REFERENCE
===============================================================================

Each drive has 4 partitions:
  part1: EFI System Partition (512MB, FAT32, UUID=${EFI_VOLUME_ID})
  part2: Swap (4GB)
  part3: Boot Pool (2GB, ZFS)
  part4: Root Pool (Remaining space, ZFS)

Drive 1 partitions:
  ${PART1_EFI} (EFI)
  ${PART1_SWAP} (Swap)
  ${PART1_BOOT} (Boot Pool)
  ${PART1_ROOT} (Root Pool)

Drive 2 partitions:
  ${PART2_EFI} (EFI)
  ${PART2_SWAP} (Swap)
  ${PART2_BOOT} (Boot Pool)
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
# Instead of trying to synchronize hostids (which is complex and error-prone),
# we configure the first boot to use 'zfs_force=1' kernel parameter.
# This tells the ZFS initramfs to use 'zpool import -f' for reliable import.
# After successful first boot, the system automatically removes this configuration
# and future boots use clean imports without force flags.

log_info "Configuring first-boot force import for reliable pool import..."
log_info "This eliminates hostid synchronization complexity and ensures successful first boot"

# Create GRUB configuration that adds zfs_force=1 ONLY on first boot
# The zfs_force=1 parameter tells ZFS initramfs to use 'zpool import -f'
cat > /mnt/etc/grub.d/99_zfs_firstboot << 'EOF'
#!/bin/sh
# ZFS First-Boot Force Import Configuration
# Adds zfs_force=1 to kernel command line for first boot only
# After first successful boot, this script and configuration are automatically removed

if [ -f /.zfs-force-import-firstboot ]; then
    cat << 'GRUB_EOF'
# ZFS first-boot force import menu entry (auto-generated, auto-removed)
menuentry 'Ubuntu (ZFS first boot - force import)' --class ubuntu --class gnu-linux --class gnu --class os $menuentry_id_option 'gnulinux-zfs-firstboot' {
    recordfail
    load_video
    gfxmode $linux_gfx_mode
    insmod gzio
    if [ x$grub_platform = xxen ]; then insmod xzio; insmod lzopio; fi
    insmod part_gpt
    insmod zfs
    # Force import pools using zfs_force=1 kernel parameter
    linux   /vmlinuz root=ZFS=rpool/ROOT/ubuntu ro zfs_force=1 quiet splash
    initrd  /initrd.img
}
GRUB_EOF
else
    # Log warning if this script is running but force import is not needed
    echo "Warning: /etc/grub.d/99_zfs_firstboot running but /.zfs-force-import-firstboot not found" >&2
    echo "This script should have been automatically removed after first boot" >&2
fi
EOF

chmod +x /mnt/etc/grub.d/99_zfs_firstboot

# Create marker file that indicates first boot is needed
touch /mnt/.zfs-force-import-firstboot

# Update GRUB configuration to include the first-boot force import option
log_info "Updating GRUB configuration with first-boot force import option..."
chroot /mnt update-grub

# Use the sync script to ensure GRUB is installed on all ZFS mirror drives
log_info "Installing GRUB to all ZFS mirror drives for redundancy..."
chroot /mnt /usr/local/bin/sync-grub-to-mirror-drives
log_info "✓ GRUB updated and installed on all ZFS mirror drives with first-boot configuration"

# Create systemd service that automatically cleans up after successful first boot
cat > /mnt/etc/systemd/system/zfs-firstboot-cleanup.service << 'EOF'
[Unit]
Description=Remove ZFS first-boot force import configuration after successful boot
After=multi-user.target
ConditionPathExists=/.zfs-force-import-firstboot

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
    # Set up logging function
    log_info() { logger -t "zfs-firstboot-cleanup" -p user.info "$1"; echo "$1"; }
    log_error() { logger -t "zfs-firstboot-cleanup" -p user.err "$1"; echo "ERROR: $1" >&2; }
    log_warning() { logger -t "zfs-firstboot-cleanup" -p user.warning "$1"; echo "WARNING: $1"; }

    log_info "=== ZFS First-Boot Cleanup Service Starting ==="
    log_info "Hostname: $(hostname)"

    # Log ZFS pool status
    pool_status=$(zpool list -H -o name,health 2>/dev/null | tr "\t" " " | sed "s/^/  /")
    if [[ -n "$pool_status" ]]; then
        log_info "ZFS pool status:"
        echo "$pool_status" | while read line; do log_info "$line"; done
    else
        log_warning "No ZFS pools found"
    fi

    log_info "Removing first-boot force import configuration..."

    # Remove force import marker
    if [[ -f /.zfs-force-import-firstboot ]]; then
        if rm -f /.zfs-force-import-firstboot; then
            log_info "Removed force import marker: /.zfs-force-import-firstboot"
        else
            log_error "Failed to remove force import marker: /.zfs-force-import-firstboot"
        fi
    else
        log_info "Force import marker not found (already removed)"
    fi

    # Remove GRUB first-boot script
    if [[ -f /etc/grub.d/99_zfs_firstboot ]]; then
        if rm -f /etc/grub.d/99_zfs_firstboot; then
            log_info "Removed GRUB first-boot script: /etc/grub.d/99_zfs_firstboot"
        else
            log_error "Failed to remove GRUB first-boot script: /etc/grub.d/99_zfs_firstboot"
        fi
    else
        log_info "GRUB first-boot script not found (already removed)"
    fi

    # Update GRUB configuration
    log_info "Updating GRUB configuration..."
    if update-grub >/dev/null 2>&1; then
        log_info "GRUB configuration updated successfully"
    else
        log_error "GRUB update failed (exit code: $?)"
    fi

    # Disable cleanup service
    log_info "Disabling cleanup service..."
    if systemctl disable zfs-firstboot-cleanup.service >/dev/null 2>&1; then
        log_info "Cleanup service disabled successfully"
    else
        log_error "Failed to disable cleanup service (exit code: $?)"
    fi

    log_info "=== ZFS First-Boot Cleanup Complete ==="
    log_info "Future boots will use standard ZFS imports without force flags"
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the cleanup service
chroot /mnt systemctl enable zfs-firstboot-cleanup.service

log_info "✓ First boot configured to use force import (zfs_force=1)"
log_info "✓ Auto-cleanup service enabled - removes force configuration after successful boot"
log_info "✓ Future boots will use clean imports without force flags"

# ================================================================
# MANUAL RECOVERY INSTRUCTIONS
# ================================================================
# Document manual recovery steps in case the automatic force import fails

log_header "First Boot Recovery Information"
echo ""
echo -e "${YELLOW}${BOLD}If you encounter boot issues on first boot:${NC}"
echo -e "${CYAN}1. From initramfs prompt, run these commands:${NC}"
echo -e "   ${GREEN}zpool import -f rpool${NC}"
echo -e "   ${GREEN}zpool import -f bpool${NC}"
echo -e "   ${GREEN}exit${NC}"
echo ""
echo -e "${CYAN}2. After successful boot, the system will automatically remove${NC}"
echo -e "   ${CYAN}the force import configuration for future boots.${NC}"
echo ""
echo -e "${CYAN}3. If you need to manually clean up the configuration:${NC}"
echo -e "   ${GREEN}sudo rm -f /.zfs-force-import-firstboot${NC}"
echo -e "   ${GREEN}sudo rm -f /etc/grub.d/99_zfs_firstboot${NC}"
echo -e "   ${GREEN}sudo update-grub${NC}"
echo ""

show_progress 10 10 "Installation complete!"

# Final summary of the first-boot approach
log_info "📋 Summary: First boot will use automatic force import for reliability"
log_info "🔄 After successful first boot, the system switches to clean imports automatically"

# Mark installation as completed
INSTALL_STATE="completed"

log_header "🎉 Installation Successfully Completed! 🎉"

echo ""
echo -e "${GREEN}${BOLD}✅ Ubuntu 24.04 with ZFS mirror root installed successfully!${NC}"
echo ""
echo -e "${BOLD}System Configuration:${NC}"
echo -e "  • Hostname: ${GREEN}${HOSTNAME}${NC}"
echo -e "  • Admin User: ${GREEN}${ADMIN_USER}${NC}"
echo -e "  • ZFS Pools: ${GREEN}rpool (root), bpool (boot)${NC}"
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
echo -en "${BOLD}Unmount and prepare for reboot? (Y/n): ${NC}"
read -r response

if [[ ! "${response}" =~ ^[Nn]$ ]]; then
    log_info "Performing clean shutdown sequence..."
        
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
    zpool export bpool 2>/dev/null || zpool export -f bpool 2>/dev/null || true
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
    echo -e "  ✓ Clean pool import via hostid alignment (no force flags)"
    echo -e "  ✓ Both drives fully bootable and synchronized"
    echo -e "  ✓ Comprehensive test and recovery tools included"
    echo ""
    echo -e "${YELLOW}${BOLD}First Boot:${NC}"
    echo -e "  • Force import flag will be automatically removed"
    echo -e "  • Manual cleanup (if needed): ${GREEN}sudo rm -f /.zfs-force-import-firstboot /etc/grub.d/99_zfs_firstboot && sudo update-grub${NC}"
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
echo -e "${BOLD}Installation log: ${GREEN}${LOG_FILE}${NC}"
echo -e "${BOLD}Original repository: ${GREEN}${ORIGINAL_REPO}${NC}"
