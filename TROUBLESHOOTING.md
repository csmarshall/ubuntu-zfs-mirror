# Ubuntu ZFS Mirror - Troubleshooting Guide

**← Back to [README.md](./README.md) | Installation Guide**

## Known Issues and Solutions

### First Boot Import Issues

**Symptoms:**
- `pool was previously in use from another system` errors
- Manual force import required: `zpool import -f rpool`
- Clean import failures on first boot

**Root Cause:**
ZFS pools created in live CD environment may not import cleanly on first boot due to different system context.

**Solution (v6.0.0+ - Simplified Force Import):**
- **Kernel Parameter Force Import:** Uses `zfs_force=1` in GRUB kernel command line for reliable first boot
- **Service-Controlled Cleanup:** Systemd service automatically removes force import after successful boot
- **Single Pool Architecture:** Only `rpool` exists - no complex dual-pool management
- **Comprehensive Validation:** Pool health, mount validation, and write access checks before cleanup
- **Transparent Logging:** All activities logged to system log for debugging

**Technical Implementation:**
- **GRUB Configuration:** Temporary GRUB script adds `zfs_force=1` to kernel command line when service is enabled
- **Service Detection:** Force import only active when `zfs-firstboot-cleanup.service` is enabled
- **Automatic Cleanup:** Service validates successful boot and removes itself after one successful import
- **Smart Integration:** Preserves existing kernel parameters (console, etc.) while adding force import

### Manual Recovery Instructions (v6.0.0+)

**If First Boot Fails (Rare):**
If the automatic force import somehow fails, you can manually import:

```bash
# From initramfs prompt (single pool architecture):
zpool import -f rpool
exit
```

**Manual Cleanup (If Needed):**
If you need to manually remove the first-boot configuration:

```bash
# Check service status
sudo systemctl status zfs-firstboot-cleanup.service

# Disable service manually if needed
sudo systemctl disable zfs-firstboot-cleanup.service
sudo rm -f /etc/systemd/system/zfs-firstboot-cleanup.service

# Update GRUB to remove force import
sudo update-grub

# Verify rpool status
zpool status rpool
```

**View First-Boot Logs:**
```bash
# Check first-boot cleanup logs
sudo journalctl -u zfs-firstboot-cleanup.service

# Check system log for ZFS force import activities
sudo journalctl | grep "zfs-firstboot-cleanup"
```

### Architecture Changes (v6.0.0+)

**Single-Pool Architecture:**
- **Only `rpool` exists** - eliminated `bpool` due to Ubuntu 24.04 systemd incompatibility
- **3-Partition Layout:** EFI (1GB) + Swap (configurable) + ZFS Root (remaining space)
- **GRUB2 Compatibility:** Root pool uses `compatibility=grub2` for direct kernel storage
- **No Complex Hostid Management:** Relies on reliable force import mechanism

**Benefits of Single-Pool Design:**
- ✅ **Ubuntu 24.04 Compatible:** Eliminates systemd assertion failures
- ✅ **Simplified Maintenance:** No dual-pool complexity
- ✅ **Reliable First Boot:** Proven force import mechanism
- ✅ **KISS Architecture:** Keep It Simple and Stupid principle

### Legacy Issues (v5.x and Earlier)

**Note:** The following issues were related to dual-pool architecture and complex hostid synchronization used in versions prior to v6.0.0. These issues no longer apply.

**Historical Context:**
- **v4.x:** Complex hostid synchronization with dual-pool architecture
- **v5.x:** `/etc/default/zfs` configuration approach with dual pools
- **v6.0.0+:** Simplified `zfs_force=1` kernel parameter with single pool

**Migration from Legacy Versions:**
The v6.0.0+ single-pool architecture eliminates all previous issues including:
- Dual-pool import failures and systemd assertion errors
- Complex hostid synchronization timing issues
- Boot pool import failures in Ubuntu 24.04
- Complex force import cleanup procedures

### Quick Fixes

**Emergency Force Import:**
```bash
# From initramfs prompt (single pool only)
zpool import -f rpool
exit
```

**Manual Pool Import (if needed):**
```bash
# Import pool manually (emergency only)
sudo zpool import -f rpool

# Check pool status
zpool status rpool

# Check basic functionality
sudo zfs list
sudo df -h /
```

**System Recovery Commands:**
```bash
# Check ZFS service status
sudo systemctl status zfs-import-cache.service
sudo systemctl status zfs-import-scan.service
sudo systemctl status zfs-mount.service

# Force ZFS service restart
sudo systemctl restart zfs-import-scan.service
sudo systemctl restart zfs-mount.service
```

