#!/usr/bin/env bash

# Compares active PVs in the k3s cluster against directories on the host.
# Prints a table of all host dirs with ACTIVE / ORPHANED status, then lists
# any orphaned directories with the ssh command to remove them.
#
# Prerequisites: kubectl, ssh alias "k3s"
# Usage: KUBECONFIG=<path> ./scripts/pvc-audit.sh
#        or set KUBECONFIG in the environment before running.

set -o errexit
set -o pipefail

KUBECONFIG="${KUBECONFIG:-$(dirname "$0")/../secrets/k3s-kubeconfig}"
export KUBECONFIG

SSH_HOST="k3s"
STORAGE_PATH="/opt/k3s/data"

# ── collect active PV paths from the cluster ─────────────────────────────────
active_paths=$(kubectl get pv -o jsonpath='{.items[*].metadata.name}')

# ── collect directories on the host ──────────────────────────────────────────
host_dirs=$(ssh "$SSH_HOST" "ls '$STORAGE_PATH'")

# ── render table ─────────────────────────────────────────────────────────────
COL_DIR=80
COL_STATUS=10

printf "\n%-${COL_DIR}s  %s\n" "DIRECTORY (${STORAGE_PATH}/...)" "STATUS"
printf '%s\n' "$(printf '─%.0s' $(seq 1 $((COL_DIR + COL_STATUS + 2))))"

orphaned=()

while IFS= read -r dir; do
  uid="${dir%%_*}"
  if echo "$active_paths" | grep -qF "$uid"; then
    status="ACTIVE"
  else
    status="ORPHANED"
    orphaned+=("$dir")
  fi
  printf "%-${COL_DIR}s  %s\n" "$dir" "$status"
done <<< "$host_dirs"

printf '%s\n' "$(printf '─%.0s' $(seq 1 $((COL_DIR + COL_STATUS + 2))))"

# ── summary ──────────────────────────────────────────────────────────────────
total=$(echo "$host_dirs" | wc -l | tr -d ' ')
active_count=$(( total - ${#orphaned[@]} ))

printf "\nTotal: %d  |  Active: %d  |  Orphaned: %d\n" \
  "$total" "$active_count" "${#orphaned[@]}"

# ── orphan cleanup commands ───────────────────────────────────────────────────
if [[ ${#orphaned[@]} -eq 0 ]]; then
  printf "\nNo orphaned directories found. All clean.\n\n"
else
  printf "\nOrphaned directories — run to delete:\n\n"
  printf "  ssh %s sudo rm -rf \\\\\n" "$SSH_HOST"
  for i in "${!orphaned[@]}"; do
    if [[ $i -lt $(( ${#orphaned[@]} - 1 )) ]]; then
      printf "    %s/%s \\\\\n" "$STORAGE_PATH" "${orphaned[$i]}"
    else
      printf "    %s/%s\n" "$STORAGE_PATH" "${orphaned[$i]}"
    fi
  done
  printf "\n"
fi
