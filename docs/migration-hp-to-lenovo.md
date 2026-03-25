# Migration Guide: HP EliteDesk → Lenovo ThinkCentre M70Q Gen2

## Lessons Learned (read before starting)

Hard-won knowledge from the actual migration. Read this first.

### Proxmox installer ignores `hdsize`
The Proxmox installer Advanced option `hdsize=500` to limit the install to 500GB **does not reliably work** — the installer often takes the full disk anyway. If you need a separate media partition on the same NVMe, verify with `lsblk` immediately after install. If p3 covers the full disk, shrinking the LVM thin pool afterwards is too complex and risky. Use the intenso-hdd as the media drive instead (see Phase 6.6).

### PBS repository on Proxmox 9 uses `trixie` not `bookworm`
Proxmox 9 is based on Debian 13 (trixie). The PBS apt repository must use `trixie`:
```
deb http://download.proxmox.com/debian/pbs trixie pbs-no-subscription
```
Using `bookworm` causes dependency errors (`libsgutils2-1.46-2`, `libapt-pkg6.0` not installable).

### PBS datastore mount is owned by PBS — never put it in fstab
When `datastore.cfg` uses `backing-device`, PBS mounts the WD HDD itself via systemd at startup. The mount point is `/mnt/datastore/wd-hdd-600/` and PBS creates it automatically. **Do not add the WD HDD to `/etc/fstab`** — if both fstab and PBS try to mount the same device, PBS loses and reports "datastore not mounted" or 400 Bad Request errors. Only the intenso-hdd goes in fstab.

### Lenovo ThinkCentre M70Q Gen2 BIOS boot quirks
- **Boot key**: F12 for one-time boot menu, F1 for BIOS setup
- **UEFI only**: this model has no Legacy/CSM mode
- **Boot order**: set in **Startup** tab → **Boot Priority Order**. Remove network PXE entries from the list — they cause the machine to fall back to BIOS setup when PXE fails
- **EFI fallback**: if the machine ignores the Proxmox EFI entry, copy grub to the universal fallback path:
  ```bash
  mkdir -p /boot/efi/EFI/BOOT
  cp /boot/efi/EFI/proxmox/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  ```
- **FQDN required**: the Proxmox installer requires a fully qualified hostname (needs a dot). Use `ministation.local` to match the existing PBS TLS cert CN exactly

### GRUB auto-boot
After install, GRUB may wait for a keypress instead of auto-booting. Fix:
```bash
nano /etc/default/grub
# Set:
# GRUB_TIMEOUT=5
# GRUB_TIMEOUT_STYLE=countdown
update-grub
```

### rsync to exFAT target
exFAT does not support Unix permissions or ownership. Always use:
```bash
rsync -rlth --info=progress2 --no-perms --no-owner --no-group <src> <dst>
```
`--info=progress2` shows overall progress on a single line instead of every filename. `--progress` causes "Operation not permitted" errors on exFAT.

### ext4 filesystem corruption
If rsync reports `Structure needs cleaning (error 117)`, the source ext4 filesystem has corruption. Fix before proceeding:
```bash
umount /dev/nvme1n1p1
fsck.ext4 -y /dev/nvme1n1p1
mount /dev/nvme1n1p1 /mnt/data-ssd
```
Then re-run rsync — it will skip already-transferred files and only retry failed ones.

---

## Overview

Migrating the full Proxmox homelab stack from the HP EliteDesk to the Lenovo ThinkCentre M70Q Gen2.

### Hardware inventory

| Drive | Where now | Moves to | Notes |
|---|---|---|---|
| 256GB SK Hynix NVMe (`nvme0n1`) | HP M.2 slot 1 (Proxmox OS) | Stays in HP | Sold with the machine |
| 2TB WD Red SN700 NVMe (`nvme1n1`) | HP M.2 slot 2 (k3s passthrough) | Lenovo M.2 slot | Contains 895GB media data — must preserve |
| 596GB WD HDD (`sda`) | HP SATA (PBS datastore) | Lenovo SATA | PBS backups live here |
| 1.9TB WD HDD (`sdb`) | HP SATA (intenso-hdd / media) | Lenovo SATA | Used as staging for this migration |

