#!/usr/bin/env bash

# Validates backup health across:
#   - Kubernetes CronJobs (PVC, postgres, vaultwarden, immich-windows)
#   - Proxmox Backup Server snapshots (databases + PVCs)
#   - Proxmox VM/CT backups
#   - PBS disk health

set -o errexit
set -o pipefail

KUBECONFIG="${KUBECONFIG:-$(dirname "$0")/../secrets/k3s-kubeconfig}"
export KUBECONFIG

CONFIG_ENV="$(dirname "$0")/secrets/config.env"
if [[ ! -f "$CONFIG_ENV" ]]; then
  echo "Error: $CONFIG_ENV not found. Copy scripts/secrets/config.env.example and fill in your values." >&2
  exit 1
fi
# shellcheck source=secrets/config.env
source "$CONFIG_ENV"

NOW=$(date +%s)

PASS=0
WARN=0
FAIL=0

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BOLD="\033[1m"
RESET="\033[0m"

_ok()      { printf "  ${GREEN}[OK]${RESET}   %s\n" "$*";   PASS=$((PASS+1)); }
_warn()    { printf "  ${YELLOW}[WARN]${RESET} %s\n" "$*";  WARN=$((WARN+1)); }
_fail()    { printf "  ${RED}[FAIL]${RESET} %s\n" "$*";     FAIL=$((FAIL+1)); }

_section() { printf "\n${BOLD}── %s${RESET}\n" "$*"; }

_hours_since() {
  local ts="$1"
  if [[ -z "$ts" ]]; then echo 99999; return; fi
  local epoch
  epoch=$(date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)
  echo $(( (NOW - epoch) / 3600 ))
}

_check_cronjob() {
  local namespace="$1"
  local cronjob="$2"
  local max_hours="$3"
  local label="${4:-$cronjob}"

  local last_success last_schedule hours_since
  last_success=$(kubectl get cronjob "$cronjob" -n "$namespace" \
    -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)
  last_schedule=$(kubectl get cronjob "$cronjob" -n "$namespace" \
    -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || true)

  if [[ -z "$last_success" ]]; then
    local recent_success
    recent_success=$(kubectl get jobs -n "$namespace" \
      --sort-by='.metadata.creationTimestamp' \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[0].type}{" "}{.status.completionTime}{"\n"}{end}' \
      2>/dev/null | grep -i "$cronjob" | grep -i "SuccessCriteriaMet" | tail -1 || true)
    if [[ -n "$recent_success" ]]; then
      local completion_time
      completion_time=$(echo "$recent_success" | awk '{print $3}')
      hours_since=$(_hours_since "$completion_time")
      _ok "$label: last success ${hours_since}h ago (via job history, $completion_time)"
      return
    fi
    if [[ -z "$last_schedule" ]]; then
      _fail "$label: never scheduled"
    else
      _warn "$label: scheduled but no success recorded yet (last schedule: $last_schedule)"
    fi
    return
  fi

  hours_since=$(_hours_since "$last_success")
  if [[ "$hours_since" -le "$max_hours" ]]; then
    _ok "$label: last success ${hours_since}h ago ($last_success)"
  elif [[ "$hours_since" -le $(( max_hours * 2 )) ]]; then
    _warn "$label: last success ${hours_since}h ago — expected within ${max_hours}h ($last_success)"
  else
    _fail "$label: last success ${hours_since}h ago — expected within ${max_hours}h ($last_success)"
  fi

  local latest_job_status
  latest_job_status=$(kubectl get jobs -n "$namespace" \
    --sort-by='.metadata.creationTimestamp' \
    -o jsonpath='{.items[-1:].status.conditions[0].type}' 2>/dev/null || true)
  if [[ "$latest_job_status" == "FailureTarget" ]]; then
    _warn "$label: most recent job run FAILED (check: kubectl logs -n $namespace -l app.kubernetes.io/name=$cronjob)"
  fi
}

