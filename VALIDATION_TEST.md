# ZFS Mirror Installation Validation Test (v4.3.1)

**Purpose**: Comprehensive end-to-end validation of the ZFS mirror root installation with rpool-authoritative hostid synchronization and auto-recovery features.

⚠️ **CRITICAL SAFETY WARNING**: This test will COMPLETELY WIPE the specified drives. Only run on dedicated test hardware or VMs!

## Example Command Format

Based on real usage, your command will look like:
```bash
./zfs_mirror_setup.sh hostname /dev/disk/by-id/nvme-VENDOR_SSD_1TB_SERIAL123456 /dev/disk/by-id/nvme-VENDOR_SSD_1TB_SERIAL789012
```

**Real example (anonymized from actual usage):**
```bash
./zfs_mirror_setup.sh rosa /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S7L***0Y118363M /dev/disk/by-id/nvme-CT1000T500SSD8_252***9D5ADF
```

⚠️ **Always use YOUR actual `/dev/disk/by-id/` paths - serials will be different!**

## Pre-Test Requirements

- [ ] Ubuntu 24.04 Live USB environment
- [ ] Two test drives of similar size (±10% tolerance)
- [ ] Internet connectivity
- [ ] **DEDICATED TEST HARDWARE** - NOT production systems!

---

## Phase 1: Pre-Installation Setup

### Step 1: Prepare Test Environment

```bash
# Boot Ubuntu 24.04 Live USB
# Verify internet connectivity
ping -c 3 google.com
```

**Expected Result**: ✅ Network connectivity confirmed

### Step 2: Identify Test Drives

```bash
# List all drives by stable ID - CRITICAL: Use /dev/disk/by-id/ paths ONLY!
ls -la /dev/disk/by-id/ | grep -v part

# ⚠️ NEVER use /dev/sdX names - they can change between reboots!
# Select FULL /dev/disk/by-id/ paths for testing
# Example paths (replace with YOUR actual drive IDs):
DRIVE1="/dev/disk/by-id/nvme-VENDOR_SSD_1TB_SERIAL123456"
DRIVE2="/dev/disk/by-id/nvme-VENDOR_SSD_1TB_SERIAL789012"

# VERIFY: Drives exist and are block devices
ls -la $DRIVE1 $DRIVE2
echo "Test drives selected: $DRIVE1 and $DRIVE2"
```

**Expected Result**: ✅ Two valid `/dev/disk/by-id/` paths identified

### Step 3: Verify Script Integrity

```bash
# Check script version
head -20 zfs_mirror_setup.sh | grep -E "(VERSION|v4\.3\.1)"

# Verify execute permissions
chmod +x zfs_mirror_setup.sh
```

**Expected Result**: ✅ Script shows v4.3.1 and is executable

---

## Phase 2: Installation Testing

### Step 4: Run Full Installation

```bash
# Execute installation with comprehensive logging
# Example command format (use YOUR actual drive paths):
sudo ./zfs_mirror_setup.sh --prepare hostname $DRIVE1 $DRIVE2 2>&1 | tee install.log

# Real example (anonymized):
# ./zfs_mirror_setup.sh rosa /dev/disk/by-id/nvme-VENDOR_SSD_1TB_SERIAL123456 /dev/disk/by-id/nvme-VENDOR_SSD_1TB_SERIAL789012

# Monitor output for:
# ✅ No errors during drive preparation
# ✅ ZFS pools created successfully
# ✅ Ubuntu base system installed
# ✅ GRUB configuration completed
# ✅ First-boot force import configured
# ✅ "Installation Successfully Completed!" message
```

**Expected Results**:
- [ ] Installation completes without errors
- [ ] No "pool was previously in use from another system" warnings
- [ ] Script validates and uses by-id paths throughout
- [ ] Shows "Installation Successfully Completed!" message

### Step 5: Pre-Reboot Validation

```bash
# Verify created files exist
ls -la /mnt/.zfs-force-import-firstboot        # Should exist
ls -la /mnt/etc/grub.d/99_zfs_firstboot        # Should exist
ls -la /mnt/etc/systemd/system/zfs-firstboot-cleanup.service  # Should exist

# Check utility scripts
ls -la /mnt/usr/local/bin/test-zfs-mirror
ls -la /mnt/usr/local/bin/sync-efi-partitions
ls -la /mnt/usr/local/bin/sync-grub-to-mirror-drives
ls -la /mnt/usr/local/bin/replace-drive-in-zfs-boot-mirror

# Verify pool configuration
zpool status
zpool get cachefile bpool rpool  # Should show "none" for both

# Check hostid alignment
hostid
zdb -l ${DRIVE1}-part3 | grep hostid
hexdump -C /mnt/etc/hostid | head -1
```

**Expected Results**:
- [ ] All required files and scripts created
- [ ] Both pools show `cachefile=none`
- [ ] Hostid consistent between pools and target system
- [ ] No pool errors or warnings

---

## Phase 3: First Boot Testing

### Step 6: Reboot and Monitor First Boot

```bash
# Remove USB and reboot
reboot
```

**Monitor During Boot**:
- [ ] GRUB shows "Ubuntu (ZFS first boot - force import)" option
- [ ] System boots automatically without manual intervention
- [ ] No "pool was previously in use from another system" errors
- [ ] Login prompt appears normally

**Expected Result**: ✅ Clean first boot with force import

### Step 7: Post-First-Boot Validation

```bash
# Verify pools imported correctly
zpool status
zpool list

# Check pool health
zpool status | grep -E "(ONLINE|DEGRADED|FAULTED)"

# Verify auto-cleanup worked
ls -la /.zfs-force-import-firstboot     # Should NOT exist
ls -la /etc/grub.d/99_zfs_firstboot     # Should NOT exist
systemctl is-enabled zfs-firstboot-cleanup.service  # Should be "disabled"

# Check cleanup logs
sudo journalctl -u zfs-firstboot-cleanup.service --no-pager
sudo journalctl -t zfs-firstboot-cleanup --no-pager
```