### What runs on the cluster

| ID | Name | Type | IP | Notes |
|---|---|---|---|---|
| 140 | k3s-controlplane | VM | 192.168.178.130 | 24GB RAM, 60GB disk + 2TB NVMe passthrough |
| 200 | homeassistant | VM (HAOS) | 192.168.178.150 | 6GB RAM, 36GB disk |
| 111 | pihole | LXC | 192.168.178.111 | 512MB RAM, 8GB disk |

### Key IPs to preserve

| Service | IP |
|---|---|
| Proxmox host | 192.168.178.10 |
| k3s VM | 192.168.178.130 |
| Home Assistant | 192.168.178.150 |
| Pi-hole | 192.168.178.111 |

---

## Phase 1 — Preparation (HP still running, zero downtime)

### 1.1 — Check free space on intenso-hdd

```bash
df -h /mnt/intenso-hdd
# Need at least 900GB free for the 2TB media backup
```

### 1.2 — Back up 895GB of 2TB media data to intenso-hdd

The 2TB NVMe will be wiped during Proxmox install. All data must be copied first.

```bash
ssh -i ~/.ssh/elitemox_ed25519 root@192.168.178.10

# Mount the 2TB (fstab entry exists as /mnt/data-ssd)
mount /mnt/data-ssd

# Create destination
mkdir -p /mnt/intenso-hdd/2tb-ssd-backup

# Copy everything — rsync handles resume if interrupted
rsync -rlth --info=progress2 --no-perms --no-owner --no-group \
  /mnt/data-ssd/ /mnt/intenso-hdd/2tb-ssd-backup/

# Verify sizes match when done
df -h /mnt/data-ssd
df -h /mnt/intenso-hdd
```

> ⚠️ This is **irreplaceable data** (photos, media). Do not proceed to Phase 2 until rsync completes without errors.

### 1.3 — Save all Proxmox and PBS config files

```bash
mkdir -p /mnt/intenso-hdd/proxmox-migration-config

# PVE config
tar czf /mnt/intenso-hdd/proxmox-migration-config/pve-etc.tar.gz \
  /etc/pve/storage.cfg \
  /etc/pve/datacenter.cfg \
  /etc/pve/jobs.cfg
# NOTE: /etc/pve/nodes/ministation/ is intentionally excluded — it contains
# hardware-specific config (network, BIOS mappings) that must be regenerated
# fresh on the new machine. VMs are restored from PBS, not from LVM snapshots.

# PBS config (includes auth keys, TLS cert, datastore, users, prune jobs, notifications)
tar czf /mnt/intenso-hdd/proxmox-migration-config/pbs-etc.tar.gz \
  /etc/proxmox-backup/

# fstab and crontab for reference
cp /etc/fstab /mnt/intenso-hdd/proxmox-migration-config/fstab.bak
crontab -l > /mnt/intenso-hdd/proxmox-migration-config/crontab.bak
```

### 1.4 — Run fresh PBS backups of all VMs

Fresh backups already ran today (~01:30), but run one final set right before shutdown:

```bash
vzdump 140 --storage pbs-local --mode snapshot --compress zstd
vzdump 200 --storage pbs-local --mode snapshot --compress zstd
vzdump 111 --storage pbs-local --mode snapshot --compress zstd

# Confirm they completed successfully
pvesm list pbs-local | grep "$(date +%Y-%m-%d)"
```

---

## Phase 2 — Shutdown and Physical Migration (downtime begins)

### 2.1 — Shut everything down cleanly

```bash
qm shutdown 140   # k3s — wait for it to fully stop
qm shutdown 200   # Home Assistant
pct stop 111      # pihole

# Confirm all stopped
qm list && pct list

# Shutdown Proxmox
shutdown -h now
```

### 2.2 — Physical hardware steps

1. Power off the HP EliteDesk
2. Remove from HP:
   - **2TB WD Red SN700 NVMe** from M.2 slot 2
   - **596GB WD HDD** from SATA
   - **1.9TB WD HDD** from SATA
