# Ubuntu 24.04 ZFS Mirror Root Installer

Enhanced version of the Ubuntu ZFS mirror root installation script with production fixes and bulletproof hostid synchronization for clean first boot.

## Overview

This script creates a ZFS root mirror on two drives for Ubuntu 24.04 Server with full redundancy and automatic failover capability. Both drives will be bootable with UEFI support.

## Features

- **Clean Pool Import**: Pools import without force flags via automatic hostid synchronization
- **Full Drive Redundancy**: Both drives are bootable with automatic failover
- **Production Ready**: Enhanced error handling and recovery mechanisms
- **No Manual Intervention**: Eliminates "pool was previously in use from another system" errors
- **UEFI Support**: Modern boot configuration with proper EFI handling

## Requirements

- Ubuntu 24.04 Live USB environment
- Two drives of similar size (±10% tolerance)
- Root privileges
- UEFI boot mode
- Internet connection for package installation

## Quick Start

### 1. Find Your Drives
```bash
ls -la /dev/disk/by-id/ | grep -v part
```

### 2. Basic Installation
```bash
sudo ./zfs_mirror_setup.sh hostname /dev/disk/by-id/drive1 /dev/disk/by-id/drive2
```

### 3. Recommended: Clean Installation
```bash
sudo ./zfs_mirror_setup.sh --prepare hostname /dev/disk/by-id/drive1 /dev/disk/by-id/drive2
```

## Usage Options

```bash
./zfs_mirror_setup.sh [--prepare] <hostname> <disk1> <disk2>
./zfs_mirror_setup.sh --wipe-only <disk1> <disk2>
```

**Options:**
- `--prepare`: Wipe drives completely before installation (recommended)
- `--wipe-only`: Just wipe drives without installing

## Architecture

### ZFS Pool Configuration
- **rpool**: Root filesystem pool with compression and modern features
- **bpool**: Boot pool with GRUB2 compatibility
- **Both pools**: Mirror configuration across both drives
- **Import method**: Scan-based import (`cachefile=none`) for Ubuntu 24.04 reliability

### Partition Layout (per drive)
1. **EFI System Partition**: 1GB FAT32 for UEFI boot
2. **Boot Pool Partition**: 2GB for ZFS boot pool
3. **Root Pool Partition**: Remaining space for ZFS root pool

### System Configuration
- **Clean Pool Import**: No force flags needed due to hostid synchronization
- **Service Configuration**: Bulletproof ZFS import services using scan-based detection
- **Recovery Tools**: Manual utilities and troubleshooting guides included

## Installation Flow

The script follows a carefully orchestrated sequence to ensure reliable ZFS root installation:

```mermaid
flowchart TD
    A[Start Installation] --> B[Validate Drives & Environment]
    B --> C{--prepare flag?}
    C -->|Yes| D[Wipe Drives Completely]
    C -->|No| E[Skip Drive Wipe]
    D --> F[Partition Drives]
    E --> F

    F --> G[Install Required Packages]
    G --> H[Create ZFS Pools]
    H --> I[Boot Pool Creation]
    I --> J[Root Pool Creation]
    J --> K[Verify Empty /mnt for Altroot]
    K --> L[Pools Mount to /mnt]

    L --> M[Create ZFS Datasets]
    M --> N[Install Ubuntu Base System]
    N --> O[Configure Target System]

    O --> P[Setup Network & Users]
    P --> Q[Install & Configure GRUB]
    Q --> R[Generate Initramfs]

    R --> S[Read Actual Pool Hostid]
    S --> T[Set Target System Hostid to Match]
    T --> U[Final Validation]
    U --> V{Hostid Match?}
    V -->|No| W[❌ FAIL: Hostid Sync Error]
    V -->|Yes| X[✅ Installation Complete]

    style S fill:#e1f5fe
    style T fill:#e8f5e8
    style U fill:#fff3e0
    style X fill:#e8f5e8
    style W fill:#ffebee
```

### Critical Validation Points

1. **Pool Creation** (Steps H-L): ZFS pools created with installer's current hostid
2. **Complete Installation** (Steps M-R): Full system installation completed
3. **Hostid Synchronization** (Steps S-T): Read actual pool hostid and set target system to match
4. **Final Validation** (Step U): Verify target system hostid matches pool hostid exactly

This simplified approach eliminates timing issues and ensures pools always import cleanly without force flags.

## Post-Installation

### Verification Commands
```bash
# Check pool status
zpool status

# Verify both pools imported
zpool list

# Check hostid alignment
hostid
sudo zdb -l /dev/disk/by-id/your-drive-part4 | grep hostid
```

### Maintenance Commands
```bash
# Monthly scrub (automated via cron)
sudo zpool scrub rpool && sudo zpool scrub bpool

# Sync EFI partitions
sudo /usr/local/bin/sync-efi-partitions

# Manual force flag removal (if needed)
sudo /usr/local/bin/zfs-remove-force-flag
```

## Troubleshooting

For detailed troubleshooting information, common issues, and solutions, see:
**[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)**

### Quick Emergency Recovery
If you encounter boot issues:

1. **Import pools manually** from live USB:
   ```bash
   sudo zpool import -f -R /mnt rpool
   sudo zpool import -f -R /mnt bpool
   ```

2. **Check the troubleshooting guide** for specific error solutions

## Technical Details

### Ubuntu 24.04 Specific Improvements
- **Bulletproof Import**: Uses `zfs-import-scan.service` only
- **No Cache Files**: Avoids cache file corruption issues
- **Reliable First Boot**: Both pools import automatically

### Security Features
- **Disk Wiping**: Optional secure disk preparation
- **EFI Security**: Proper UEFI boot configuration
- **Recovery Mode**: Built-in emergency recovery procedures

## Development

### Testing
After making changes, test with:
```bash
# Test in VM or dedicated hardware
sudo ./zfs_mirror_setup.sh --prepare test-host /dev/sdX /dev/sdY
```

### Contributing
1. Test changes thoroughly
2. Update `TROUBLESHOOTING.md` with new issues/solutions
3. Verify all installation scenarios work

## License

MIT License - See original repository for details.

## References and Documentation

### Official Sources
- **OpenZFS Documentation**: https://openzfs.github.io/openzfs-docs/
- **Ubuntu ZFS Guide**: https://ubuntu.com/tutorials/setup-zfs-storage-pool
- **Original Repository**: https://github.com/csmarshall/ubuntu-zfs-mirror
- **Enhanced Version**: https://claude.ai - Production-ready fixes

### Technical Specifications
- **Script Version**: 4.3.0 - Implemented pool-to-target hostid synchronization (eliminates timing issues)
- **License**: MIT
- **Drive Support**: NVMe, SATA SSD, SATA HDD, SAS, and other drive types
- **Ubuntu Repositories**: Uses official archive.ubuntu.com and security.ubuntu.com

### Key Technical Features
- **GRUB2 Compatibility**: Boot pool configured with `compatibility=grub2`
- **UEFI Integration**: Proper EFI System Partition setup with deterministic volume IDs
- **AppArmor Support**: Configurable security (enabled by default)
- **Drive Failure Simulation**: Built-in commands for testing resilience
- **EFI Sync Utility**: Automatic synchronization between EFI partitions

---

**⚠️ Warning**: This script will completely wipe the specified drives. Ensure you have backups of any important data.

**📖 Need Help?** Check [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for common issues and solutions.
**📈 History**: See [CHANGELOG.md](./CHANGELOG.md) for development timeline and major changes.