**Expected Results**:
- [ ] Both bpool and rpool show ONLINE status
- [ ] No degraded or faulted devices
- [ ] Force import files automatically removed
- [ ] Cleanup service disabled itself
- [ ] Cleanup logs show successful completion

---

## Phase 4: Second Boot Testing

### Step 8: Test Clean Boot Process

```bash
# Reboot to test clean import process
sudo reboot
```

**Monitor During Boot**:
- [ ] GRUB no longer shows force import option
- [ ] System boots normally with standard ZFS imports
- [ ] No force-related kernel parameters or GRUB entries

**Expected Result**: ✅ Clean boot without any force import configuration

### Step 9: System Functionality Testing

```bash
# Test all utility scripts
sudo /usr/local/bin/test-zfs-mirror

# Test EFI synchronization
sudo /usr/local/bin/sync-efi-partitions

# Test GRUB synchronization
sudo /usr/local/bin/sync-grub-to-mirror-drives

# Verify logging is working
sudo journalctl -t test-zfs-mirror --no-pager
sudo journalctl -t sync-efi-partitions --no-pager
sudo journalctl -t sync-grub-to-mirror-drives --no-pager
```

**Expected Results**:
- [ ] All utility scripts execute successfully
- [ ] Comprehensive system status reported
- [ ] EFI and GRUB sync complete without errors
- [ ] All operations properly logged with timestamps

---

## Phase 5: Drive Replacement Testing (Optional)

### Step 10: Simulate Drive Failure

```bash
# Take one drive offline to simulate failure
sudo zpool offline rpool ${DRIVE2}-part3
zpool status

# Verify degraded state
zpool status | grep -E "(DEGRADED|OFFLINE)"
```

**Expected Result**: ✅ Pool shows DEGRADED with one OFFLINE device

### Step 11: Test Drive Replacement Logic

```bash
# Test drive replacement detection (without actual replacement)
sudo /usr/local/bin/replace-drive-in-zfs-boot-mirror --help

# Test safety detection
sudo /usr/local/bin/replace-drive-in-zfs-boot-mirror /dev/disk/by-id/ata-NONEXISTENT-DRIVE

# Bring drive back online
sudo zpool online rpool ${DRIVE2}-part3
zpool status
```

**Expected Results**:
- [ ] Script detects offline/failed drives correctly
- [ ] Safety checks prevent replacement of healthy drives
- [ ] Usage instructions clear and accurate
- [ ] Pool returns to ONLINE status when drive restored

---

## Phase 6: Logging and Documentation Validation

### Step 12: Comprehensive Log Review

```bash
# Check all ZFS-related system logs
sudo grep -i zfs /var/log/syslog | tail -20

# Verify structured logging
sudo journalctl --list-boots
sudo journalctl -b 0 | grep -E "(zfs-firstboot|sync-grub|test-zfs)"

# Check for unexpected errors
sudo journalctl -p err --no-pager
```

**Expected Results**:
- [ ] All operations properly logged with timestamps
- [ ] No unexpected errors or warnings in system logs
- [ ] Structured logging working for all utility scripts

### Step 13: Documentation Consistency Check

```bash
# Verify all documented files exist
ls -la /usr/local/bin/ | grep -E "(test-zfs|sync-efi|sync-grub|replace-drive)"

# Check version consistency in documentation
grep -r "4\.3\.1" *.md

# Verify links in documentation work
curl -I https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html
```

**Expected Results**:
- [ ] All documented utility scripts exist and are executable
- [ ] Version references consistent across all files
- [ ] Documentation links accessible

---

## Final Validation Checklist

### ✅ Critical Success Criteria

- [ ] **Installation**: Completes without errors using `/dev/disk/by-id/` paths
- [ ] **First Boot**: Clean import with `zfs_force=1`, no manual intervention
- [ ] **Auto-Cleanup**: Force configuration automatically removed after first boot
- [ ] **Second Boot**: Clean import without any force flags
- [ ] **Utilities**: All scripts functional with proper logging
- [ ] **Logging**: Comprehensive audit trail in syslog and systemd journal
- [ ] **Safety**: Drive replacement includes safety checks and validation
- [ ] **Documentation**: All references accurate and links functional

### 🚨 Failure Investigation

If ANY step fails, collect diagnostics:

```bash
# Comprehensive log collection
sudo journalctl --no-pager > full-journal.log
sudo dmesg > dmesg.log
zpool status > pool-status.log
zpool history > pool-history.log
ls -la /etc/grub.d/ > grub-scripts.log
systemctl list-units | grep zfs > zfs-services.log

# Review installation log
grep -i error install.log
grep -i fail install.log

# Check for common issues
sudo journalctl -u zfs-firstboot-cleanup.service --no-pager
zpool import  # Check for importable pools
```

---

## Test Completion

**Date Tested**: _______________
**Tester**: _______________
**Test Environment**: _______________
**Ubuntu Version**: _______________
**ZFS Version**: _______________

**Overall Result**:
- [ ] ✅ ALL TESTS PASSED - Ready for production use
- [ ] ❌ SOME TESTS FAILED - Requires investigation
- [ ] ⚠️ NEEDS RETESTING - After fixes applied

**Notes**:
```
_________________________________________________
_________________________________________________
_________________________________________________
```

---

**⚠️ Remember**: This test completely wipes the specified drives. Only run on dedicated test hardware!

For issues or questions, refer to:
- **TROUBLESHOOTING.md** - Common issues and solutions
- **README.md** - Complete documentation
- **CHANGELOG.md** - Version history and changes