3. Install into Lenovo ThinkCentre M70Q Gen2:
   - 2TB NVMe → M.2 slot
   - 596GB HDD + 1.9TB HDD → SATA bays

> ⚠️ The M70Q Gen2 has **1× built-in 2.5" SATA bay**. A second bay requires the optional storage bracket accessory. Confirm you have room for both HDDs before proceeding — if not, use a USB-SATA dock temporarily.

---

## Phase 3 — Proxmox Fresh Install on the Lenovo

### 3.1 — Install Proxmox VE

- Boot from Proxmox VE USB installer (latest PVE 9.x) — use **F12** on the Lenovo splash screen for one-time boot menu
- **Target disk**: 2TB WD Red SN700 NVMe
- The installer will wipe and repartition the drive — expected, data was backed up
- **Hostname**: `ministation.local` — must use FQDN format (installer requires a dot). Use exactly `ministation.local` to match the PBS TLS cert CN
- **IP address**: `192.168.178.10` — keep identical
- Set same root password as before
- In the disk options **Advanced** screen: try setting `hdsize` to `500` to reserve space for a media partition — but **do not rely on this working**. The installer often ignores it and takes the full disk. Verify with `lsblk` after install and see Phase 6.1 for both outcomes.

### 3.2 — Fix GRUB auto-boot

The installer may leave GRUB waiting for a keypress on every boot. Fix immediately:

```bash
nano /etc/default/grub
# Set these two lines:
# GRUB_TIMEOUT=5
# GRUB_TIMEOUT_STYLE=countdown

update-grub
```

### 3.3 — Fix EFI boot entry (if machine boots into BIOS instead of Proxmox)

The Lenovo M70Q Gen2 BIOS sometimes ignores the Proxmox EFI entry. Copy grub to the universal fallback path:

```bash
mkdir -p /boot/efi/EFI/BOOT
cp /boot/efi/EFI/proxmox/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
```

Also in the BIOS (F1): go to **Startup** tab → **Boot Priority Order** → remove all network/PXE entries from the list. PXE entries cause the machine to fall back to BIOS setup when the network boot fails.

### 3.4 — Post-install: restore fstab mounts

After first boot — **only mount the intenso-hdd here**. The PBS WD HDD must NOT be in fstab.

```bash
mkdir -p /mnt/intenso-hdd

# Edit /etc/fstab and add ONLY this one line (intenso-hdd only):
# UUID=<INTENSO_HDD_UUID>  /mnt/intenso-hdd  exfat  defaults,nofail  0  2

mount /mnt/intenso-hdd

# Verify
df -h /mnt/intenso-hdd
```

> ⚠️ **Do NOT add the WD HDD (UUID=`<WD_HDD_PBS_UUID>`) to fstab.** When `datastore.cfg` uses `backing-device`, PBS mounts the drive itself at startup via systemd. If fstab also mounts it, PBS and the OS fight over the device and PBS reports "datastore not mounted" or 400 errors. Let PBS own it entirely.

---

## Phase 4 — Restore PBS Server

### 4.1 — Install PBS

Proxmox 9 is based on Debian 13 (trixie) — the PBS repo must use `trixie`, not `bookworm`. Using `bookworm` causes unsatisfied dependency errors.

```bash
# Add the correct PBS repository for Proxmox 9 / Debian trixie
echo "deb http://download.proxmox.com/debian/pbs trixie pbs-no-subscription" \
  > /etc/apt/sources.list.d/pbs.list

apt update && apt install -y proxmox-backup-server
```

### 4.2 — Restore PBS config

```bash
# Stop PBS before overwriting config
systemctl stop proxmox-backup proxmox-backup-proxy

# Restore all config files
tar xzf /mnt/intenso-hdd/proxmox-migration-config/pbs-etc.tar.gz -C /

# This restores:
#   authkey.key / authkey.pub  — PBS identity, existing backup tokens stay valid
#   proxy.key + proxy.pem      — TLS cert, fingerprint stays identical
#   datastore.cfg              — wd-hdd-600 datastore definition
#   user.cfg                   — backup-client@pbs user
#   acl.cfg                    — permissions
#   prune.cfg                  — prune job (keep-last 7, runs at 06:05)
#   notifications.cfg          — Telegram webhook

# Restart PBS
systemctl start proxmox-backup proxmox-backup-proxy
```

