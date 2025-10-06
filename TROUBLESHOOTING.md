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

**Solution (v5.1.0 - Smart Force Import):**
- **Automatic force import:** Uses `/etc/default/zfs` configuration for seamless first boot
- **ZFS native integration:** Leverages OpenZFS systemd service configuration
- **Smart cleanup:** Automatic removal of force configuration after successful first boot
- **Parameter inheritance:** Preserves existing kernel parameters (console, etc.)
- **No synchronization needed:** Eliminates complex hostid manipulation entirely

**Technical Implementation:**
- **ZFS Configuration:** `ZPOOL_IMPORT_OPTS="-f"` in `/etc/default/zfs` for force import
- **Initramfs Integration:** Works with `zfs-import-scan.service` for automatic pool detection
- **GRUB Inheritance:** Smart detection and preservation of existing kernel parameters
- **Auto-cleanup:** Systemd service removes force configuration after successful boot
- **Robust Error Handling:** Comprehensive GRUB editing with fallback mechanisms

### Manual Recovery Instructions (v5.1.0)

**If First Boot Fails (Rare):**
If the automatic force import somehow fails, you can manually import:

```bash
# From initramfs prompt:
zpool import -f rpool
zpool import -f bpool
exit
```

**Manual Cleanup (If Needed):**
If you need to manually remove the first-boot configuration:

```bash
# Remove force import configuration
sudo rm -f /etc/default/zfs.bak
sudo sed -i '/ZFS_INITRD_ADDITIONAL_DATASETS=/d' /etc/default/zfs
sudo sed -i '/ZPOOL_IMPORT_OPTS=/d' /etc/default/zfs
sudo systemctl disable zfs-firstboot-cleanup.service
```

**Technical Details:**
- **ZFS Configuration:** Uses `/etc/default/zfs` for OpenZFS systemd service configuration
- **Import Service:** `zfs-import-scan.service` handles automatic pool detection and import
- **Force Import:** `ZPOOL_IMPORT_OPTS="-f"` parameter passed to zpool import commands
- **Smart GRUB:** Preserves existing kernel parameters while adding necessary ZFS options

### Legacy Issues (Pre-v5.1.0)

**Note:** The following issues were related to complex hostid synchronization approaches used in versions prior to v5.1.0. These issues no longer apply as the hostid approach has been completely removed in favor of a simpler force import mechanism.

**Historical Context:**
- **v4.2.x - v4.3.x:** Used complex hostid synchronization with multiple validation points
- **v5.0.x:** Used kernel parameter `zfs_force=1` approach
- **v5.1.0+:** Uses `/etc/default/zfs` configuration for seamless integration

**Migration from Legacy Versions:**
If upgrading from older script versions, the new approach eliminates all previous hostid-related issues including:
- Hostid generation timing issues
- Chroot environment hexdump/od command inconsistencies
- Byte order and validation failures
- Complex synchronization logic

**Current Approach Benefits:**
- ✅ No hostid manipulation required
- ✅ Uses standard OpenZFS configuration files
- ✅ Seamless integration with systemd services
- ✅ Automatic cleanup after first successful boot
- ✅ Preserves existing kernel parameters

### Quick Fixes

**Emergency Force Import:**
```bash
# From initramfs prompt
zpool import -f rpool
exit
```

**Manual Pool Import (if needed):**
```bash
# Import pools manually (emergency only)
sudo zpool import -f rpool
sudo zpool import -f bpool

# Check pool status
zpool status

# Check hostid alignment
hostid
zdb -C rpool | grep hostid
zdb -C bpool | grep hostid
```

## Script Configuration Details

### Pool Import Configuration
- Both `rpool` and `bpool` use `cachefile=none`
- `zfs-import-scan.service` handles all imports
- No cache file dependencies
- **Hostid synchronization** ensures clean import without force flags

### Hostid Management (v4.2.0+)
- Unique hostid generated during installation
- Synchronized across installer and target system
- Pre-boot verification confirms pool alignment
- No cleanup services or force flags required

## Development Notes

### Recent Changes
- **2025-09-30:** v4.3.1 - **ENHANCED**: Implemented rpool-authoritative hostid synchronization with auto-recovery
- **2025-09-30:** v4.3.0 - **MAJOR**: Implemented pool-to-target hostid synchronization (eliminates timing issues)
- **2025-09-30:** v4.2.11 - Fixed inconsistent hostid reading commands (replaced hexdump with od)
- **2025-09-30:** v4.2.10 - Fixed malformed od command causing hostid concatenation errors
- **2025-09-30:** v4.2.9 - Fixed chroot hostid command generating random hostids instead of using synchronized file
- **2025-09-30:** v4.2.8 - Fixed missing hexdump in chroot causing hostid synchronization failures
- **2025-09-30:** v4.2.7 - Fixed hostid generation timing bug causing pool validation failures
- **2025-09-29:** v4.2.6 - Fixed chroot hostid reading to use synchronized file
- **2025-09-29:** v4.2.5 - Fixed hostid hex formatting with leading zeros
- **2025-09-29:** v4.2.4 - Fixed zdb hostid validation for active pools
- **2025-09-29:** v4.2.3 - Dual hostid validation with DRY refactoring
- **2025-09-29:** v4.2.2 - Fixed hostid mountpoint conflict during pool creation
- **2025-09-29:** v4.2.1 - Fixed hostid validation timing (validation moved to after base system install)
- **2025-09-29:** v4.2.0 - Implemented hostid synchronization for clean imports
- **2025-09-26:** Fixed first boot import reliability by switching to cachefile=none for both pools

### Testing Checklist
- [ ] Hostid generated before pool creation
- [ ] Hostid file copied to target system (early validation)
- [ ] Pools created with correct hostid
- [ ] Base system installed successfully
- [ ] Final validation: target system hostid matches pool hostid (verified by zdb -C)
- [ ] Both pools import cleanly at first boot
- [ ] No force import required

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
- Current version: **5.2.1** (as of 2025-10-06)

**⚠️ CRITICAL: Version Synchronization Required**
When updating version numbers, you **MUST** update ALL of these locations:
1. `zfs_mirror_setup.sh` - Line 6 (comment) and Line 14 (VERSION variable)
2. `README.md` - Technical Specifications section
3. `TROUBLESHOOTING.md` - This section (current version)
4. `CHANGELOG.md` - Timeline and Recent Fixes sections

Use this command to verify synchronization:
```bash
grep -r "5\.[0-9]\+\.[0-9]\+" *.{sh,md} | grep -E "(Version|version|Script Version)"
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