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

**Solution (Implemented v4.2.0):**
- **Hostid synchronization:** Generate unique hostid before pool creation
- **Perfect alignment:** Same hostid used by installer and target system
- **Pre-boot verification:** Validate pools have correct hostid before reboot
- **Clean imports:** No force flags or cleanup complexity needed

**Technical Details:**
- **Before:** Pools created with random installer hostid, complex cleanup system needed
- **After:** Hostid generated and synchronized, pools import cleanly
- **Legacy approach:** First-boot cleanup system (removed in v4.2.0)
- **New approach:** Bulletproof hostid alignment eliminates all force flag requirements

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
- Current version: **4.2.1** (as of 2025-09-29)

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