### 4.3 — Verify the TLS fingerprint is preserved

This is critical — the PVE `storage.cfg` references the PBS fingerprint. Because the original `proxy.key` + `proxy.pem` are restored, the fingerprint is identical and no changes are needed anywhere.

```bash
openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -fingerprint -sha256
# Must show: <YOUR_PBS_FINGERPRINT>
```

### 4.4 — Verify the PBS datastore is accessible

```bash
proxmox-backup-manager datastore list
# Should show wd-hdd-600

proxmox-backup-manager datastore show wd-hdd-600
# Should show backing-device UUID <WD_HDD_PBS_UUID>

# List backup snapshots
proxmox-backup-client list --repository backup-client@pbs@localhost:wd-hdd-600
```

---

## Phase 5 — Restore PVE Config and VMs

### 5.0 — Extract the saved config archive

```bash
# Verify contents first
tar tzf /mnt/intenso-hdd/proxmox-migration-config/pve-etc.tar.gz

# Extract — but do NOT let it overwrite storage.cfg yet
# We handle each file manually in 5.1 below
tar xzf /mnt/intenso-hdd/proxmox-migration-config/pve-etc.tar.gz \
  -C /tmp/pve-restore
```

### 5.1 — Restore PVE config

There are three config files to handle. Each is treated differently.

---

#### 5.1.1 — `storage.cfg`

**Do NOT overwrite this file.** The new Proxmox install generates it with entries tied to the new machine's LVM setup. Overwriting it would break storage.

After a fresh install, the file looks exactly like this:

```
dir: local
	path /var/lib/vz
	content vztmpl,iso,backup

lvmthin: local-lvm
	thinpool data
	vgname pve
	content rootdir,images
```

You need to **append** only the `pbs-local` block. The values below are the exact values from the old machine — copy them verbatim:

```bash
cat >> /etc/pve/storage.cfg << 'EOF'

pbs: pbs-local
	datastore wd-hdd-600
	server 192.168.178.10
	content backup
	fingerprint <YOUR_PBS_FINGERPRINT>
	prune-backups keep-all=1
	username backup-client@pbs
EOF
```

Verify the result looks correct:

```bash
cat /etc/pve/storage.cfg
# Should show: local block + local-lvm block + pbs-local block
```

The PBS entry will work immediately because:
- `server 192.168.178.10` — same IP as before
- `fingerprint` — unchanged (you restored the original `proxy.pem` in Phase 4)
- `username backup-client@pbs` — user exists in the restored PBS config

---

#### 5.1.2 — `jobs.cfg`

This file defines the three scheduled vzdump backup jobs. Safe to write directly — the new install creates an empty `jobs.cfg`.

Write the file directly with the known content from the old machine:

```bash
cat > /etc/pve/jobs.cfg << 'EOF'
vzdump: backup-f4f23ee8-6be3
	compress zstd
	enabled 1
	fleecing 0
	mode snapshot
	notes-template {{guestname}}
	schedule 02:15
	storage pbs-local
	vmid 200

vzdump: backup-ba8f29ba-973c
	compress zstd
	enabled 1
	fleecing 0
	mode snapshot
	notes-template {{guestname}}
	schedule 02:00
	storage pbs-local
	vmid 111

vzdump: backup-1d25bba8-fcc5
	enabled 1
	fleecing 0
	mode snapshot
	notes-template {{guestname}}
	schedule 02:30
	storage pbs-local
	vmid 140
EOF
```

> The backup job IDs (e.g. `backup-f4f23ee8-6be3`) are preserved intentionally — keeping them means the jobs appear in the PVE UI with their history intact.

---

#### 5.1.3 — `datacenter.cfg`

Only contains keyboard layout. Write directly:

```bash
cat > /etc/pve/datacenter.cfg << 'EOF'
keyboard: en-us
EOF
```

---

#### 5.1.4 — Set the backup-client PBS password

