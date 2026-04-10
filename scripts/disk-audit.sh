#!/usr/bin/env bash

# Disk usage audit for all VMs, LXCs, and storage partitions.
# Sources: Proxmox pvesh API (LXC/VM allocation), SSH into k3s guest,
#          Proxmox host mounts (/mnt/media, /mnt/intenso-hdd, PBS datastore).

set -o errexit
set -o pipefail

CONFIG_ENV="$(dirname "$0")/secrets/config.env"
if [[ ! -f "$CONFIG_ENV" ]]; then
  echo "Error: $CONFIG_ENV not found. Copy scripts/secrets/config.env.example and fill in your values." >&2
  exit 1
fi
# shellcheck source=secrets/config.env
source "$CONFIG_ENV"

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

_section() { printf "\n${BOLD}── %s${RESET}\n" "$*"; }

_bar() {
  local pct="$1"
  local width=20
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local color
  if   [[ "$pct" -lt 70 ]]; then color="$GREEN"
  elif [[ "$pct" -lt 85 ]]; then color="$YELLOW"
  else                            color="$RED"
  fi
  printf "${color}["
  printf '%0.s█' $(seq 1 "$filled") 2>/dev/null || printf '%*s' "$filled" | tr ' ' '#'
  printf '%0.s░' $(seq 1 "$empty")  2>/dev/null || printf '%*s' "$empty"  | tr ' ' '-'
  printf "]${RESET}"
}

_row() {
  local label="$1"
  local used="$2"
  local total="$3"
  local pct="$4"
  local note="${5:-}"
  local color
  if   [[ "$pct" -lt 70 ]]; then color="$GREEN"
  elif [[ "$pct" -lt 85 ]]; then color="$YELLOW"
  else                            color="$RED"
  fi
  printf "  %-42s %6s / %-6s  %s ${color}%3d%%${RESET}  ${DIM}%s${RESET}\n" \
    "$label" "$used" "$total" "$(_bar "$pct")" "$pct" "$note"
}

_row_na() {
  local label="$1"
  local note="${2:-}"
  printf "  %-42s ${DIM}n/a${RESET}  ${DIM}%s${RESET}\n" "$label" "$note"
}