_check_pbs_snapshot() {
  local path="$1"
  local label="$2"
  local max_hours="$3"

  local latest_snapshot
  latest_snapshot=$(ssh -i "$PBS_SSH_KEY" -o StrictHostKeyChecking=no \
    "${PBS_USER}@${PBS_HOST}" \
    "ls '$path' 2>/dev/null | grep -v owner | sort | tail -1" 2>/dev/null || true)

  if [[ -z "$latest_snapshot" ]]; then
    _fail "$label: no snapshots found in $path"
    return
  fi

  local snapshot_ts="${latest_snapshot%Z}Z"
  local hours_since
  hours_since=$(_hours_since "$snapshot_ts")

  if [[ "$hours_since" -le "$max_hours" ]]; then
    _ok "$label: latest snapshot ${hours_since}h ago ($latest_snapshot)"
  elif [[ "$hours_since" -le $(( max_hours * 2 )) ]]; then
    _warn "$label: latest snapshot ${hours_since}h ago — expected within ${max_hours}h"
  else
    _fail "$label: latest snapshot ${hours_since}h ago — expected within ${max_hours}h"
  fi
}

_check_pbs_vm_ct() {
  local type="$1"
  local id="$2"
  local label="$3"
  local max_hours="$4"

  local path="${PBS_DATASTORE_PATH}/${type}/${id}"
  _check_pbs_snapshot "$path" "$label" "$max_hours"
}

# ─────────────────────────────────────────────────────────────────────────────
_section "Kubernetes CronJob Health"
# ─────────────────────────────────────────────────────────────────────────────

_check_cronjob default  default-postgres-backup  30  "DB backup: default-postgres"
_check_cronjob default  security-postgres-backup 30  "DB backup: security-postgres"
_check_cronjob default  pvc-backup               30  "PVC backup"
_check_cronjob security vaultwarden-backup        30  "Vaultwarden backup"
_check_cronjob media    immich-windows-backup     60  "Immich Windows backup (every 2d)"

IMMICH_LOG=$(kubectl logs -n media \
  -l app.kubernetes.io/name=immich-windows-backup \
  --tail=5 2>/dev/null || true)
if echo "$IMMICH_LOG" | grep -q "backup completed successfully"; then
  _ok "Immich Windows backup: last pod log confirms successful completion"
elif [[ -z "$IMMICH_LOG" ]]; then
  _warn "Immich Windows backup: no pod logs available (TTL'd or not yet run)"
else
  _fail "Immich Windows backup: last pod log does NOT contain 'backup completed successfully'"
fi

# ─────────────────────────────────────────────────────────────────────────────
_section "PBS — Database Snapshots (k3s/databases)"
# ─────────────────────────────────────────────────────────────────────────────

DB_PATH="${PBS_DATASTORE_PATH}/ns/k3s/ns/databases/host"
_check_pbs_snapshot "${DB_PATH}/default-postgres"  "PBS: default-postgres"  30
_check_pbs_snapshot "${DB_PATH}/security-postgres" "PBS: security-postgres" 30

# ─────────────────────────────────────────────────────────────────────────────
_section "PBS — PVC Snapshots (k3s/pvcs) — active PVCs only"
# ─────────────────────────────────────────────────────────────────────────────

PVC_PATH="${PBS_DATASTORE_PATH}/ns/k3s/ns/pvcs/host"

