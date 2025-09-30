# Ubuntu ZFS Mirror - Troubleshooting Guide

**← Back to [README.md](./README.md) | Installation Guide**

## Known Issues and Solutions

### First Boot Import Issues

**Symptoms:**
- `pool was previously in use from another system` errors
- Manual force import required: `zpool import -f rpool`
- Clean import failures on first boot

**Root Cause:**
Hostid mismatch between installer environment and target system. ZFS pools are created with installer USB hostid but target system boots with different hostid.

**Solution (Implemented v4.2.0, Fixed v4.2.7):**
- **Hostid synchronization:** Generate unique hostid before pool creation
- **Perfect alignment:** Same hostid used by installer and target system
- **Pre-boot verification:** Validate pools have correct hostid before reboot
- **Clean imports:** No force flags or cleanup complexity needed
- **Timing validation (v4.2.7):** Added verification that hostid generation actually takes effect

**Technical Details:**
- **Before:** Pools created with random installer hostid, complex cleanup system needed
- **After:** Hostid generated and synchronized, pools import cleanly
- **Legacy approach:** First-boot cleanup system (removed in v4.2.0)
- **New approach:** Bulletproof hostid alignment eliminates all force flag requirements
- **v4.2.7 Fix:** Added timing checks to ensure `zgenhostid -f` actually changes the hostid before pool creation

### Hostid Generation Timing Issues (Fixed v4.2.7)

**Symptoms:**
- Installation fails with: `Pool hostid validation FAILED at completion`
- Error shows: `Expected: 0d31d8fd, got rpool: 127e115a, bpool: 127e115a`
- Pools have old hostid instead of newly generated one

**Root Cause:**
Timing bug where `zgenhostid -f` generates new hostid but pools get created with old hostid before the change takes effect.

**Fix Applied (v4.2.7-v4.2.8):**
```bash
# v4.2.7: Added validation after zgenhostid -f
sleep 1
HOSTID=$(hostid)
NEW_HOSTID_CHECK=$(hostid)

# Ensure hostid actually changed
if [[ "${HOSTID}" == "${ORIGINAL_HOSTID}" ]]; then
    log_error "Hostid generation failed - hostid unchanged: ${HOSTID}"
    exit 1
fi

# Double-check consistency
if [[ "${HOSTID}" != "${NEW_HOSTID_CHECK}" ]]; then
    log_error "Hostid inconsistent after generation"
    exit 1
fi

# v4.2.8: Install util-linux in chroot and improve hostid reading
apt-get install --yes util-linux  # Ensures hexdump is available
HOSTID=$(printf "%08x" "$(od -An -tx4 -N4 /etc/hostid | tr -d ' ')" || echo "failed")
```

**Manual Recovery (if using old script):**
```bash
# Export pools
zpool export rpool bpool

# Set correct hostid and re-import
echo -ne '\x0d\x31\xd8\xfd' > /etc/hostid
zpool import -f rpool
zpool import -f bpool

# Update target system
echo -ne '\x0d\x31\xd8\xfd' > /mnt/etc/hostid
```

### Missing hexdump in Chroot Environment (Fixed v4.2.8)

**Symptoms:**
- Log shows: `/tmp/configure_system.sh: line 134: hexdump: command not found`
- Hostid validation shows: `Using previously generated hostid for ZFS: 00000000`
- Installation fails later with pool hostid mismatch

**Root Cause:**
The `hexdump` command was not available in the chroot environment, causing hostid reading to fail and fall back to generating a new random hostid.

**Fix Applied (v4.2.8):**
- Install `util-linux` package in chroot (contains hexdump)
- Use `od` as backup method for reading hostid file
- Better error detection for failed hostid reads

**Manual Fix (if using old script):**
```bash
# Install util-linux in chroot
chroot /mnt apt-get install --yes util-linux

# Or use od to read hostid file manually
HOSTID=$(printf "%08x" "$(od -An -tx4 -N4 /etc/hostid | tr -d ' ')")
echo "Current hostid: ${HOSTID}"
```

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
- Current version: **4.2.5** (as of 2025-09-29)

### AI Assistant Guidelines

**Workflow for AI Assistants:**
1. **Before making changes**: Read existing documentation to understand context
2. **While making changes**: Note what documentation needs updating
3. **After making changes**: Update ALL relevant documentation files
4. **Never skip documentation**: Even small fixes require changelog entries

**Quality Standards:**
- Test thoroughly (changes affect bootability and data integrity)
- Document everything (users depend on accurate troubleshooting info)
- Follow existing patterns and code style
- Validate logic (ZFS operations have complex interdependencies)

### Future Improvements
- Monitor Ubuntu ZFS service changes
- Consider pool scrub automation
- Add more detailed health checks