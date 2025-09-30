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

### Chroot Hostid Generation Issues (Fixed v4.2.8-v4.2.9)

#### Missing hexdump in Chroot Environment (Fixed v4.2.8)

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

#### Chroot Hostid Command Ignoring Synchronized File (Fixed v4.2.9)

**Symptoms:**
- Pools created with correct hostid (e.g., `056c64de`)
- Final validation fails with different hostid (e.g., `75eded19`)
- Log shows: `ZFS configuration created with hostid: 75eded19` but pools have `056c64de`

**Root Cause:**
The `chroot /mnt hostid` command generates new random hostids instead of reading the synchronized `/mnt/etc/hostid` file.

**Fix Applied (v4.2.9):**
```bash
# Changed from:
HOSTID=$(chroot /mnt hostid 2>/dev/null || echo "")

# To:
HOSTID=$(printf "%08x" "$(od -An -tx4 -N4 /mnt/etc/hostid | tr -d ' ')" || echo "failed")
```

**Manual Fix (if using old script):**
```bash
# Read hostid directly from synchronized file
HOSTID=$(printf "%08x" "$(od -An -tx4 -N4 /mnt/etc/hostid | tr -d ' ')")
echo "Synchronized hostid: ${HOSTID}"

# Verify both files match
cmp /etc/hostid /mnt/etc/hostid && echo "Files match" || echo "Files differ"
```

#### Malformed Od Command Causing Concatenation Errors (Fixed v4.2.10)

**Symptoms:**
- Log shows hostid like: `00000612failed` or `Using synchronized hostid for ZFS configuration: 00000612failed`
- Validation fails with malformed hostid containing "failed" text
- Od command works but error handling concatenates output incorrectly

**Root Cause:**
The `printf` command structure was malformed, causing partial od output to concatenate with error handling text.

**Fix Applied (v4.2.10):**
```bash
# Changed from (broken):
HOSTID=$(printf "%08x" "$(od -An -tx4 -N4 /mnt/etc/hostid | tr -d ' ')" || echo "failed")

# To (fixed):
HOSTID_RAW=$(od -An -tx4 -N4 /mnt/etc/hostid 2>/dev/null | tr -d ' ')
if [[ -n "${HOSTID_RAW}" && "${HOSTID_RAW}" =~ ^[0-9a-f]{8}$ ]]; then
    HOSTID="${HOSTID_RAW}"
else
    HOSTID="failed"
fi
```

**Manual Fix (if using old script):**
```bash
# Test the od command properly
HOSTID_RAW=$(od -An -tx4 -N4 /mnt/etc/hostid 2>/dev/null | tr -d ' ')
echo "Raw hostid: '${HOSTID_RAW}'"
if [[ "${HOSTID_RAW}" =~ ^[0-9a-f]{8}$ ]]; then
    echo "Valid hostid: ${HOSTID_RAW}"
else
    echo "Invalid or failed hostid read"
fi
```

#### Inconsistent Hostid Reading Commands (Fixed v4.2.11)

**Symptoms:**
- Final validation fails even though pools were created correctly
- Mix of `od` and `hexdump` commands causing inconsistent hostid reading
- Hostid synchronization works during install but fails at final validation

**Root Cause:**
The script used `od` commands in some places (chroot environment) but still used `hexdump` in the final validation step, causing inconsistent hostid reading between install and target system environments.

**Fix Applied (v4.2.11):**
```bash
# Changed from (inconsistent):
TARGET_HOSTID=$(printf "%08x" "$(hexdump -e '1/4 "%u"' /mnt/etc/hostid)" 2>/dev/null || echo "failed")

# To (consistent with rest of script):
TARGET_HOSTID_RAW=$(od -An -tx4 -N4 /mnt/etc/hostid 2>/dev/null | tr -d ' ')
if [[ -n "${TARGET_HOSTID_RAW}" && "${TARGET_HOSTID_RAW}" =~ ^[0-9a-f]{8}$ ]]; then
    TARGET_HOSTID="${TARGET_HOSTID_RAW}"
else
    TARGET_HOSTID="failed"
fi
```