_pbs() {
  ssh -i "$PBS_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "${PBS_USER}@${PBS_HOST}" "$@" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
_section "Proxmox Host — Storage Partitions"
# ─────────────────────────────────────────────────────────────────────────────

printf "  %-42s %6s   %-6s  %s\n" "Mount / Volume" "Used" "Total" "                       Usage"
printf "  %s\n" "$(printf '─%.0s' $(seq 1 90))"

while IFS= read -r line; do
  fs=$(echo "$line"    | awk '{print $1}')
  size=$(echo "$line"  | awk '{print $2}')
  used=$(echo "$line"  | awk '{print $3}')
  avail=$(echo "$line" | awk '{print $4}')
  pct=$(echo "$line"   | awk '{print $5}' | tr -d '%')
  mp=$(echo "$line"    | awk '{print $6}')
  case "$mp" in
    /|/mnt/media|/mnt/intenso-hdd|/mnt/datastore/*)
      _row "$mp ($fs)" "$used" "$size" "$pct"
      ;;
  esac
done <<< "$(_pbs "df -h | tail -n +2")"

_pbs "df -h /run/proxmox-backup" 2>/dev/null | tail -1 | while IFS= read -r line; do
  size=$(echo "$line" | awk '{print $2}')
  used=$(echo "$line" | awk '{print $3}')
  pct=$(echo "$line"  | awk '{print $5}' | tr -d '%')
  _row "PBS in-memory (/run/proxmox-backup)" "$used" "$size" "$pct"
done || true

# LVM thin pool
TPOOL=$(_pbs "lvs --noheadings --units g -o lv_name,data_percent pve 2>/dev/null | grep data-tpool" || true)
if [[ -n "$TPOOL" ]]; then
  TPOOL_PCT=$(echo "$TPOOL" | awk '{printf "%d", $2}')
  TPOOL_SIZE="371G"
  TPOOL_USED=$(echo "$TPOOL" | awk '{printf "%dG", 371*$2/100}')
  _row "LVM thin pool (pve/data-tpool)" "$TPOOL_USED" "$TPOOL_SIZE" "$TPOOL_PCT" "VMs+LXC disks"
fi

# ─────────────────────────────────────────────────────────────────────────────
_section "Proxmox — VM & LXC Disk Allocation (from hypervisor)"
# ─────────────────────────────────────────────────────────────────────────────

printf "  %-42s %6s   %-6s  %s\n" "Name (VMID)" "Used" "Total" "                       Usage"
printf "  %s\n" "$(printf '─%.0s' $(seq 1 90))"

_pbs "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" | \
  python3 -c "
import json, sys, math
data = json.load(sys.stdin)
for vm in sorted(data, key=lambda x: x.get('vmid', 0)):
    vmid   = vm.get('vmid', '?')
    name   = vm.get('name', 'unknown')
    status = vm.get('status', '?')
    disk   = vm.get('disk', 0)
    maxd   = vm.get('maxdisk', 0)
    mem    = vm.get('mem', 0)
    maxm   = vm.get('maxmem', 0)

    def human(b):
        if b == 0: return '0B'
        units = ['B','K','M','G','T']
        i = int(math.log(b, 1024)) if b > 0 else 0
        i = min(i, len(units)-1)
        return f'{b/1024**i:.1f}{units[i]}'

    disk_pct = round(disk * 100 / maxd) if maxd > 0 else 0
    mem_pct  = round(mem  * 100 / maxm) if maxm > 0 else 0
    print(f'{vmid}|{name}|{status}|{human(disk)}|{human(maxd)}|{disk_pct}|{human(mem)}|{human(maxm)}|{mem_pct}')
" 2>/dev/null | while IFS='|' read -r vmid name status disk_used disk_max disk_pct mem_used mem_max mem_pct; do
  label="${name} (${vmid}) [${status}]"
  if [[ "$disk_pct" -gt 0 ]]; then
    _row "$label — disk" "$disk_used" "$disk_max" "$disk_pct"
  else
    _row_na "$label — disk" "QEMU: see guest FS sections below"
  fi
  _row "$label — mem" "$mem_used" "$mem_max" "$mem_pct"
done

# ─────────────────────────────────────────────────────────────────────────────
_section "VM 140 — k3s-controlplane (guest filesystems via SSH)"
# ─────────────────────────────────────────────────────────────────────────────

printf "  %-42s %6s   %-6s  %s\n" "Mount" "Used" "Total" "                       Usage"
printf "  %s\n" "$(printf '─%.0s' $(seq 1 90))"

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 k3s \
  "df -h / /mnt/data 2>/dev/null | tail -n +2" 2>/dev/null | \
while IFS= read -r line; do
  fs=$(echo "$line"   | awk '{print $1}')
  size=$(echo "$line" | awk '{print $2}')
  used=$(echo "$line" | awk '{print $3}')
  pct=$(echo "$line"  | awk '{print $5}' | tr -d '%')
  mp=$(echo "$line"   | awk '{print $6}')
  _row "${mp} (${fs})" "$used" "$size" "$pct"
done

# ─────────────────────────────────────────────────────────────────────────────
_section "VM 200 — homeassistant (guest filesystems via QEMU agent)"
# ─────────────────────────────────────────────────────────────────────────────

printf "  %-42s %6s   %-6s  %s\n" "Mount" "Used" "Total" "                       Usage"
printf "  %s\n" "$(printf '─%.0s' $(seq 1 90))"

_pbs "pvesh get /nodes/ministation/qemu/200/agent/get-fsinfo --output-format json 2>/dev/null" | \
  python3 -c "
import json, sys, math
data = json.load(sys.stdin)

def human(b):
    if b == 0: return '0B'
    units = ['B','K','M','G','T']
    i = int(math.log(b, 1024)) if b > 0 else 0
    i = min(i, len(units)-1)
    return f'{b/1024**i:.1f}{units[i]}'

for fs in data.get('result', []):
    mp    = fs.get('mountpoint', '?')
    total = fs.get('total-bytes', 0)
    used  = fs.get('used-bytes', 0)
    ftype = fs.get('type', '?')
    if ftype == 'erofs':
        continue
    if total == 0:
        continue
    pct = round(used * 100 / total)
    print(f'{mp}|{human(used)}|{human(total)}|{pct}|{ftype}')
" 2>/dev/null | while IFS='|' read -r mp used total pct ftype; do
  _row "${mp} (${ftype})" "$used" "$total" "$pct"
done

# ─────────────────────────────────────────────────────────────────────────────
_section "VM 140 — /mnt/data breakdown"
# ─────────────────────────────────────────────────────────────────────────────

printf "  %-42s %s\n" "Directory" "Size"
printf "  %s\n" "$(printf '─%.0s' $(seq 1 55))"

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 k3s \
  "du -sh /mnt/data/*/ 2>/dev/null | sort -rh" 2>/dev/null | \
while IFS= read -r line; do
  sz=$(echo "$line" | awk '{print $1}')
  dir=$(echo "$line" | awk '{print $2}')
  printf "  %-42s ${CYAN}%s${RESET}\n" "$(basename "$dir")/" "$sz"
done

# ─────────────────────────────────────────────────────────────────────────────
_section "Proxmox — /mnt/media breakdown"
# ─────────────────────────────────────────────────────────────────────────────

printf "  %-42s %s\n" "Directory" "Size"
printf "  %s\n" "$(printf '─%.0s' $(seq 1 55))"

_pbs "du -sh /mnt/media/*/ 2>/dev/null | sort -rh" | \
while IFS= read -r line; do
  sz=$(echo "$line" | awk '{print $1}')
  dir=$(echo "$line" | awk '{print $2}')
  printf "  %-42s ${CYAN}%s${RESET}\n" "$(basename "$dir")/" "$sz"
done