The `backup-client@pbs` user needs its password set in PBS so PVE can authenticate when running backup jobs. This is stored in PBS, not PVE — it was restored in Phase 4.2, but verify it works:

```bash
# Test authentication from PVE to PBS
pvesm list pbs-local | head -5
# If this returns backup snapshots, credentials are working
# If it returns an auth error, reset the password:
proxmox-backup-manager user update backup-client@pbs --password '<YOUR_PBS_BACKUP_CLIENT_PASSWORD>'
```

The PVE side stores the password in `/etc/pve/priv/storage/<storage-id>.pw`. When you add the `pbs-local` storage via the config file above, PVE will prompt for the password the first time you use it via the UI, or you can set it now:

```bash
mkdir -p /etc/pve/priv/storage
echo -n '<YOUR_PBS_BACKUP_CLIENT_PASSWORD>' > /etc/pve/priv/storage/pbs-local.pw
chmod 600 /etc/pve/priv/storage/pbs-local.pw
```

### 5.2 — Verify PBS storage is visible in PVE

```bash
pvesm list pbs-local | head -10
# Should immediately show existing backups — same fingerprint, same IP, same credentials
```

### 5.3 — Restore VMs from PBS backups

```bash
# k3s VM (use most recent snapshot from today)
qmrestore pbs-local:backup/vm/140/2026-03-24T17:53:59Z 140 --storage local-lvm --unique false ; qmrestore pbs-local:backup/vm/200/2026-03-24T17:54:54Z 200 --storage local-lvm --unique false ; qmrestore pbs-local:backup/vm/99999//2026-03-24T19:09:22Z 99999 --storage local-lvm --unique false ; pct restore 111 pbs-local:backup/ct/111/2026-03-24T17:55:29Z  --storage local-lvm --unique false
```

> Use the snapshot timestamps from your actual run (step 1.4), not the ones above.

---

## Phase 6 — Storage Layout on the New Machine

### 6.1 — Why the split is necessary

If all data (k3s PVCs + media/photos) lived inside the k3s VM disk on `local-lvm`, PBS would back up all of it every night. The numbers don't work:

| What | Size |
|---|---|
| k3s VM disk (current) | 60GB |
| HA VM disk | 36GB |
| pihole LXC | 6GB |
| **Current total per PBS snapshot** | **~102GB** |
| PBS HDD capacity | 596GB |
| PBS retention | 7 snapshots |

If media/photos (~895GB) moved inside the k3s VM disk, a single snapshot would exceed the entire PBS HDD. Even with PBS deduplication it would fail within days.

**Ideal solution**: split the 2TB NVMe into two partitions at install time using `hdsize=500` in the Proxmox installer Advanced options. However, **the Proxmox installer often ignores `hdsize` and takes the full disk**. If that happens (p3 covers the full 1.8TB), shrinking the LVM thin pool afterwards is complex and risky — not worth it.

**Practical solution**: use the **intenso-hdd (1.9TB USB HDD)** as the media drive instead. It is already mounted, already contains the media data, and serves the same purpose. For read-heavy workloads like Jellyfin and Immich it is adequate. Pass it through to k3s as `scsi1` with `backup=0`.

> ⚠️ If the installer DID respect `hdsize=500` and left free space, follow steps 6.2–6.5 to create a dedicated NVMe partition. If not (p3 = full disk), skip to **6.6 — Use intenso-hdd as media drive**.

**Target layout (NVMe partition, if installer respected hdsize):**

```
nvme0n1 (2TB WD Red SN700)
├── p1     1MB      BIOS boot
├── p2     1GB      /boot/efi
├── p3   ~499GB     LVM physical volume
│   ├── pve-root    ~96GB   Proxmox OS
│   ├── pve-swap    ~8GB    swap
│   └── pve-data   ~395GB  LVM thin pool (local-lvm)
│       ├── vm-140-disk-0   60GB   k3s OS disk  (PBS backed ✅)
│       ├── vm-200-disk-1   36GB   Home Assistant (PBS backed ✅)
│       └── vm-111-disk-0    8GB   pihole         (PBS backed ✅)
└── p4   ~1.3TB     raw ext4 partition  ← passthrough to k3s as scsi1, backup=0 ❌
    └── media, photos, icloud-staging, usenet
```