**Manual Fix (if using old script):**
```bash
# Use consistent od command for all hostid reading
TARGET_HOSTID_RAW=$(od -An -tx4 -N4 /mnt/etc/hostid 2>/dev/null | tr -d ' ')
if [[ "${TARGET_HOSTID_RAW}" =~ ^[0-9a-f]{8}$ ]]; then
    echo "Valid hostid: ${TARGET_HOSTID_RAW}"
else
    echo "Failed to read hostid"
fi
```

#### Hostid Byte Order Issues (Fixed v4.3.0+)

**Symptoms:**
- Pool hostid validation fails even though synchronization appears to work
- Log shows different hex values: `Expected: 956b0a0b, got rpool: 0b0a6b95`
- Hostids appear to be "backwards" or byte-swapped

**Root Cause:**
Linux hostid files must be written in little-endian byte order, but hex string conversion creates big-endian format.

**Example of the Problem:**
```bash
# Pool hostid: 185232277 (decimal) = 0x0b0a6b95 (hex)
# Wrong way (big-endian): printf "%08x" 185232277 | xxd -r -p
# Creates bytes: [0b, 0a, 6b, 95]
# When read back: 956b0a0b (reversed!)

# Correct way (little-endian): struct.pack('<I', 185232277)
# Creates bytes: [95, 6b, 0a, 0b]
# When read back: 0b0a6b95 (matches pool!)
```

**Fix Applied (v4.3.0):**
```bash
# Use Python struct.pack for correct byte order
python3 -c "import struct; open('/mnt/etc/hostid', 'wb').write(struct.pack('<I', ${HOSTID_DECIMAL}))"
```

#### New Simplified Approach (v4.3.0+)

**Major Change: Pool-to-Target Hostid Synchronization**

Starting with v4.3.0, the script uses a completely new approach that eliminates all previous timing and synchronization issues:

**Old Approach (v4.2.x):**
1. Generate hostid early with `zgenhostid -f`
2. Try to synchronize during installation
3. Multiple validation points with timing issues
4. Complex error-prone synchronization logic

**New Approach (v4.3.0+):**
1. Create pools with whatever hostid installer has
2. Complete entire installation normally
3. **Final step**: Read actual pool hostid → write to `/mnt/etc/hostid`
4. Single validation: target system hostid matches pool hostid

**Benefits:**
- ✅ No timing issues or race conditions
- ✅ No risk of hostid files being overwritten mid-install
- ✅ Pools are authoritative source of hostid
- ✅ Eliminates all "pool was previously in use from another system" errors
- ✅ Much simpler logic and easier to debug

**Code Example (v4.3.0):**
```bash
# Read actual pool hostid (at end of installation)
ACTUAL_POOL_HOSTID_DECIMAL=$(zdb -l "/dev/disk/by-id/${POOL_DEVICE}" | grep "hostid:" | awk '{print $2}')

# Set target system to match
printf "%08x" "${ACTUAL_POOL_HOSTID_DECIMAL}" | xxd -r -p > /mnt/etc/hostid

# Verify synchronization
TARGET_HOSTID=$(od -An -tx4 -N4 /mnt/etc/hostid | tr -d ' ')
validate_pool_hostid "at completion" "${TARGET_HOSTID}"
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
- Current version: **4.3.0** (as of 2025-09-30)

**⚠️ CRITICAL: Version Synchronization Required**
When updating version numbers, you **MUST** update ALL of these locations:
1. `zfs_mirror_setup.sh` - Line 6 (comment) and Line 14 (VERSION variable)
2. `README.md` - Technical Specifications section
3. `TROUBLESHOOTING.md` - This section (current version)
4. `CHANGELOG.md` - Timeline and Recent Fixes sections

Use this command to verify synchronization:
```bash
grep -r "4\.[0-9]\+\.[0-9]\+" *.{sh,md} | grep -E "(Version|version|Script Version)"
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