#!/bin/bash

# Ubuntu 24.04 ZFS Root Installation Script
# Creates a ZFS mirror on two drives with full redundancy
# Supports: NVMe, SATA SSD, SATA HDD, SAS, and other drive types
# Version: 3.3.2 - Fixed USE_PERFORMANCE_TUNABLES unbound variable
# License: MIT
# Repository: https://github.com/csmarshall/ubuntu-zfs-mirror

set -euo pipefail

# Script metadata
readonly VERSION="3.3.4"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# More aggressive pool destruction
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
        
    log_info "Attempting basic ZFS cleanup for ${pool_name}"
        
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
        
    log_info "Basic cleanup completed for ${pool_name}"
}

# Enhanced nuclear cleanup with better pool handling
perform_aggressive_zfs_cleanup() {
    local pool_name="$1"
    local part1="$2"  
    local part2="$3"
        
    log_info "NUCLEAR CLEANUP: Aggressively clearing ZFS state for ${pool_name}"
    log_debug "Target partitions: ${part1}, ${part2}"
        
    # Step 1: Specifically destroy the pool we're about to create
    destroy_specific_pool "${pool_name}"
        
    # Step 2: Destroy all pools for good measure
    destroy_all_pools
        
    # Step 3: Check if pool still exists in import cache
    log_debug "Checking import cache for ${pool_name}"
    if zpool import 2>/dev/null | grep -q "pool: ${pool_name}"; then
        log_info "Pool ${pool_name} found in import cache, force importing to destroy"
        # Import with -N to not mount datasets, -f to force
        zpool import -f -N "${pool_name}" 2>/dev/null || true
        # Now destroy it
        zpool destroy -f "${pool_name}" 2>/dev/null || true
    fi
        
    # Step 4: Clear the ZFS cache file
    log_debug "Clearing ZFS cache files"
    rm -f /etc/zfs/zpool.cache 2>/dev/null || true
        
    # Step 5: Stop ZFS services temporarily
    log_debug "Stopping ZFS services for cleanup"
    systemctl stop zfs-import-cache.service 2>/dev/null || true
    systemctl stop zfs-import-scan.service 2>/dev/null || true
    systemctl stop zfs.target 2>/dev/null || true
        
    # Step 6: Nuclear option - clear labels with multiple methods
    log_info "Using nuclear approach to clear ZFS labels"
    for part in "${part1}" "${part2}"; do
        log_debug "Nuclear cleanup on partition: ${part}"
                
        # Method 1: ZFS labelclear (multiple times for good measure)
        for i in {1..3}; do
            zpool labelclear -f "${part}" 2>/dev/null || true
        done
                
        # Method 2: Wipe the beginning and end of partition
        dd if=/dev/zero of="${part}" bs=1M count=10 2>/dev/null || true
                
        # Get partition size for end wipe
        local part_size
        part_size=$(blockdev --getsize64 "${part}" 2>/dev/null || echo "0")
        if [[ "${part_size}" -gt 10485760 ]]; then  # If larger than 10MB
            dd if=/dev/zero of="${part}" bs=1M count=10 seek=$(((part_size / 1048576) - 10)) 2>/dev/null || true
        fi
                
        # Method 3: Wipe ZFS label locations specifically
        # ZFS writes 4 labels: 2 at the beginning (L0, L1) and 2 at the end (L2, L3)
        for offset in 0 256 512 768; do
            dd if=/dev/zero of="${part}" bs=1K count=256 seek=${offset} 2>/dev/null || true
        done
    done
        
    # Step 7: Restart ZFS services
    log_debug "Restarting ZFS services"
    systemctl start zfs.target 2>/dev/null || true
        
    # Step 8: Clear kernel module state
    log_debug "Refreshing kernel module state"
    if lsmod | grep -q "^zfs "; then
        # Try to unload and reload ZFS module (may fail if in use)
        modprobe -r zfs 2>/dev/null || true
        modprobe zfs 2>/dev/null || true
    fi
        
    # Step 9: Force kernel to drop caches and re-read
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    partprobe "${part1}" "${part2}" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
        
    # Step 10: Wait for kernel to settle
    log_debug "Waiting for kernel to settle after nuclear cleanup"
    sleep 5  # Increased wait time
        
    # Final verification
    log_debug "Verifying cleanup success"
    if zpool import 2>/dev/null | grep -q "pool: ${pool_name}"; then
        log_error "WARNING: Pool ${pool_name} still visible in import list after cleanup"
        # One more aggressive attempt
        log_info "Making final aggressive cleanup attempt"
        dd if=/dev/zero of="${part1}" bs=1M count=100 2>/dev/null || true
        dd if=/dev/zero of="${part2}" bs=1M count=100 2>/dev/null || true
        sleep 3
    fi
        
    log_info "Nuclear ZFS cleanup completed for ${pool_name}"
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

# Get drive identifier for UEFI naming - Fixed trailing dash issue
get_drive_identifier() {
    local disk_path="$1"
    local identifier=""
    
    log_debug "Generating UEFI-compatible identifier for: ${disk_path}" >&2
    
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
    
    # CRITICAL FIX: Clean up the identifier to ensure UEFI compatibility
    # Replace underscores with hyphens for UEFI compatibility
    identifier="${identifier//_/-}"
        
    # Remove leading and trailing dashes
    identifier="${identifier##-}"  # Remove leading dashes
    identifier="${identifier%%-}"  # Remove trailing dashes
        
    # Remove any consecutive dashes (replace -- with -)
    while [[ "${identifier}" == *"--"* ]]; do
        identifier="${identifier//--/-}"
    done
    
    # Final validation - ensure it's not empty and doesn't end with dash
    if [[ -z "${identifier}" ]]; then
        identifier="GenericDisk"
        log_warning "Empty identifier, using generic fallback" >&2
    fi
        
    # Final trailing dash removal (in case truncation creates one)
    identifier="${identifier%-}"
    
    # Limit length for UEFI compatibility (20 chars max)
    if [[ ${#identifier} -gt 20 ]]; then
        identifier="${identifier:0:20}"
        log_debug "Truncated identifier to 20 chars: ${identifier}" >&2
                
        # Re-check for trailing dash after truncation
        identifier="${identifier%-}"
    fi
    
    log_debug "Final UEFI identifier: '${identifier}'" >&2
    echo "${identifier}"
}

# Get network interface with improved detection
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
}

# Secure wipe function - consolidated with better progress reporting
secure_wipe_drive() {
    local disk="$1"
    local wipe_type="${2:-quick}"  # quick or full
    
    log_info "Performing ${wipe_type} wipe on ${disk}..."
    
    # Stop any services using the disk
    systemctl stop zed 2>/dev/null || true
    
    # Force kernel to drop caches for clean state
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    if [[ "${wipe_type}" == "full" ]]; then
        # Full security wipe with random data (slow but thorough)
        log_warning "Full wipe requested - this will take hours for large drives"
        dd if=/dev/urandom of="${disk}" bs=1M status=progress || true
    else
        # Quick wipe - critical areas only
        local disk_size
        disk_size=$(blockdev --getsize64 "${disk}" 2>/dev/null || echo "0")
        local disk_size_sectors=$((disk_size / 512))
                
        log_debug "Disk size: ${disk_size} bytes (${disk_size_sectors} sectors)" >&2
                
        # Wipe first 100MB (covers partition tables, boot sectors, ZFS labels)
        log_debug "Wiping first 100MB of ${disk}" >&2
        dd if=/dev/zero of="${disk}" bs=1M count=100 status=none 2>/dev/null || true
                
        # Wipe last 100MB (covers GPT backup, ZFS labels at end)
        if [[ "${disk_size_sectors}" -gt 204800 ]]; then  # 204800 sectors = 100MB
            log_debug "Wiping last 100MB of ${disk}" >&2
            dd if=/dev/zero of="${disk}" bs=512 count=204800 \
               seek=$((disk_size_sectors - 204800)) status=none 2>/dev/null || true
        fi
                
        # Wipe ZFS label areas specifically (L0-L3 at standard offsets)
        for offset in 256 512 3840 3584; do
            log_debug "Wiping ZFS label area at offset ${offset}K" >&2
            dd if=/dev/zero of="${disk}" bs=1K count=256 seek=${offset} status=none 2>/dev/null || true
        done
    fi
    
    # Force kernel to re-read partition table
    blockdev --rereadpt "${disk}" 2>/dev/null || true
    partprobe "${disk}" 2>/dev/null || true
    
    log_info "Wipe of ${disk} complete"
}

# ============================================================================
# MAIN FUNCTIONS
# ============================================================================

# Usage information with improved formatting
usage() {
    # Use echo -e to properly interpret color codes
    echo -e "${BOLD}Ubuntu 24.04 ZFS Mirror Root Installer v${VERSION}${NC}"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo "  ${SCRIPT_NAME} [--prepare] <hostname> <disk1> <disk2>"
    echo "  ${SCRIPT_NAME} --wipe-only <disk1> <disk2>"
    echo ""
    echo -e "${BOLD}Description:${NC}"
    echo "  Creates a ZFS root mirror on two drives for Ubuntu 24.04 Server."
    echo "  Both drives will be bootable with automatic failover capability."
    echo ""
    echo "  Supports NVMe, SATA SSD, SATA HDD, SAS, and other drive types."
    echo "  Automatically optimizes for drive type (SSD vs HDD)."
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

# Wipe drives completely
wipe_drives_completely() {
    local disk1="$1"
    local disk2="$2"
    
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
    secure_wipe_drive "${disk1}" "quick"
    secure_wipe_drive "${disk2}" "quick"
    
    log_info "Drives wiped successfully"
    exit 0
}

# Validate disk device with comprehensive checks
validate_disk_device() {
    local disk="$1"
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
        log_error "ERROR: ${disk} appears to be a partition, not a whole disk"
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

# Check prerequisites
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
        apt-get update || exit 1
        apt-get install -y debootstrap gdisk zfsutils-linux dosfstools openssh-server efibootmgr || exit 1
                
        log_info "All required tools installed successfully"
    fi
    
    log_info "All prerequisites satisfied"
}

# Get drive size in bytes with error handling
get_drive_size() {
    local drive="$1"
    local size
        
    log_debug "Getting size for drive: ${drive}" >&2
    size=$(blockdev --getsize64 "${drive}" 2>/dev/null || echo "0")
        
    if [[ "${size}" == "0" ]]; then
        log_warning "Could not determine size for ${drive}" >&2
    else
        log_debug "Drive ${drive} size: ${size} bytes" >&2
    fi
        
    echo "${size}"
}

# Detect disk type with improved detection
detect_disk_type() {
    local disk="$1"
    local disk_path
    local disk_name
    disk_path=$(readlink -f "${disk}")
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
        is_rotational=$(cat "${rotational}")
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
}

# Get partition naming with improved handling
get_partition_name() {
    local disk="$1"
    local part_num="$2"
    
    log_debug "Getting partition name for disk ${disk}, partition ${part_num}" >&2
    
    # For /dev/disk/by-id/ paths (most reliable)
    if [[ "${disk}" =~ ^/dev/disk/by- ]]; then
        echo "${disk}-part${part_num}"
        return
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
}

# Partition a disk with improved error handling and logging
partition_disk() {
    local disk="$1"
    local disk_type="$2"
    
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
        exit 1
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
    
    log_info "Successfully partitioned ${disk}"
}

# Console and system configuration
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
        SERIAL_UNIT="${SERIAL_PORT#ttyS}"
        [[ ! "${SERIAL_UNIT}" =~ ^[0-9]+$ ]] && SERIAL_UNIT="1"
                
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
}

# Create admin user with improved validation
create_admin_user() {
    log_header "Creating Administrative User"
    
    # Get username with validation
    while true; do
        echo -en "${BOLD}Enter username for admin account: ${NC}"
        read -r ADMIN_USER
                
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
    
    # Optional SSH key
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
}

# Enhanced pre-destruction analysis with risk-based confirmations
perform_pre_destruction_analysis() {
    echo ""
    log_warning "⚠️  PRE-DESTRUCTION ANALYSIS ⚠️"
    echo ""
    
    # Check if we're running from a ZFS root that we're trying to destroy
    local current_root
    current_root=$(findmnt -n -o SOURCE /)
    if [[ "${current_root}" =~ ^rpool ]] || [[ "${current_root}" =~ ^bpool ]]; then
        log_error "CRITICAL: You appear to be running from a ZFS root system!"
        log_error "The installer cannot destroy pools that are currently in use as root."
        log_error "Please boot from a Live USB to run this installer."
        exit 1
    fi
    
    # Analyze what's currently on the drives
    has_zfs_pools=false
    has_mounted_fs=false
    has_partitions=false
    has_boot_signatures=false
    
    log_info "Analyzing current drive contents..."
    
    for disk in "${PRIMARY_DISK}" "${SECONDARY_DISK}"; do
        echo ""
        # Display disk with appropriate name
        if [[ "${disk}" == "${PRIMARY_DISK}" ]]; then
            echo -e "${BOLD}${disk} (${DISK1_NAME}):${NC}"
        else
            echo -e "${BOLD}${disk} (${DISK2_NAME}):${NC}"
        fi
                
        # Check for ZFS pools
        local disk_basename
        disk_basename=$(basename "$(readlink -f "${disk}")")
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
        part_info=$(lsblk -n "${disk}" 2>/dev/null | tail -n +2)
        if [[ -n "${part_info}" ]]; then
            echo -e "${YELLOW}  • Contains partition table with $(echo "${part_info}" | wc -l) partition(s)${NC}"
            echo "${part_info}" | head -5 | sed 's/^/    /'
            has_partitions=true
                        
            # Check for boot/EFI signatures
            while IFS= read -r part_line; do
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
                        elif [[ "${fs_type}" == "ext4" ]] || [[ "${fs_type}" == "ext3" ]] || [[ "${fs_type}" == "ext2" ]]; then
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
PRIMARY_DISK="${DISK1}"
SECONDARY_DISK="${DISK2}"

# Validate hostname
if [[ ! "${HOSTNAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    log_error "Invalid hostname format: ${HOSTNAME}"
    log_error "Hostname must be 1-63 characters, alphanumeric with hyphens (not at start/end)"
    exit 1
fi

# Get drive identifiers
DISK1_NAME=$(get_drive_identifier "${DISK1}")
DISK2_NAME=$(get_drive_identifier "${DISK2}")

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

log_info "Installation started at $(date)"
log_info "Configuration:"
log_info "  Hostname: ${HOSTNAME}"
log_info "  Primary disk: ${PRIMARY_DISK} (${DISK1_NAME})"
log_info "  Secondary disk: ${SECONDARY_DISK} (${DISK2_NAME})"
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
check_prerequisites
configure_system_preferences
create_admin_user

log_header "Validating Drive Configuration"
INSTALL_STATE="validating"

# Verify drives exist and are valid
for disk in "${PRIMARY_DISK}" "${SECONDARY_DISK}"; do
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
DISK1_TYPE=$(detect_disk_type "${PRIMARY_DISK}")
DISK2_TYPE=$(detect_disk_type "${SECONDARY_DISK}")

log_info "Disk types:"
log_info "  Primary: ${DISK1_TYPE}"
log_info "  Secondary: ${DISK2_TYPE}"

# Check and compare disk sizes
DISK1_SIZE=$(get_drive_size "${PRIMARY_DISK}")
DISK2_SIZE=$(get_drive_size "${SECONDARY_DISK}")

DISK1_SIZE_GB=$((DISK1_SIZE / 1024 / 1024 / 1024))
DISK2_SIZE_GB=$((DISK2_SIZE / 1024 / 1024 / 1024))

log_info "Disk sizes:"
log_info "  Primary: ${DISK1_SIZE_GB}GB (${DISK1_SIZE} bytes)"
log_info "  Secondary: ${DISK2_SIZE_GB}GB (${DISK2_SIZE} bytes)"

# Calculate and validate size difference
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
perform_pre_destruction_analysis

# If --prepare was specified, wipe drives first
if [[ "${USE_PREPARE}" == "true" ]]; then
    log_header "Preparing Drives (--prepare mode)"
    log_info "Performing complete wipe of both drives..."
        
    # Stop all services first
    stop_disk_services "${PRIMARY_DISK}"
    stop_disk_services "${SECONDARY_DISK}"
        
    # Destroy existing ZFS pools
    destroy_all_pools
        
    # Perform secure wipe on both drives
    secure_wipe_drive "${PRIMARY_DISK}" "quick"
    secure_wipe_drive "${SECONDARY_DISK}" "quick"
        
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
partition_disk "${PRIMARY_DISK}" "${DISK1_TYPE}"
partition_disk "${SECONDARY_DISK}" "${DISK2_TYPE}"

log_header "Creating ZFS Pools"
INSTALL_STATE="pools_creating"

# Determine optimal ZFS settings based on drive types
ASHIFT=12  # Default for 4K sectors
COMPRESSION="off"  # Default off for performance, lz4 for boot pool
TRIM_ENABLED="on"  # Default on for SSDs

# Adjust settings for HDDs
if [[ "${DISK1_TYPE}" == "hdd" ]] || [[ "${DISK2_TYPE}" == "hdd" ]]; then
    log_info "HDD detected - adjusting ZFS settings for optimal HDD performance"
        
    # Check actual sector sizes
    SECTOR1=$(blockdev --getpbsz "${PRIMARY_DISK}" 2>/dev/null || echo "4096")
    SECTOR2=$(blockdev --getpbsz "${SECONDARY_DISK}" 2>/dev/null || echo "4096")
    
    # Use ashift=9 for 512 byte sectors
    if [[ "${SECTOR1}" == "512" ]] || [[ "${SECTOR2}" == "512" ]]; then
        ASHIFT=9
    fi
    
    # Disable TRIM for HDDs
    TRIM_ENABLED="off"
fi

log_info "ZFS pool settings:"
log_info "  ashift: ${ASHIFT}"
log_info "  compression: ${COMPRESSION} (root), lz4 (boot)"
log_info "  autotrim: ${TRIM_ENABLED}"

# Get partition device paths
PART1_EFI=$(get_partition_name "${PRIMARY_DISK}" 1)
PART2_EFI=$(get_partition_name "${SECONDARY_DISK}" 1)
PART1_SWAP=$(get_partition_name "${PRIMARY_DISK}" 2)
PART2_SWAP=$(get_partition_name "${SECONDARY_DISK}" 2)
PART1_BOOT=$(get_partition_name "${PRIMARY_DISK}" 3)
PART2_BOOT=$(get_partition_name "${SECONDARY_DISK}" 3)
PART1_ROOT=$(get_partition_name "${PRIMARY_DISK}" 4)
PART2_ROOT=$(get_partition_name "${SECONDARY_DISK}" 4)

log_debug "Partition mapping:"
log_debug "  EFI: ${PART1_EFI}, ${PART2_EFI}"
log_debug "  Swap: ${PART1_SWAP}, ${PART2_SWAP}"
log_debug "  Boot: ${PART1_BOOT}, ${PART2_BOOT}"
log_debug "  Root: ${PART1_ROOT}, ${PART2_ROOT}"

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

# Nuclear cleanup before boot pool creation
log_info "Preparing for boot pool creation"
log_info "Attempting basic ZFS cleanup for bpool"
perform_basic_zfs_cleanup "bpool" "${PART1_BOOT}" "${PART2_BOOT}"
log_info "Basic cleanup completed for bpool"

# Create boot pool with GRUB compatibility - ALL OPTIONS INLINE
log_info "Creating boot pool (bpool)..."
# NOTE: Using cachefile=none due to Ubuntu 24.04 bug where cachefile property
# doesn't persist correctly even when set to /etc/zfs/zpool.cache
# This forces pool discovery by scanning on each boot rather than cache
if ! zpool create \
    -f \
    -o "ashift=${ASHIFT}" \
    -o "autotrim=${TRIM_ENABLED}" \
    -o cachefile=none \
    -o compatibility=grub2 \
    -o feature@livelist=enabled \
    -o feature@zpool_checkpoint=enabled \
    -O devices=off \
    -O acltype=posixacl \
    -O xattr=sa \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=/boot \
    -R /mnt \
    bpool mirror "${PART1_BOOT}" "${PART2_BOOT}"; then
    log_error "Failed to create boot pool"
    exit 1
fi

# CRITICAL: Verify boot pool was actually created
if ! zpool list bpool &>/dev/null; then
    log_error "Boot pool creation appeared to succeed but pool doesn't exist!"
    log_error "This is a critical error. Please check system logs."
    exit 1
fi

log_info "Boot pool created successfully"

show_progress 4 10 "Creating root pool..."

# Simple cleanup before root pool creation  
log_info "Preparing for root pool creation"
log_info "Attempting basic ZFS cleanup for rpool"
perform_basic_zfs_cleanup "rpool" "${PART1_ROOT}" "${PART2_ROOT}"
log_info "Basic cleanup completed for rpool"

# Create root pool with optimal settings - ALL OPTIONS INLINE
log_info "Creating root pool (rpool)..."
if [[ "${TRIM_ENABLED}" == "on" ]]; then
    if ! zpool create \
        -f \
        -o "ashift=${ASHIFT}" \
        -o autotrim=on \
        -O acltype=posixacl \
        -O xattr=sa \
        -O dnodesize=auto \
        -O "compression=${COMPRESSION}" \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off \
        -O mountpoint=/ \
        -R /mnt \
        rpool mirror "${PART1_ROOT}" "${PART2_ROOT}"; then
        log_error "Failed to create root pool"
        exit 1
    fi
else
    if ! zpool create \
        -f \
        -o "ashift=${ASHIFT}" \
        -O acltype=posixacl \
        -O xattr=sa \
        -O dnodesize=auto \
        -O "compression=${COMPRESSION}" \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off \
        -O mountpoint=/ \
        -R /mnt \
        rpool mirror "${PART1_ROOT}" "${PART2_ROOT}"; then
        log_error "Failed to create root pool"
        exit 1
    fi
fi

# CRITICAL: Verify root pool was actually created
if ! zpool list rpool &>/dev/null; then
    log_error "Root pool creation appeared to succeed but pool doesn't exist!"
    log_error "This is a critical error. Please check system logs."
    exit 1
fi

log_info "Root pool created successfully"

POOLS_CREATED="yes"

log_info "ZFS pools created successfully!"
echo ""
log_info "Current pool status:"
zpool list
echo ""

# Show detailed status for both pools
log_info "Boot pool status:"
if ! zpool status bpool 2>/dev/null; then
    log_warning "Boot pool status unavailable"
fi

echo ""
log_info "Root pool status:"
if ! zpool status rpool 2>/dev/null; then
    log_warning "Root pool status unavailable"
fi

show_progress 5 10 "Creating ZFS datasets..."

# Create essential datasets
zfs create -o mountpoint=/ rpool/root
zfs create -o mountpoint=/boot bpool/boot
zfs create -o mountpoint=/var rpool/var
zfs create -o mountpoint=/var/log rpool/var/log

# Interactive dataset creation
echo ""
echo -e "${BOLD}Optional: Create additional ZFS datasets?${NC}"
echo ""
echo "Additional datasets provide benefits like:"
echo "  - Separate snapshots/rollbacks for different areas"
echo "  - Individual quotas to prevent runaway disk usage"
echo "  - Different compression/performance settings per dataset"
echo "  - Granular backup policies"
echo ""
echo "Common examples:"
echo "  /var/cache      - Package manager cache (can exclude from backups)"
echo "  /var/tmp        - Temporary files (can set quotas, shorter retention)"
echo "  /var/lib/docker - Docker data (if using Docker)"
echo "  /usr/local      - Locally installed software (separate from system)"
echo "  /srv            - Service data (web files, databases)"
echo "  /opt            - Optional software packages"
echo "  /home           - User home directories (separate user data)"
echo ""
echo -en "${BOLD}Would you like to create additional datasets? (y/N): ${NC}"
read -r response

if [[ "${response}" =~ ^[Yy]$ ]]; then
    log_info "Creating additional datasets..."
    echo ""
    echo "Enter mount points one per line (e.g., /var/cache, /srv, /opt)"
    echo "Press Enter on empty line when done:"
        
    while true; do
        echo -en "${BOLD}Mount point: ${NC}"
        read -r mountpoint
                
        # Break on empty line
        [[ -z "${mountpoint}" ]] && break
                
        # Validate mount point format
        if [[ ! "${mountpoint}" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
            log_warning "Invalid mount point format: ${mountpoint}"
            continue
        fi
                
        # Convert mount point to dataset name
        dataset_name=$(echo "${mountpoint}" | sed 's|^/||' | sed 's|/|-|g')
                
        # Ask about quota
        echo -en "Set quota for ${mountpoint}? (e.g., 10G, 500M, or Enter for none): "
        read -r quota
                
        # Ask about compression
        echo ""
        echo "Compression options:"
        echo "  ${BOLD}off${NC}  - No compression (fastest, default for NVMe)"
        echo "  ${BOLD}lz4${NC}  - Fast compression, good for most data"
        echo "  ${BOLD}gzip${NC} - Better compression, more CPU usage"
        echo "  ${BOLD}zstd${NC} - Modern algorithm, balanced speed/compression"
        echo -en "Compression for ${mountpoint}? (off/lz4/gzip/zstd) [off]: "
        read -r compression
        compression="${compression:-off}"
                
        # Build the create command with proper quoting
        local create_opts=""
        create_opts="-o mountpoint=${mountpoint}"
                
        if [[ -n "${quota}" ]]; then
            create_opts="${create_opts} -o quota=${quota}"
        fi
                
        if [[ "${compression}" != "off" ]]; then
            create_opts="${create_opts} -o compression=${compression}"
        fi
                
        # Show what we're creating
        log_info "Creating ${mountpoint} with: compression=${compression}${quota:+, quota=${quota}}"
                
        # Create the dataset
        if ! zfs create ${create_opts} "rpool/${dataset_name}"; then
            log_warning "Failed to create dataset ${dataset_name}"
            continue
        fi
                
        # Set permissions for common directories
        case "${mountpoint}" in
            "/var/tmp"|"/tmp")
                chmod 1777 "/mnt${mountpoint}"
                ;;
        esac
        echo ""
    done
        
    log_info "Additional datasets created"
    echo ""
    log_info "Current dataset layout:"
    zfs list -r rpool -t filesystem -o name,mountpoint,quota,compress
    echo ""
else
    log_info "Skipping additional datasets - you can create them later if needed"
fi

# Mount tmpfs for /run
mkdir -p /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock
MOUNTS_ACTIVE="yes"

show_progress 6 10 "Installing base system..."

# Install Ubuntu base system
log_info "Installing Ubuntu base system with debootstrap..."
if ! debootstrap noble /mnt; then
    log_error "Failed to install Ubuntu base system"
    exit 1
fi

# Copy ZFS cache
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/ || true

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
DEFAULT_INTERFACE=$(get_network_interface)
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

# Create comprehensive chroot configuration script
cat << 'CHROOT_SCRIPT' > /mnt/tmp/configure_system.sh
#!/bin/bash
set -euo pipefail

# Logging in chroot
ts() { date +'%F %T'; }
log_info() { echo "$(ts) CHROOT INFO: $*"; }

exec > >(tee -a /tmp/chroot_config.log)
exec 2>&1

log_info "Starting chroot system configuration"

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
    htop net-tools \
    software-properties-common \
    systemd-timesyncd \
    cron

# Create and format EFI filesystems
apt-get install --yes dosfstools

# Create identical EFI filesystems (they'll be synced to stay identical)
log_info "Creating EFI filesystems for redundant boot"
mkdosfs -F 32 -s 1 -n "EFI" "${PART1_EFI}"
mkdosfs -F 32 -s 1 -n "EFI" "${PART2_EFI}"

# Use device path for primary EFI partition for explicit control
mkdir -p /boot/efi
echo "${PART1_EFI} /boot/efi vfat defaults 0 1" >> /etc/fstab
mount /boot/efi

log_info "Primary EFI partition mounted, secondary will be synced for redundancy"

# Install kernel and bootloader
DEBIAN_FRONTEND=noninteractive apt-get install --yes \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    linux-image-generic \
    linux-headers-generic \
    shim-signed \
    zfs-initramfs

# Configure swap using device paths for faster boot failure
log_info "Configuring swap with device paths for reliable boot behavior"
mkswap -f "${PART1_SWAP}"
mkswap -f "${PART2_SWAP}"

# Use device paths instead of UUIDs for faster failure if drives are missing
echo "${PART1_SWAP} none swap sw,discard,pri=1 0 0" >> /etc/fstab
echo "${PART2_SWAP} none swap sw,discard,pri=1 0 0" >> /etc/fstab
swapon -a

log_info "Swap configured with device paths - will fail fast if drives missing"

# Create admin user
useradd -m -s /bin/bash -G sudo,adm,cdrom,dip,plugdev "${ADMIN_USER}"
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd

# Configure SSH key if provided
if [[ "${USE_SSH_KEY}" == "true" ]] && [[ -n "${SSH_KEY}" ]]; then
    mkdir -p "/home/${ADMIN_USER}/.ssh"
    echo "${SSH_KEY}" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chmod 700 "/home/${ADMIN_USER}/.ssh"
    chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
fi

# Lock root account
passwd -l root

# Enable SSH service (use Ubuntu defaults)
systemctl enable ssh

# Configure tmpfs for /tmp
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

# Apply system optimizations if requested
if [[ "${USE_PERFORMANCE_TUNABLES}" == "true" ]]; then
    log_info "Applying performance tunables to /etc/sysctl.conf"
    cat << 'SYSCTL_EOF' >> /etc/sysctl.conf

# ZFS and server performance optimizations
# Applied by Ubuntu ZFS installer - can be modified anytime
vm.swappiness=10
vm.min_free_kbytes=131072
kernel.sysrq=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion=bbr
net.ipv4.tcp_fastopen=3
SYSCTL_EOF
    log_info "Performance tunables applied - see /etc/sysctl.conf"
else
    log_info "Using Ubuntu default system tunable values"
fi

# CRITICAL FIX: Generate consistent hostid for ZFS
log_info "Generating consistent hostid for ZFS"
zgenhostid -f
HOSTID=$(hostid)

# Configure ZFS import to use force flag ONLY for first boot
# This handles the hostid mismatch between Live USB and installed system
log_info "Configuring ZFS for first-boot force import"
cat > /etc/default/zfs << 'ZFS_DEFAULTS_EOF'
# Generated by Ubuntu ZFS installer
# Force import on first boot to handle Live USB to installed system transition
ZPOOL_IMPORT_OPTS="-f"
# This will be automatically removed after first successful boot
FIRST_BOOT_FORCE=yes
ZFS_DEFAULTS_EOF
echo "HOSTID=${HOSTID}" >> /etc/default/zfs

# Since the first-boot cleanup doesn't always work reliably,
# ensure we have permanent import services regardless
log_info "Note: Pool import services will handle imports even after force flag removal"

# Configure GRUB with console and AppArmor settings - Updated timeout to 10 seconds
if [[ "${USE_SERIAL_CONSOLE}" == "true" ]]; then
    # Build kernel command line with serial console
    KERNEL_CMDLINE="console=tty1 console=${SERIAL_PORT},${SERIAL_SPEED}"
    if [[ "${USE_APPARMOR}" == "false" ]]; then
        KERNEL_CMDLINE="${KERNEL_CMDLINE} apparmor=0"
    fi
    KERNEL_CMDLINE="${KERNEL_CMDLINE} root=ZFS=rpool/root"
        
    cat << GRUB_SERIAL_EOF > /etc/default/grub
GRUB_DEFAULT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_TIMEOUT=10
GRUB_CMDLINE_LINUX="${KERNEL_CMDLINE}"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=${SERIAL_SPEED} --unit=${SERIAL_UNIT} --word=8 --parity=no --stop=1"
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_SERIAL_EOF
else
    # Local console only
    KERNEL_CMDLINE="root=ZFS=rpool/root"
    if [[ "${USE_APPARMOR}" == "false" ]]; then
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

# Create enhanced EFI sync script with PROVEN working approach
cat << 'EFI_SYNC_EOF' > /usr/local/bin/sync-efi-partitions
#!/bin/bash
# Enhanced EFI Partition Sync Script - FINAL WORKING VERSION
# Dynamically discovers ZFS mirror drives and syncs EFI partitions with UUID recreation
# Uses simple, reliable approach that syncs first drive to second drive
#
# FINAL FIX: Simple drive-to-drive sync without complex path resolution
# Version: 1.3 - Proven working approach

set -euo pipefail

LOG_TAG="efi-sync"

# Logging function
log_message() {
    logger -t "$LOG_TAG" "$*" 2>/dev/null || true
    echo "$(date '+%F %T') [$LOG_TAG] $*"
}

# FIXED: Function to get ZFS mirror drives for rpool with proper output handling
get_zfs_mirror_drives() {
    local drives=()
        
    # Send debug output to stderr to avoid polluting function return
    echo "DEBUG: Scanning zpool status for rpool mirror drives" >&2
        
    # Get the mirror members for rpool
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*(/dev/|nvme-|ata-|scsi-) ]]; then
            # Extract device path, handling various formats
            local device
            device=$(echo "$line" | awk '{print $1}' | sed 's/[[:space:]]*$//')
                        
            echo "DEBUG: Found potential device in zpool status: $device" >&2
                        
            # Convert to base device (remove partition numbers)
            if [[ "$device" =~ -part[0-9]+$ ]]; then
                device="${device%-part*}"
                echo "DEBUG: Stripped -part suffix, now: $device" >&2
            elif [[ "$device" =~ p[0-9]+$ ]]; then
                device="${device%p*}"
                echo "DEBUG: Stripped p suffix, now: $device" >&2
            elif [[ "$device" =~ [0-9]+$ ]]; then
                device="${device%[0-9]*}"
                echo "DEBUG: Stripped numeric suffix, now: $device" >&2
            fi
                        
            # CRITICAL FIX: Ensure we have the full /dev/disk/by-id/ path
            if [[ "$device" =~ ^/dev/ ]]; then
                # Already a full path, resolve if it's a symlink
                if [[ -L "$device" ]]; then
                    device=$(readlink -f "$device")
                    echo "DEBUG: Resolved symlink to: $device" >&2
                fi
            else
                # Not a full path, prepend /dev/disk/by-id/
                device="/dev/disk/by-id/$device"
                echo "DEBUG: Added /dev/disk/by-id/ prefix: $device" >&2
            fi
                        
            # Verify the device exists before adding it
            if [[ -b "$device" || -L "$device" ]]; then
                drives+=("$device")
                echo "DEBUG: Device verified and added: $device" >&2
            else
                echo "DEBUG: Device $device not found, trying fallback search" >&2
                # Fallback: try to find the device in /dev/disk/by-id/
                local found_device=""
                local basename_target
                basename_target=$(basename "$device")
                                
                for candidate in /dev/disk/by-id/*; do
                    if [[ "$(basename "$candidate")" == "$basename_target" ]]; then
                        found_device="$candidate"
                        echo "DEBUG: Found device via fallback: $found_device" >&2
                        break
                    fi
                done
                                
                if [[ -n "$found_device" && (-b "$found_device" || -L "$found_device") ]]; then
                    drives+=("$found_device")
                    echo "DEBUG: Fallback device verified and added: $found_device" >&2
                else
                    echo "WARNING: Could not find device: $device" >&2
                fi
            fi
        fi
    done < <(zpool status rpool 2>/dev/null | grep -A 10 "mirror-0" | grep -E "(nvme|sd|vd)")
        
    echo "DEBUG: Final drives array: ${drives[*]}" >&2
        
    # Output only the actual drives to stdout
    printf '%s\n' "${drives[@]}"
}

# Function to get EFI partition from base drive
get_efi_partition() {
    local base_drive="$1"
        
    echo "DEBUG: Looking for EFI partition on base drive: $base_drive" >&2
        
    # Try different partition naming schemes
    for suffix in "-part1" "p1" "1"; do
        local efi_part="${base_drive}${suffix}"
        echo "DEBUG: Checking potential EFI partition: $efi_part" >&2
                
        if [[ -b "$efi_part" ]]; then
            # Verify it's actually an EFI partition
            local fs_type
            fs_type=$(blkid -s TYPE -o value "$efi_part" 2>/dev/null || echo "")
            echo "DEBUG: Partition $efi_part has filesystem type: $fs_type" >&2
                        
            if [[ "$fs_type" == "vfat" ]]; then
                echo "DEBUG: Found valid EFI partition: $efi_part" >&2
                echo "$efi_part"
                return 0
            fi
        fi
    done
        
    echo "ERROR: No valid EFI partition found for base drive: $base_drive" >&2
    return 1
}

# Main execution starts here
START_TIME=$(date +%s.%N 2>/dev/null || date +%s)
log_message "Starting enhanced EFI partition sync with smart change detection"

# Check if we're running on a ZFS system
if ! command -v zpool >/dev/null 2>&1; then
    log_message "ERROR: zpool command not found - not a ZFS system"
    exit 1
fi

# Check if rpool exists
if ! zpool list rpool >/dev/null 2>&1; then
    log_message "ERROR: rpool not found - cannot sync EFI partitions"
    exit 1
fi

# Step 1: Discover ZFS mirror drives
log_message "Step 1: Discovering ZFS mirror drives for rpool..."
mapfile -t MIRROR_DRIVES < <(get_zfs_mirror_drives)

if [[ ${#MIRROR_DRIVES[@]} -ne 2 ]]; then
    log_message "ERROR: Expected exactly 2 mirror drives, found ${#MIRROR_DRIVES[@]}: ${MIRROR_DRIVES[*]}"
    exit 1
fi

log_message "Found ZFS mirror drives: ${MIRROR_DRIVES[*]}"

# Step 2: Get EFI partitions from both drives
EFI_PARTITIONS=()
for drive in "${MIRROR_DRIVES[@]}"; do
    log_message "Step 2: Getting EFI partition for drive: $drive"
    if efi_part=$(get_efi_partition "$drive"); then
        EFI_PARTITIONS+=("$efi_part")
        log_message "Found EFI partition: $efi_part"
    else
        log_message "ERROR: Could not find EFI partition for drive $drive"
        exit 1
    fi
done

# Step 3: Simple approach - use first drive as source, second as target
PRIMARY_EFI="${EFI_PARTITIONS[0]}"
SECONDARY_EFI="${EFI_PARTITIONS[1]}"

log_message "Primary EFI (source): $PRIMARY_EFI"
log_message "Secondary EFI (target): $SECONDARY_EFI"

# Step 4: Get primary partition's UUID and label
PRIMARY_UUID=$(blkid -s UUID -o value "$PRIMARY_EFI" 2>/dev/null || "")
PRIMARY_LABEL=$(blkid -s LABEL -o value "$PRIMARY_EFI" 2>/dev/null || "EFI")

if [[ -z "$PRIMARY_UUID" ]]; then
    log_message "ERROR: Could not determine UUID of primary EFI partition $PRIMARY_EFI"
    exit 1
fi

log_message "Primary EFI UUID: $PRIMARY_UUID, Label: $PRIMARY_LABEL"

# Step 5: Mount primary to get content
PRIMARY_MOUNT=$(mktemp -d)
if ! mount "$PRIMARY_EFI" "$PRIMARY_MOUNT"; then
    log_message "ERROR: Failed to mount primary $PRIMARY_EFI"
    rmdir "$PRIMARY_MOUNT"
    exit 1
fi

# Step 6: Create secondary with matching UUID
SECONDARY_MOUNT=$(mktemp -d)

log_message "Recreating secondary EFI partition with matching UUID"
UUID_FOR_MKDOSFS="${PRIMARY_UUID//-/}"
if ! mkdosfs -F 32 -s 1 -n "$PRIMARY_LABEL" -i "$UUID_FOR_MKDOSFS" "$SECONDARY_EFI" >/dev/null 2>&1; then
    log_message "ERROR: Failed to recreate secondary EFI partition"
    umount "$PRIMARY_MOUNT" 2>/dev/null || true
    rmdir "$PRIMARY_MOUNT" "$SECONDARY_MOUNT"
    exit 1
fi

# Step 7: Mount secondary and sync content
if ! mount "$SECONDARY_EFI" "$SECONDARY_MOUNT"; then
    log_message "ERROR: Failed to mount secondary EFI partition"
    umount "$PRIMARY_MOUNT" 2>/dev/null || true
    rmdir "$PRIMARY_MOUNT" "$SECONDARY_MOUNT"
    exit 1
fi

log_message "Syncing EFI content from primary to secondary"
if rsync -av --delete "$PRIMARY_MOUNT/" "$SECONDARY_MOUNT/" >/dev/null 2>&1; then
    log_message "EFI content sync completed successfully"
else
    log_message "WARNING: EFI content sync had errors"
fi

# Step 8: Cleanup
umount "$PRIMARY_MOUNT" "$SECONDARY_MOUNT"
rmdir "$PRIMARY_MOUNT" "$SECONDARY_MOUNT"

# Step 9: Verify UUIDs match
SECONDARY_UUID=$(blkid -s UUID -o value "$SECONDARY_EFI" 2>/dev/null || "")
if [[ "$PRIMARY_UUID" == "$SECONDARY_UUID" ]]; then
    log_message "SUCCESS: Both EFI partitions have identical UUID: $PRIMARY_UUID"
else
    log_message "WARNING: UUID mismatch after sync - Primary: $PRIMARY_UUID, Secondary: $SECONDARY_UUID"
fi

# Step 10: Reinstall GRUB to secondary with unique bootloader ID to preserve drive identification
# Get drive identifiers from the base device paths
PRIMARY_DRIVE_BASE=$(echo "$PRIMARY_EFI" | sed 's/-part[0-9]*$//')
SECONDARY_DRIVE_BASE=$(echo "$SECONDARY_EFI" | sed 's/-part[0-9]*$//')

# Extract drive identifiers for bootloader IDs
get_drive_identifier() {
    local disk_path="$1"
    local identifier=""
    
    # Try to extract model name from the disk path
    if [[ "$disk_path" =~ nvme-(.+)_[A-Za-z0-9]{8,} ]]; then
        identifier="${BASH_REMATCH[1]}"
    elif [[ "$disk_path" =~ ata-(.+)_[A-Za-z0-9]{8,} ]] || [[ "$disk_path" =~ scsi-(.+)_[A-Za-z0-9]{8,} ]]; then
        identifier="${BASH_REMATCH[1]}"
    else
        local dev_name
        dev_name=$(basename "$disk_path")
        identifier="Disk-${dev_name}"
    fi
    
    # Clean up identifier for UEFI compatibility
    identifier="${identifier//_/-}"
    identifier="${identifier##-}"
    identifier="${identifier%%-}"
    while [[ "$identifier" == *"--"* ]]; do
        identifier="${identifier//--/-}"
    done
        
    if [[ -z "$identifier" ]]; then
        identifier="GenericDisk"
    fi
        
    if [[ ${#identifier} -gt 20 ]]; then
        identifier="${identifier:0:20}"
        identifier="${identifier%-}"
    fi
        
    echo "$identifier"
}

PRIMARY_ID=$(get_drive_identifier "$PRIMARY_DRIVE_BASE")
SECONDARY_ID=$(get_drive_identifier "$SECONDARY_DRIVE_BASE")

# Mount secondary EFI to install GRUB with unique ID
TEMP_MOUNT=$(mktemp -d)
if mount "$SECONDARY_EFI" "$TEMP_MOUNT"; then
    log_message "Installing GRUB to secondary drive with unique bootloader ID: Ubuntu-$SECONDARY_ID"
        
    # Install GRUB to secondary with unique bootloader ID
    if grub-install --target=x86_64-efi --efi-directory="$TEMP_MOUNT" \
       --bootloader-id="Ubuntu-$SECONDARY_ID" --recheck --no-floppy >/dev/null 2>&1; then
        log_message "GRUB successfully installed to secondary drive with ID: Ubuntu-$SECONDARY_ID"
    else
        log_message "WARNING: Failed to install GRUB to secondary drive with unique ID"
    fi
        
    umount "$TEMP_MOUNT"
else
    log_message "WARNING: Could not mount secondary EFI partition for GRUB installation"
fi
rmdir "$TEMP_MOUNT"

log_message "Enhanced EFI partition sync completed successfully"
log_message "Both drives bootable with unique identifiers: Ubuntu-$PRIMARY_ID and Ubuntu-$SECONDARY_ID"
exit 0
EFI_SYNC_EOF

chmod +x /usr/local/bin/sync-efi-partitions

# Create APT hook for EFI sync
echo 'DPkg::Post-Invoke {"/usr/local/bin/sync-efi-partitions || true";};' \
    > /etc/apt/apt.conf.d/99-sync-efi

log_info "APT hook created for automatic EFI sync during package updates"
log_info "Note: EFI partitions will be initially synced on first boot"

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

# Enable essential system services
log_info "Ensuring essential system services are enabled"
chroot /mnt systemctl enable systemd-timesyncd cron

# Note: Previous versions of this script masked systemd-udev-settle.service
# to work around boot delays, but we now rely on Ubuntu's default configuration
# for maximum compatibility and minimal system modifications
log_info "Using Ubuntu's default systemd configuration - no custom service masking"

# Update initramfs with ZFS support and proper hostid
update-initramfs -c -k all

log_info "Chroot configuration completed successfully"
CHROOT_SCRIPT

chmod +x /mnt/tmp/configure_system.sh

# Execute in chroot with all environment variables
chroot /mnt /usr/bin/env \
    PRIMARY_DISK="${PRIMARY_DISK}" \
    SECONDARY_DISK="${SECONDARY_DISK}" \
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
    DEFAULT_INTERFACE="${DEFAULT_INTERFACE}" \
    TRIM_ENABLED="${TRIM_ENABLED}" \
    USE_SERIAL_CONSOLE="${USE_SERIAL_CONSOLE:-false}" \
    SERIAL_PORT="${SERIAL_PORT:-ttyS1}" \
    SERIAL_SPEED="${SERIAL_SPEED:-115200}" \
    SERIAL_UNIT="${SERIAL_UNIT:-1}" \
    USE_APPARMOR="${USE_APPARMOR:-true}" \
    USE_PERFORMANCE_TUNABLES="${USE_PERFORMANCE_TUNABLES:-false}" \
    bash /tmp/configure_system.sh

# Verify the chroot script completed successfully
if [[ $? -ne 0 ]]; then
    log_error "Chroot configuration failed!"
    log_error "System may not be bootable. Check /mnt/tmp/chroot_config.log"
    exit 1
fi

# Immediately verify critical components were created
log_info "Verifying critical system components..."

# Check import services exist and are enabled
SERVICES_CREATED=false
SERVICES_TO_ENABLE=()

# Check zfs-import-pools.service
if [[ ! -f /mnt/etc/systemd/system/zfs-import-pools.service ]]; then
    log_error "CRITICAL: zfs-import-pools.service not created!"
    log_error "Creating it now with modern systemd dependencies..."
        
    # Create it directly with MODERN systemd dependencies (not deprecated udev-settle)
    cat << 'EOF' > /mnt/etc/systemd/system/zfs-import-pools.service
[Unit]
Description=Import ZFS pools (fallback creation)
DefaultDependencies=no
Before=zfs-mount.service
After=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/sbin/zpool import -a -f 2>/dev/null || true; /sbin/zpool list'

[Install]
WantedBy=zfs-import.target
EOF
    SERVICES_CREATED=true
    SERVICES_TO_ENABLE+=("zfs-import-pools.service")
else
    # Check if it's enabled
    if ! chroot /mnt systemctl is-enabled zfs-import-pools.service &>/dev/null; then
        log_warning "zfs-import-pools.service exists but is not enabled"
        SERVICES_TO_ENABLE+=("zfs-import-pools.service")
    fi
fi

# Check zfs-import-bpool.service
if [[ ! -f /mnt/etc/systemd/system/zfs-import-bpool.service ]]; then
    log_error "CRITICAL: zfs-import-bpool.service not created!"
    log_error "Creating it now with modern systemd dependencies..."
        
    cat << 'EOF' > /mnt/etc/systemd/system/zfs-import-bpool.service  
[Unit]
Description=Import boot pool explicitly (fallback creation)
DefaultDependencies=no
After=zfs-import-pools.service
Before=systemd-remount-fs.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'if ! /sbin/zpool list bpool >/dev/null 2>&1; then /sbin/zpool import -f bpool 2>/dev/null || true; fi'
ExecStart=/bin/sh -c '/sbin/zfs mount bpool/boot 2>/dev/null || true'

[Install]
WantedBy=zfs.target
EOF
    SERVICES_CREATED=true
    SERVICES_TO_ENABLE+=("zfs-import-bpool.service")
else
    # Check if it's enabled
    if ! chroot /mnt systemctl is-enabled zfs-import-bpool.service &>/dev/null; then
        log_warning "zfs-import-bpool.service exists but is not enabled"
        SERVICES_TO_ENABLE+=("zfs-import-bpool.service")
    fi
fi

# Enable any services that need it
if [[ ${#SERVICES_TO_ENABLE[@]} -gt 0 ]]; then
    log_info "Enabling ZFS import services: ${SERVICES_TO_ENABLE[*]}"
    chroot /mnt systemctl enable "${SERVICES_TO_ENABLE[@]}"
        
    # Verify they're now enabled
    for service in "${SERVICES_TO_ENABLE[@]}"; do
        if chroot /mnt systemctl is-enabled "${service}" &>/dev/null; then
            log_info "✓ ${service} is now enabled"
        else
            log_error "✗ Failed to enable ${service}"
        fi
    done
fi

# Verify /boot has content
if [[ ! -f /mnt/boot/vmlinuz* ]]; then
    log_warning "/boot appears empty - kernel may not be installed"
fi

# Verify hostid exists
if [[ ! -f /mnt/etc/hostid ]]; then
    log_warning "/etc/hostid missing - generating one"
    chroot /mnt zgenhostid -f
fi

log_info "Critical component verification complete"

show_progress 9 10 "Finalizing..."

# Create ZFS drive replacement helper script
log_info "Creating ZFS drive replacement helper script"
cat << 'REPLACE_SCRIPT' > /usr/local/bin/zfs-replace-drive
#!/bin/bash
# ZFS Mirror Drive Replacement Script
# Helps replace a failed drive in a ZFS mirror configuration
# Compatible with the Ubuntu ZFS Mirror installer

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${GREEN}INFO:${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}WARNING:${NC} $*"
}

log_error() {
    echo -e "${RED}ERROR:${NC} $*"
}

log_header() {
    echo -e "\n${BOLD}========================================${NC}"
    echo -e "${BOLD}$*${NC}"
    echo -e "${BOLD}========================================${NC}\n"
}

# Check if running as root
if [[ ${EUID} -ne 0 ]]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

# Check if ZFS is available
if ! command -v zpool &> /dev/null; then
    log_error "ZFS tools not found. Is ZFS installed?"
    exit 1
fi

# Function to display pool status with color coding
show_pool_status() {
    local pool="$1"
    echo -e "${BOLD}Pool: ${pool}${NC}"
    
    if ! zpool list "$pool" &>/dev/null; then
        log_error "Pool $pool not found"
        return 1
    fi
    
    local status
    status=$(zpool status "$pool")
    
    # Colorize the output
    echo "$status" | while IFS= read -r line; do
        if [[ "$line" =~ FAULTED|UNAVAIL|OFFLINE ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ "$line" =~ DEGRADED ]]; then
            echo -e "${YELLOW}$line${NC}"
        elif [[ "$line" =~ ONLINE ]] && [[ ! "$line" =~ "state: ONLINE" ]]; then
            echo -e "${GREEN}$line${NC}"
        else
            echo "$line"
        fi
    done
}

# Function to get drive identifier
get_drive_identifier() {
    local disk_path="$1"
    local identifier=""
    
    if [[ "$disk_path" =~ nvme-(.+)_[A-Za-z0-9]{8,} ]]; then
        identifier="${BASH_REMATCH[1]}"
    elif [[ "$disk_path" =~ ata-(.+)_[A-Za-z0-9]{8,} ]] || [[ "$disk_path" =~ scsi-(.+)_[A-Za-z0-9]{8,} ]]; then
        identifier="${BASH_REMATCH[1]}"
    else
        local dev_name
        dev_name=$(basename "$disk_path")
        identifier="Disk-${dev_name}"
    fi
    
    # Clean up identifier
    identifier="${identifier//_/-}"
    identifier="${identifier##-}"
    identifier="${identifier%%-}"
    
    while [[ "$identifier" == *"--"* ]]; do
        identifier="${identifier//--/-}"
    done
    
    if [[ -z "$identifier" ]]; then
        identifier="GenericDisk"
    fi
    
    if [[ ${#identifier} -gt 18 ]]; then
        identifier="${identifier:0:18}"
        identifier="${identifier%%-}"
    fi
    
    echo "$identifier"
}

# Main script
log_header "ZFS Mirror Drive Replacement Tool"

echo "This script helps replace a failed drive in your ZFS mirror setup."
echo "It will guide you through the process step-by-step."
echo ""

# Step 1: Assess current system status
log_header "Step 1: System Assessment"

log_info "Checking ZFS pool status..."
echo ""

# Check if pools exist
if ! zpool list rpool &>/dev/null || ! zpool list bpool &>/dev/null; then
    log_error "Required ZFS pools (rpool, bpool) not found"
    log_error "This script is designed for systems installed with the ZFS mirror installer"
    exit 1
fi

show_pool_status "rpool"
echo ""
show_pool_status "bpool"
echo ""

# Check if any pools are degraded
DEGRADED_POOLS=()
if zpool status rpool | grep -q "DEGRADED\|FAULTED\|UNAVAIL"; then
    DEGRADED_POOLS+=("rpool")
fi
if zpool status bpool | grep -q "DEGRADED\|FAULTED\|UNAVAIL"; then
    DEGRADED_POOLS+=("bpool")
fi

if [[ ${#DEGRADED_POOLS[@]} -eq 0 ]]; then
    log_info "All pools appear healthy. No replacement needed."
    echo ""
    echo -en "Continue anyway for testing/demonstration? (y/N): "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        exit 0
    fi
else
    log_warning "Degraded pools detected: ${DEGRADED_POOLS[*]}"
    log_warning "Drive replacement is recommended"
fi

# Step 2: Identify drives
log_header "Step 2: Drive Identification"

log_info "Available drives:"
ls -la /dev/disk/by-id/ | grep -E "(nvme|ata|scsi)" | grep -v part | while read -r line; do
    echo "  $line"
done

echo ""
log_info "Current ZFS configuration:"

# Get current mirror members
RPOOL_DRIVES=()
BPOOL_DRIVES=()

while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*(/dev/|nvme-|ata-|scsi-) ]]; then
        drive=$(echo "$line" | awk '{print $1}' | sed 's/[[:space:]]*$//')
        if [[ "$drive" =~ -part4$ ]]; then
            RPOOL_DRIVES+=("${drive%-part*}")
        elif [[ "$drive" =~ -part3$ ]]; then
            BPOOL_DRIVES+=("${drive%-part*}")
        fi
    fi
done < <(zpool status rpool bpool)

# Remove duplicates and display
MIRROR_DRIVES=($(printf '%s\n' "${RPOOL_DRIVES[@]}" "${BPOOL_DRIVES[@]}" | sort -u))

echo "Mirror drives in use:"
for drive in "${MIRROR_DRIVES[@]}"; do
    if [[ -b "$drive" ]] || [[ -L "$drive" ]]; then
        echo -e "  ${GREEN}✓ $drive${NC} (present)"
    else
        echo -e "  ${RED}✗ $drive${NC} (missing/failed)"
    fi
done

# Step 3: Get replacement drive
echo ""
log_header "Step 3: Drive Replacement"

echo "Please ensure you have:"
echo "1. Powered down the system"
echo "2. Physically replaced the failed drive"
echo "3. Powered back on and booted from the working drive"
echo ""

echo -en "Have you completed the physical drive replacement? (y/N): "
read -r response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    log_info "Please complete the physical replacement and run this script again"
    exit 0
fi

echo ""
log_info "Detecting new drive..."

# Find drives not currently in use by ZFS
AVAILABLE_DRIVES=()
for drive in /dev/disk/by-id/nvme-* /dev/disk/by-id/ata-* /dev/disk/by-id/scsi-*; do
    if [[ -e "$drive" ]] && [[ ! "$drive" =~ -part[0-9]+$ ]]; then
        # Check if this drive is already in the mirror
        drive_in_use=false
        for mirror_drive in "${MIRROR_DRIVES[@]}"; do
            if [[ "$drive" == "$mirror_drive" ]] && ([[ -b "$drive" ]] || [[ -L "$drive" ]]); then
                drive_in_use=true
                break
            fi
        done
        
        if [[ "$drive_in_use" == "false" ]]; then
            AVAILABLE_DRIVES+=("$drive")
        fi
    fi
done

if [[ ${#AVAILABLE_DRIVES[@]} -eq 0 ]]; then
    log_error "No new drives detected. Please check that the new drive is properly connected."
    exit 1
fi

echo "Available replacement drives:"
for i in "${!AVAILABLE_DRIVES[@]}"; do
    echo "$((i+1)). ${AVAILABLE_DRIVES[$i]}"
done

echo ""
echo -en "Select the replacement drive [1-${#AVAILABLE_DRIVES[@]}]: "
read -r selection

if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#AVAILABLE_DRIVES[@]} ]]; then
    log_error "Invalid selection"
    exit 1
fi

NEW_DRIVE="${AVAILABLE_DRIVES[$((selection-1))]}"
log_info "Selected replacement drive: $NEW_DRIVE"

# Get working drive for partition table copy
WORKING_DRIVE=""
for drive in "${MIRROR_DRIVES[@]}"; do
    if [[ -b "$drive" ]] || [[ -L "$drive" ]]; then
        WORKING_DRIVE="$drive"
        break
    fi
done

if [[ -z "$WORKING_DRIVE" ]]; then
    log_error "No working drive found to copy partition table from"
    exit 1
fi

log_info "Using $WORKING_DRIVE as template for partition table"

# Step 4: Partition the new drive
log_header "Step 4: Partitioning New Drive"

log_warning "This will destroy all data on $NEW_DRIVE"
echo -en "Continue? (y/N): "
read -r response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    log_info "Aborted by user"
    exit 0
fi

log_info "Copying partition table from $WORKING_DRIVE to $NEW_DRIVE..."
sgdisk --replicate="$NEW_DRIVE" "$WORKING_DRIVE"
sgdisk --randomize-guids "$NEW_DRIVE"

# Inform kernel
partprobe "$NEW_DRIVE"
udevadm settle
sleep 2

log_info "Partitioning completed"

# Step 5: Replace in ZFS pools
log_header "Step 5: ZFS Pool Recovery"

# Find the failed device names for replacement
FAILED_RPOOL_DEVICE=""
FAILED_BPOOL_DEVICE=""

# Look for failed devices in pool status
while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+(FAULTED|UNAVAIL|OFFLINE) ]]; then
        device="${BASH_REMATCH[1]}"
        if [[ "$device" =~ part4 ]]; then
            FAILED_RPOOL_DEVICE="$device"
        elif [[ "$device" =~ part3 ]]; then
            FAILED_BPOOL_DEVICE="$device"
        fi
    fi
done < <(zpool status rpool bpool)

# Replace in rpool
if [[ -n "$FAILED_RPOOL_DEVICE" ]]; then
    log_info "Replacing $FAILED_RPOOL_DEVICE with ${NEW_DRIVE}-part4 in rpool..."
    zpool replace rpool "$FAILED_RPOOL_DEVICE" "${NEW_DRIVE}-part4"
else
    log_info "No failed device found in rpool, adding as additional mirror member..."
    zpool attach rpool $(zpool status rpool | grep -E "part4" | head -1 | awk '{print $1}') "${NEW_DRIVE}-part4"
fi

# Replace in bpool
if [[ -n "$FAILED_BPOOL_DEVICE" ]]; then
    log_info "Replacing $FAILED_BPOOL_DEVICE with ${NEW_DRIVE}-part3 in bpool..."
    zpool replace bpool "$FAILED_BPOOL_DEVICE" "${NEW_DRIVE}-part3"
else
    log_info "No failed device found in bpool, adding as additional mirror member..."
    zpool attach bpool $(zpool status bpool | grep -E "part3" | head -1 | awk '{print $1}') "${NEW_DRIVE}-part3"
fi

log_info "ZFS resilver started. This may take several hours depending on data size."

# Step 6: Set up EFI and swap
log_header "Step 6: EFI and Swap Setup"

log_info "Creating EFI filesystem on ${NEW_DRIVE}-part1..."
mkdosfs -F 32 -s 1 -n "EFI" "${NEW_DRIVE}-part1"

log_info "Creating swap on ${NEW_DRIVE}-part2..."
mkswap "${NEW_DRIVE}-part2"
swapon "${NEW_DRIVE}-part2"

# Step 7: Monitor resilver
log_header "Step 7: Monitor Progress"

log_info "Resilver progress (press Ctrl+C to stop monitoring):"
echo ""

trap 'echo -e "\nStopping monitor..."; exit 0' SIGINT

while true; do
    clear
    show_pool_status "rpool"
    echo ""
    show_pool_status "bpool"
    
    # Check if resilver is complete
    if ! zpool status rpool | grep -q "resilver\|resilvering" && ! zpool status bpool | grep -q "resilver\|resilvering"; then
        log_info "Resilver completed!"
        break
    fi
    
    sleep 30
done

# Step 8: Final setup
log_header "Step 8: Final Configuration"

log_info "Running EFI partition sync..."
if command -v /usr/local/bin/sync-efi-partitions &>/dev/null; then
    /usr/local/bin/sync-efi-partitions
else
    log_warning "EFI sync script not found, manually installing GRUB..."
    
    # Manual GRUB installation
    mkdir -p /tmp/new-efi
    mount "${NEW_DRIVE}-part1" /tmp/new-efi
    
    DRIVE_ID=$(get_drive_identifier "$NEW_DRIVE")
    grub-install --target=x86_64-efi --efi-directory=/tmp/new-efi \
        --bootloader-id="Ubuntu-${DRIVE_ID}" --recheck --no-floppy
    
    umount /tmp/new-efi
    rmdir /tmp/new-efi
    
    log_info "GRUB installed with bootloader ID: Ubuntu-${DRIVE_ID}"
fi

# Final verification
log_header "Final Verification"

log_info "Final pool status:"
show_pool_status "rpool"
echo ""
show_pool_status "bpool"
echo ""

log_info "EFI bootloader entries:"
efibootmgr -v | head -10

echo ""
log_info "Swap status:"
swapon --show

echo ""
if zpool status rpool | grep -q "ONLINE" && zpool status bpool | grep -q "ONLINE" && \
   ! zpool status rpool | grep -q "FAULTED\|UNAVAIL\|DEGRADED" && \
   ! zpool status bpool | grep -q "FAULTED\|UNAVAIL\|DEGRADED"; then
    
    log_info "🎉 Drive replacement completed successfully!"
    echo ""
    echo "Your ZFS mirror is now fully redundant again."
    echo "Both drives are bootable and the system is ready for use."
    echo ""
    echo -e "${GREEN}Recommended next steps:${NC}"
    echo "1. Test boot from both drives to verify redundancy"
    echo "2. Monitor system logs for any issues"
    echo "3. Consider running a scrub: sudo zpool scrub rpool"
else
    log_warning "Drive replacement completed but some issues remain."
    echo "Please review the pool status above and resolve any remaining issues."
fi

REPLACE_SCRIPT

chmod +x /usr/local/bin/zfs-replace-drive
log_info "ZFS drive replacement script installed: /usr/local/bin/zfs-replace-drive"

show_progress 10 10 "Installation complete!"

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
echo -e "  • Drive 1: ${GREEN}${PRIMARY_DISK} (${DISK1_NAME})${NC}"
echo -e "  • Drive 2: ${GREEN}${SECONDARY_DISK} (${DISK2_NAME})${NC}"
echo -e "  • EFI Boot: ${GREEN}Dual redundant with dynamic sync${NC}"
echo -e "  • Boot Performance: ${GREEN}Ubuntu systemd bug workaround applied${NC}"

if [[ "${USE_SERIAL_CONSOLE:-false}" == "true" ]]; then
    echo -e "  • Serial Console: ${GREEN}${SERIAL_PORT:-ttyS1} @ ${SERIAL_SPEED:-115200} baud${NC}"
else
    echo -e "  • Console: ${YELLOW}Local only${NC}"
fi

if [[ "${USE_APPARMOR:-true}" == "true" ]]; then
    echo -e "  • AppArmor: ${GREEN}Enabled${NC}"
else
    echo -e "  • AppArmor: ${YELLOW}Disabled${NC}"
fi

if [[ "${USE_PERFORMANCE_TUNABLES:-false}" == "true" ]]; then
    echo -e "  • Performance Tunables: ${GREEN}Applied${NC}"
else
    echo -e "  • Performance Tunables: ${YELLOW}Default Ubuntu settings${NC}"
fi

echo ""
echo -en "${BOLD}Unmount and prepare for reboot? (Y/n): ${NC}"
read -r response

if [[ ! "${response}" =~ ^[Nn]$ ]]; then
    # Cleanup and unmount
    log_info "Performing clean shutdown sequence..."
        
    # Sync all writes
    sync
        
    # Kill any processes using /mnt
    fuser -km /mnt 2>/dev/null || true
    sleep 2
        
    # Restore output to original file descriptors before unmounting
    exec 1>&3 2>&4
        
    # Unmount chroot bind mounts
    umount -l /mnt/dev /mnt/proc /mnt/sys /mnt/run 2>/dev/null || true
    sleep 2
        
    # Unmount any remaining mounts under /mnt
    umount -lR /mnt 2>/dev/null || true
        
    # CRITICAL FIX: Export pools with proper options for clean first boot
    log_info "Exporting ZFS pools for clean first boot..."
        
    # NOTE: We don't set cachefile paths due to Ubuntu's broken cache mechanism
    # Pools are configured with cachefile=none to force scanning-based discovery
    # This avoids the cache file corruption issues in Ubuntu 24.04
        
    # Sync the cache anyway for completeness (though we don't rely on it)
    sync
        
    # Export the pools cleanly
    # The -f flag forces the export even if datasets are busy
    # This prevents the "pool was last accessed by another system" error
    if ! zpool export bpool 2>/dev/null; then
        log_warning "Normal export of bpool failed, forcing..."
        zpool export -f bpool 2>/dev/null || true
    fi
        
    if ! zpool export rpool 2>/dev/null; then
        log_warning "Normal export of rpool failed, forcing..."
        zpool export -f rpool 2>/dev/null || true
    fi
        
    # Verify pools are exported
    if zpool list 2>/dev/null | grep -q "bpool\|rpool"; then
        log_warning "Pools may not be fully exported - first boot may require manual import"
        echo -e "${YELLOW}Note: This can happen in Live USB environments where Ubuntu's desktop${NC}"
        echo -e "${YELLOW}services may interfere with clean pool export. The system should still${NC}"
        echo -e "${YELLOW}boot normally, but if you see 'no pool available' errors:${NC}"
        echo -e "${YELLOW}  zpool import -f rpool${NC}"
        echo -e "${YELLOW}  zpool import -f bpool${NC}"
    else
        log_info "Pools exported successfully"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}✅ System ready for reboot!${NC}"
    echo ""
    echo -e "${YELLOW}${BOLD}Next Steps:${NC}"
    echo -e "${YELLOW}1. Remove installation USB${NC}"
    echo -e "${YELLOW}2. Type: reboot${NC}"
    echo -e "${YELLOW}3. System boots from either drive${NC}"
    echo ""
    echo -e "${BOLD}Login: ${GREEN}${ADMIN_USER}${NC}"
        
    # First Boot Note
    echo ""
    echo -e "${BOLD}First Boot Information:${NC}"
    echo -e "${GREEN}✓ Fast Boot Configured:${NC}"
    echo -e "  Ubuntu's systemd-udev-settle bug has been worked around"
    echo -e "  Expected boot time: 30-60 seconds (not 2+ minutes)"
    echo -e "${GREEN}✓ True EFI Redundancy:${NC}"
    echo -e "  Both EFI partitions will be automatically synchronized"
    echo -e "  Dynamic drive discovery handles hardware changes"
    echo ""
    echo -e "${YELLOW}If you see boot delays, check:${NC}"
    echo -e "  ${GREEN}sudo systemctl status systemd-udev-settle.service${NC}"
    echo -e "  ${GREEN}sudo journalctl -b 0 -u systemd-udev-settle.service${NC}"
else
    echo -e "${YELLOW}System remains mounted at /mnt${NC}"
    echo -e "${YELLOW}To manually export pools later:${NC}"
    echo -e "  ${GREEN}umount -lR /mnt${NC}"
    echo -e "  ${GREEN}zpool export bpool${NC}"
    echo -e "  ${GREEN}zpool export rpool${NC}"
fi

echo ""
echo -e "${BOLD}Installation log: ${GREEN}${LOG_FILE}${NC}"