**Fallback layout (installer took full disk — use intenso-hdd):**

```
nvme0n1 (2TB WD Red SN700) — full disk LVM
└── p3   ~1.8TB    LVM physical volume
    ├── pve-root    ~96GB   Proxmox OS
    ├── pve-swap    ~8GB    swap
    └── pve-data   ~1.7TB  LVM thin pool (local-lvm) — VMs + k3s PVCs only

intenso-hdd (1.9TB USB) — media drive
└── passed through to k3s as scsi1, backup=0 ❌
    └── media, photos, icloud-staging, usenet (already here from migration backup)
```

### 6.2 — Tell the Proxmox installer to use only 500GB

> **Skip this step if Proxmox is already installed.** Check with `lsblk /dev/nvme0n1` — if p3 covers the full 1.8TB, the installer took the whole disk. Jump to **6.6**.

The Proxmox installer has an **Advanced** option in the disk selection screen that lets you set the target disk size. Use this to cap the install at 500GB, leaving the rest of the drive unpartitioned.

During install:
1. Select the 2TB NVMe as the target disk
2. Click **Options** (or **Advanced**)
3. Set **hdsize** to `500` (GB)
4. Complete the install normally

After install, Proxmox will have used only the first 500GB. The remaining ~1.3TB is unallocated and visible as free space.

### 6.3 — Create the media partition on the remaining space

After first boot on the new machine:

```bash
# Confirm the layout — p3 should end around 500GB, rest is free
lsblk /dev/nvme0n1
fdisk -l /dev/nvme0n1

# Create a new partition in the remaining free space
fdisk /dev/nvme0n1
# → n  (new partition)
# → p  (primary)
# → accept default partition number (likely 4)
# → accept default start sector (first free sector after p3)
# → accept default end sector (end of disk)
# → w  (write and exit)

# Reload partition table
partprobe /dev/nvme0n1

# Format as ext4 with label 'data'
mkfs.ext4 -L data /dev/nvme0n1p4

# To relabel an already-formatted partition:
# e2label /dev/nvme0n1p4 data

# Verify
lsblk -o NAME,SIZE,FSTYPE,LABEL /dev/nvme0n1
```

### 6.4 — Mount the media partition on the host

```bash
# Create mount point
mkdir -p /mnt/media

# Get the UUID of the new partition
blkid /dev/nvme0n1p4

# Add to fstab (replace UUID with actual value from blkid)
echo 'UUID=<new-uuid>  /mnt/media  ext4  defaults,nofail  0  2' >> /etc/fstab

# Mount it
mount /mnt/media

# Verify
df -h /mnt/media
# Should show ~1.3TB available
```

### 6.5 — Restore media data from intenso-hdd

```bash
rsync -rlth --info=progress2 --no-perms --no-owner --no-group \
  /mnt/intenso-hdd/2tb-ssd-backup/ /mnt/media/

# Verify all dirs are present
ls /mnt/media/
# Should show: complete, icloud-staging, incomplete, media, old-pics, photos, usenet

df -h /mnt/media
```

### 6.5.1 — Fix ownership after rsync

All k3s workloads mounting `/mnt/media` via hostPath run as **uid=1000, gid=1000**
(SABnzbd, Jellyfin, Radarr, Sonarr, Immich, iCloud pipeline, immich-windows-backup).
The `--no-owner --no-group` flags leave files owned by root on a fresh ext4 partition. Fix before starting VMs:

```bash
chown -R 1000:1000 /mnt/media
```

> `fsGroupChangePolicy: OnRootMismatch` on these pods only applies to PVC-backed volumes, not hostPath mounts.
> For hostPath, host filesystem ownership is authoritative — Kubernetes will not fix it automatically.

### 6.6 — Use intenso-hdd as media drive (fallback — installer took full disk)

> **Use this step if the installer used the full 1.8TB for LVM** (no free space for p4).
> Skip if you successfully created p4 in steps 6.2–6.5.

