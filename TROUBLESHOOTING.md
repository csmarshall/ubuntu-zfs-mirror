# Ubuntu ZFS Mirror - Troubleshooting Guide

**← Back to [README.md](./README.md) | Installation Guide**

## Known Issues and Solutions

### First Boot Import Issues

**Symptoms:**
- `bpool` not importing at first boot
- `zfs-first-boot-cleanup.service` failing
- Manual force import required

**Root Cause:**
Ubuntu 24.04 has reliability issues with ZFS cache files, and the original script configuration was inconsistent between pools.

**Solution (Implemented):**
- Both pools now use `cachefile=none`
- Only `zfs-import-scan.service` enabled (no cache service)
- Eliminates cache file corruption issues

**Technical Details:**
- **Before:** Mixed cache/scan approach with missing scan service
- **After:** Bulletproof scan-only import for both pools
- **Trade-off:** Slightly slower boot, much more reliable

### Quick Fixes

**Emergency Force Import:**
```bash
# From initramfs prompt
zpool import -f rpool
exit
```

**Manual Cleanup After Boot Issues:**
```bash
# Remove force flag manually
sudo /usr/local/bin/zfs-remove-force-flag

# Check pool status
zpool status

# Import missing pool
sudo zpool import -f bpool
```

## Script Configuration Details

### Pool Import Configuration
- Both `rpool` and `bpool` use `cachefile=none`
- `zfs-import-scan.service` handles all imports
- No cache file dependencies

### First Boot Cleanup
- Automatic removal of force flags after successful boot
- Validates both pools are healthy before cleanup
- Manual cleanup tool available: `/usr/local/bin/zfs-remove-force-flag`

## Development Notes

### Recent Changes
- **2025-09-26:** Fixed first boot import reliability by switching to cachefile=none for both pools

### Testing Checklist
- [ ] Both pools import at first boot
- [ ] No force import required
- [ ] First boot cleanup service succeeds
- [ ] Manual cleanup tool works

### Future Improvements
- Monitor Ubuntu ZFS service changes
- Consider pool scrub automation
- Add more detailed health checks