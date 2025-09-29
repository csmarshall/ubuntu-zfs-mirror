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
- **2025-09-29:** v4.2.0 - Implemented hostid synchronization for clean imports
- **2025-09-26:** Fixed first boot import reliability by switching to cachefile=none for both pools

### Testing Checklist
- [ ] Hostid generated before pool creation
- [ ] Pools created with correct hostid (verified by zdb -C)
- [ ] Target system configured with same hostid
- [ ] Both pools import cleanly at first boot
- [ ] No force import required

### Future Improvements
- Monitor Ubuntu ZFS service changes
- Consider pool scrub automation
- Add more detailed health checks