ACTIVE_PVC_KEYS=$(kubectl get pv \
  -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{"_"}{.spec.claimRef.name}{"\n"}{end}' \
  2>/dev/null)

PBS_PVC_LATEST=$(ssh -i "$PBS_SSH_KEY" -o StrictHostKeyChecking=no \
  "${PBS_USER}@${PBS_HOST}" \
  "for d in '$PVC_PATH'/*/; do
     name=\$(basename \"\$d\")
     latest=\$(ls \"\$d\" 2>/dev/null | grep -v owner | sort | tail -1)
     echo \"\$name|\$latest\"
   done" 2>/dev/null || true)

while IFS='|' read -r pbs_dir latest_snapshot; do
  if ! echo "$ACTIVE_PVC_KEYS" | grep -qF "$pbs_dir"; then
    continue
  fi
  if [[ -z "$latest_snapshot" ]]; then
    _fail "PBS PVC: $pbs_dir: no snapshots found"
    continue
  fi
  hours_since=$(_hours_since "$latest_snapshot")
  if [[ "$hours_since" -le 30 ]]; then
    _ok "PBS PVC: $pbs_dir: latest snapshot ${hours_since}h ago ($latest_snapshot)"
  elif [[ "$hours_since" -le 60 ]]; then
    _warn "PBS PVC: $pbs_dir: latest snapshot ${hours_since}h ago — expected within 30h"
  else
    _fail "PBS PVC: $pbs_dir: latest snapshot ${hours_since}h ago — expected within 30h"
  fi
done <<< "$PBS_PVC_LATEST"

# ─────────────────────────────────────────────────────────────────────────────
_section "PBS — Proxmox VM/CT Backups"
# ─────────────────────────────────────────────────────────────────────────────

_check_pbs_vm_ct vm  140 "Proxmox VM 140"    60
_check_pbs_vm_ct vm  200 "Proxmox VM 200"    60
_check_pbs_vm_ct ct  111 "Proxmox CT 111"    60

# ─────────────────────────────────────────────────────────────────────────────
_section "PBS — Disk & GC Health"
# ─────────────────────────────────────────────────────────────────────────────

PBS_DISK_INFO=$(ssh -i "$PBS_SSH_KEY" -o StrictHostKeyChecking=no \
  "${PBS_USER}@${PBS_HOST}" \
  "df -h '$PBS_DATASTORE_PATH' 2>/dev/null | tail -1" 2>/dev/null || true)

if [[ -n "$PBS_DISK_INFO" ]]; then
  PBS_USE_PCT=$(echo "$PBS_DISK_INFO" | awk '{print $5}' | tr -d '%')
  PBS_AVAIL=$(echo "$PBS_DISK_INFO" | awk '{print $4}')
  if [[ "$PBS_USE_PCT" -lt 80 ]]; then
    _ok "PBS disk usage: ${PBS_USE_PCT}% used (${PBS_AVAIL} available)"
  elif [[ "$PBS_USE_PCT" -lt 90 ]]; then
    _warn "PBS disk usage: ${PBS_USE_PCT}% used (${PBS_AVAIL} available) — consider pruning"
  else
    _fail "PBS disk usage: ${PBS_USE_PCT}% used (${PBS_AVAIL} available) — CRITICAL, backups may fail"
  fi
else
  _warn "PBS disk usage: could not query"
fi

GC_STATE=$(ssh -i "$PBS_SSH_KEY" -o StrictHostKeyChecking=no \
  "${PBS_USER}@${PBS_HOST}" \
  "proxmox-backup-manager garbage-collection list --output-format json-pretty 2>/dev/null | python3 -c \"
import json,sys
d=json.load(sys.stdin)
if d: print(d[0].get('last-run-state','unknown'))
else: print('no-data')
\"" 2>/dev/null || echo "unknown")

if [[ "$GC_STATE" == "OK" ]]; then
  _ok "PBS garbage collection: last run OK"
elif [[ "$GC_STATE" == "unknown" || "$GC_STATE" == "no-data" ]]; then
  _warn "PBS garbage collection: state unknown"
else
  _fail "PBS garbage collection: last run state = $GC_STATE"
fi

# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}── Summary${RESET}\n"
# ─────────────────────────────────────────────────────────────────────────────

printf "\n  ${GREEN}OK: %d${RESET}   ${YELLOW}WARN: %d${RESET}   ${RED}FAIL: %d${RESET}\n\n" "$PASS" "$WARN" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  exit 2
fi
