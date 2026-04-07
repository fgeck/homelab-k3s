# Proxmox Host Debugging

Quick reference for analyzing `ministation` after an outage or unexpected reboot.

## 1. Establish basic state

```bash
uptime                  # how long since last (re)boot
date                    # current time
last reboot -n 10       # reboot history — "crash" = unclean shutdown
```

## 2. Errors from the current boot

```bash
# All errors + above
journalctl -b -p err..emerg --no-pager

# Errors in a specific time window
journalctl --since="2026-04-06 20:00" --until="2026-04-06 23:59" -p err..emerg --no-pager

# Just kernel messages with errors
journalctl -b -k --no-pager | grep -iE 'error|panic|oom|killed|fail|corrupt'
```

## 3. Previous (crashed) boot

```bash
# Errors from the boot before this one
journalctl -b -1 -p err..emerg --no-pager

# Last N lines of the previous boot (what was happening before crash)
journalctl -b -1 --no-pager -n 100

# Find where the previous boot's journal ends
journalctl -b -1 --no-pager -n 5
```

## 4. Storage & filesystem health

```bash
# Disk usage — look for 100% entries
df -h

# LVM thin pool fill — check Data% and Meta% columns
lvs

# EXT4 errors on a specific device
journalctl -b -1 --no-pager | grep -i 'ext4\|EXT4'

# Filesystem state + error count (offline, unmounted check)
tune2fs -l /dev/nvme0n1p4 | grep -E 'state|error|Last checked|Mount count'

# SMART status — all drives
smartctl -a /dev/sda  | grep -E 'overall|Reallocated|Pending|Uncorrectable|Temperature|Power_On'
smartctl -a /dev/sdb  | grep -E 'overall|Reallocated|Pending|Uncorrectable|Temperature|Power_On'
smartctl -a /dev/nvme0 | grep -E 'overall|Critical|Warning|Error|Percentage|Temperature'
```

## 5. NVMe / PCIe hardware errors

```bash
# PCIe AER errors (physical layer, correctable/uncorrectable)
journalctl -b --no-pager | grep -E 'pcieport|AER|RxErr|nvme.*error|PCIe Bus Error'

# Current dmesg — hardware and filesystem errors only
dmesg | grep -iE 'nvme|EXT4|ext4.*error|panic|oom|killed|pcieport|AER'
```

## 6. OOM / memory kills

```bash
# Out-of-memory kills
journalctl -b --no-pager | grep -iE 'oom|out of memory|killed process|memory peak'

# Killed services and their memory usage
journalctl -b --no-pager | grep -E 'killed|SIGBUS|signal.*BUS|memory peak'
```

## 7. Backup & service health

```bash
# PBS backup job errors
journalctl -b --no-pager | grep -iE 'TASK ERROR|backup.*fail|No space left|broken pipe|SIGBUS'

# Proxmox scheduler errors (vzdump)
journalctl -b --no-pager | grep 'pvescheduler' | grep -i 'error\|fail'

# Service crash/restart events
journalctl -b --no-pager | grep -E 'Main process exited|Failed with result|Scheduled restart'
```

## 8. Full timeline around a known event

```bash
# All logs ±30 minutes around the event time
journalctl --since="YYYY-MM-DD HH:MM" --until="YYYY-MM-DD HH:MM" --no-pager

# Same but errors only
journalctl --since="YYYY-MM-DD HH:MM" --until="YYYY-MM-DD HH:MM" -p err..emerg --no-pager
```

## 9. Filesystem repair (offline — unmount first)

```bash
# Only run when device is unmounted
umount /mnt/media
fsck -f -y /dev/nvme0n1p4

# Verify after
tune2fs -l /dev/nvme0n1p4 | grep 'Filesystem state'
```

## 10. Watch for errors in real time

```bash
# Stream all errors
journalctl -f -p err..emerg

# Stream NVMe/PCIe errors specifically
journalctl -f | grep -E 'pcieport|AER|RxErr|nvme'
```

## 11. PCIe error monitoring

```bash
# Count RxErr events since last boot — 0 is healthy, any number = investigate
journalctl -b -k --no-pager | grep -c 'RxErr'

# Show each RxErr event with timestamp
journalctl -b -k --no-pager | grep 'RxErr' | awk '{print $1, $2, $3, $NF}'

# Count per boot — run for -1, -2, -3 to see trend over time
journalctl -b -1 -k --no-pager | grep -c 'RxErr'
journalctl -b -2 -k --no-pager | grep -c 'RxErr'

# Continuous watch — prints a timestamped line every time a PCIe error occurs
journalctl -f -k | grep --line-buffered -E 'pcieport|AER|RxErr'

# Summary: errors per hour since boot (needs bash)
journalctl -b -k --no-pager | grep 'RxErr' \
  | awk '{print $3}' | cut -d: -f1 | sort | uniq -c
```

## 12. APT / repository maintenance

```bash
# Fix 401 Unauthorized — disable enterprise repos (no subscription)
# PBS enterprise repo
sed -i '/^Types:/i Enabled: false' /etc/apt/sources.list.d/pbs-enterprise.sources
# PVE enterprise repo
sed -i '/^Types:/i Enabled: false' /etc/apt/sources.list.d/pve-enterprise.sources

# Ensure no-subscription repos exist
cat /etc/apt/sources.list.d/pbs.list
# should contain: deb http://download.proxmox.com/debian/pbs trixie pbs-no-subscription

# Verify clean update
apt-get update 2>&1 | grep -E 'Err|error|401|WARNING' || echo "All repos OK"
```