The intenso-hdd (1.9TB USB, already mounted at `/mnt/intenso-hdd`) already contains the media data from the migration backup. It will serve as the `scsi1` passthrough to k3s instead of a dedicated NVMe partition.

The data is already in `/mnt/intenso-hdd/2tb-ssd-backup/` — it needs to be moved to the root of the drive so k3s sees the same directory structure as before:

```bash
# Move data from backup subdirectory to root of intenso-hdd
# (rsync to avoid issues with cross-device move)
rsync -rlth --info=progress2 --no-perms --no-owner --no-group \
  /mnt/intenso-hdd/2tb-ssd-backup/ /mnt/intenso-hdd/data/

# Verify structure
ls /mnt/intenso-hdd/data/
# Should show: complete, icloud-staging, incomplete, media, old-pics, photos, usenet
```

The intenso-hdd is a USB drive — it cannot be passed through as a raw block device to k3s the same way an NVMe partition can. Instead, mount it on the host and share the path via hostPath in k3s (same as the current Immich setup uses `hostPath: /mnt/data/photos`).

Add to fstab so it survives reboots (UUID unchanged from old machine):

```bash
# Should already be in fstab from Phase 3.2 — verify
grep intenso /etc/fstab
# UUID=<INTENSO_HDD_UUID>  /mnt/intenso-hdd  exfat  defaults,nofail  0  2
```

### 6.7 — Remove the old scsi1 entry from the restored k3s VM config

The PBS backup of VM 140 still contains the `scsi1` passthrough entry pointing to the old NVMe by-id path. That path no longer exists — remove it before starting the VM, then re-add it pointing to the new partition:

```bash
# Check what the restored config contains
qm config 140 | grep scsi

# Remove the stale passthrough entry
qm set 140 -delete scsi1

# Add the new partition as passthrough (backup=0 = excluded from PBS)
qm set 140 -scsi1 /dev/disk/by-id/nvme-WD_Red_SN700_2000GB_<NVME_SERIAL>-part4,backup=0

# Verify
qm config 140 | grep scsi
# scsi0: local-lvm:vm-140-disk-0,size=60G
# scsi1: /dev/disk/by-id/nvme-WD_Red_SN700_...-part4,backup=0,size=...
```

> The by-id path uses the drive serial `<NVME_SERIAL>` which is a physical property of the drive — it does not change after reformatting.

### 6.7 — Verify PBS backup scope is correct

```bash
# Run a test backup of VM 140 and confirm it only backs up scsi0
vzdump 140 --storage pbs-local --mode snapshot --compress zstd

# Check the resulting snapshot size — should be ~60GB, not 1.3TB
pvesm list pbs-local | grep "vm/140" | tail -1
```

### 6.8 — Future NAS migration path

When the NAS arrives:

1. Copy data from `/mnt/media` (the 1.3TB partition) to the NAS
2. In k3s: replace the `scsi1` hostPath PersistentVolumes with NFS PersistentVolumes pointing to the NAS — the PV definitions change, the workloads (Jellyfin, Immich) do not
3. Remove `scsi1` from VM 140 config
4. The 1.3TB partition becomes free space — see Phase 9 for absorbing it into `local-lvm`

---

## Phase 8 — Final Checks

### 8.1 — Start everything up

```bash
qm start 140   # k3s
qm start 200   # Home Assistant
pct start 111  # pihole
```

### 8.2 — Restore crontab

```bash
crontab /mnt/intenso-hdd/proxmox-migration-config/crontab.bak

# Verify
crontab -l
# Should include:
#   @reboot echo powersave → cpu scaling_governor
#   (commented) PBS backup client jobs
```

### 8.3 — Verify k3s cluster is healthy

```bash
# Give Flux ~5 minutes to reconcile after k3s starts
ssh fgeck@192.168.178.130 "kubectl get nodes"
ssh fgeck@192.168.178.130 "kubectl get kustomizations -A"
```

### 8.4 — Run a test PBS backup

```bash
vzdump 111 --storage pbs-local --mode snapshot --compress zstd
# Confirm it lands in pbs-local and Telegram notification fires
pvesm list pbs-local | grep 111 | tail -3
```