## Script Configuration Details

### Single Pool Configuration (v6.0.0+)
- **Only `rpool`** exists with `cachefile=none`
- **GRUB2 Compatible:** Uses `compatibility=grub2` feature set
- **Service-Controlled Force Import:** `zfs-firstboot-cleanup.service` manages first boot
- **Automatic Cleanup:** Self-removing service after successful boot validation

### First-Boot Force Import Process
1. **Service Enabled:** `zfs-firstboot-cleanup.service` is enabled during installation
2. **GRUB Detection:** GRUB configuration detects enabled service and adds `zfs_force=1`
3. **Force Import:** Kernel boots with force import parameter
4. **Validation:** Service validates pool health, mounts, and write access
5. **Cleanup:** Service disables itself and updates GRUB configuration
6. **Reboot:** System reboots cleanly without force import

### Partition Layout (v6.0.0+)
```
Disk 1 & 2 (mirrored):
- Partition 1: EFI System (1GB) - FAT32
- Partition 2: Linux Swap (user-configurable, default 8GB)
- Partition 3: ZFS Root (remaining space) - rpool mirror
```

## Development Notes

### Recent Changes
- **2025-10-07:** v6.0.1 - Cleanup dual-pool references and undefined variables
- **2025-10-07:** v6.0.0 - **MAJOR**: Single-pool architecture refactor for Ubuntu 24.04 compatibility
- **Historical:** v5.x and earlier used dual-pool architecture (now deprecated)

### Testing Checklist (v6.0.0+)
- [ ] Single rpool created successfully with GRUB2 compatibility
- [ ] First-boot service enabled during installation
- [ ] System boots automatically with force import
- [ ] Service validates pool health and mounts
- [ ] Service disables itself after successful validation
- [ ] Subsequent boots work without force import
- [ ] System remains stable and functional

### Current Architecture Validation
```bash
# Verify single-pool architecture
zpool list  # Should show only rpool
zfs list    # Should show rpool datasets

# Check service status (should be disabled after first boot)
systemctl status zfs-firstboot-cleanup.service

# Verify GRUB configuration (should not have zfs_force=1 after cleanup)
grep -i zfs_force /boot/grub/grub.cfg
```

### Documentation Requirements

When making **ANY** changes to code files, you **MUST** update the corresponding documentation:

**Required Updates for ALL Code Changes:**

1. **CHANGELOG.md** - Add entry with:
   - Date and version increment
   - Brief description of changes
   - Line count changes (+X, -Y)
   - Classification (Bugfix, Feature, Enhancement, etc.)

2. **TROUBLESHOOTING.md** - Update if the change:
   - Fixes a known issue
   - Changes validation logic
   - Modifies error handling
   - Affects installation flow

3. **README.md** - Update if the change:
   - Affects usage instructions
   - Changes requirements
   - Modifies command line options
   - Updates system compatibility

**Version Numbering:** Use semantic versioning (Major.Minor.Patch)
- Current version: **6.0.1** (as of 2025-10-07)

**⚠️ CRITICAL: Version Synchronization Required**
When updating version numbers, you **MUST** update ALL of these locations:
1. `zfs_mirror_setup.sh` - Line 6 (comment) and Line 14 (VERSION variable)
2. `README.md` - Technical Specifications section
3. `TROUBLESHOOTING.md` - This section (current version)
4. `CHANGELOG.md` - Timeline and Recent Fixes sections

Use this command to verify synchronization:
```bash
grep -r "6\.[0-9]\+\.[0-9]\+" *.{sh,md} | grep -E "(Version|version|Script Version)"
```

### AI Assistant Guidelines

**Workflow for AI Assistants:**
1. **Before making changes**: Read existing documentation to understand context
2. **While making changes**: Note what documentation needs updating
3. **After making changes**: Update ALL relevant documentation files
4. **Version changes**: Update ALL 4 version locations (see critical warning above)
5. **Never skip documentation**: Even small fixes require changelog entries

**Quality Standards:**
- Test thoroughly (changes affect bootability and data integrity)
- Document everything (users depend on accurate troubleshooting info)
- Follow existing patterns and code style
- Validate logic (ZFS operations have complex interdependencies)

### Future Improvements
- Monitor Ubuntu ZFS service changes
- Consider pool scrub automation
- Add more detailed health checks
- Enhanced logging and monitoring capabilities