### 8.5 — Verify PBS scheduled jobs are active

```bash
systemctl list-timers | grep -i backup
# Should show prune job at 06:05 and backup jobs
```

---

## Checklist — Things NOT to Forget

- [ ] Phase 1.2 rsync completed **without errors** before proceeding
- [ ] Phase 1.4 fresh backups ran and appear in `pvesm list pbs-local`
- [ ] Proxmox hostname set to exactly `ministation` during install
- [ ] Proxmox IP set to `192.168.178.10` during install
- [ ] PBS `proxy.pem` fingerprint matches expected value after restore
- [ ] Both HDDs mounted and accessible before restoring VMs
- [ ] VM 140 `scsi1` updated to new partition path on 2TB
- [ ] 2TB data restored from intenso-hdd backup (`/mnt/media/` has all dirs)
- [ ] `/mnt/media` ownership set to `1000:1000` (`chown -R 1000:1000 /mnt/media`)
- [ ] Pi-hole running and resolving DNS (`192.168.178.111`)
- [ ] Home Assistant reachable at `192.168.178.150:8123`
- [ ] k3s Flux reconciliation healthy
- [ ] Test PBS backup completed and Telegram notification received
- [ ] Crontab restored (CPU governor + PBS client jobs)
- [ ] `local-lvm` usage healthy (was 87% on old machine — new LVM on 2TB has plenty of room)

---

## Phase 9 — NAS Migration: Absorb Media Partition into local-lvm

> **When**: Only after the NAS is available, data has been migrated, and `scsi1` has been removed from VM 140.

### 9.1 — Migrate data to NAS and update k3s

```bash
# On the Proxmox host — copy data to NAS (adjust NAS mount point)
rsync -rlth --info=progress2 /mnt/media/ /mnt/nas/photos/

# In k3s — replace hostPath PVs with NFS PVs pointing to NAS
# (update the relevant PV/PVC manifests in homelab-k3s repo, let Flux reconcile)

# Remove scsi1 passthrough from k3s VM
qm set 140 -delete scsi1

# Verify VM config no longer has scsi1
qm config 140 | grep scsi
```

### 9.2 — Unmount and remove fstab entry

```bash
# Unmount the media partition
umount /mnt/media

# Remove the fstab entry
# Edit /etc/fstab and delete the line containing /mnt/media
nano /etc/fstab

# Verify it's gone
mount | grep /mnt/media   # should return nothing
```

### 9.3 — Delete the partition

```bash
# Confirm current layout before touching anything
lsblk /dev/nvme0n1
fdisk -l /dev/nvme0n1

# Delete partition 4 (the 1.3TB media partition)
fdisk /dev/nvme0n1
# → d  (delete partition)
# → 4  (partition number)
# → w  (write and exit)

# Reload partition table
partprobe /dev/nvme0n1

# Confirm p4 is gone
lsblk /dev/nvme0n1
```

### 9.4 — Extend the LVM PV to reclaim the space

```bash
# Tell LVM the physical volume (p3) has grown
pvresize /dev/nvme0n1p3

# Verify PV now shows the additional free space
pvs

# Extend the data thin pool to use all free space
lvextend -l +100%FREE pve/data

# Verify local-lvm now shows the extra space
pvesm status | grep local-lvm
```

No reboot required. No downtime. Proxmox picks up the freed space in `local-lvm` immediately — the thin pool just gets ~1.3TB larger.

---

## Reference — Credentials and Identifiers

| Item | Value |
|---|---|
| PBS fingerprint | `<YOUR_PBS_FINGERPRINT>` — get with `openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -fingerprint -sha256` |
| PBS backup-client password | stored in PBS — set with `proxmox-backup-manager user update backup-client@pbs --password '<YOUR_PASSWORD>'` |
| PBS datastore backing UUID | `<WD_HDD_PBS_UUID>` (596GB WD HDD / sda1) |
| intenso-hdd UUID | `<INTENSO_HDD_UUID>` |
| 2TB NVMe old data UUID | `<NVME_OLD_DATA_UUID>` (will change after reformat) |
| 2TB NVMe serial | `<NVME_SERIAL>` |
