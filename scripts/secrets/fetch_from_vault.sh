#!/bin/bash

set -e

# Check if the script is executed at the root of the repository
if [[ ! -d ".git" ]]; then
  COLOR_RED="\033[1;31m"
  echo -e "${COLOR_RED}[ERROR] This script must be run from the root of the repository.${COLOR_RESET}" >&2
  exit 1
fi

# Source the helper script
source ./scripts/helper/helper.sh
assert_tools_installed bw jq yq

# --------------------------------CONFIG----------------------------------------
VAULTWARDEN_SERVER=$(yq eval '.vaultwardenURL' config.yaml)
FOLDER_NAME="Homelab"
SECRET_NAME="K3s"
# --------------------------------CONFIG----------------------------------------

log_info "Setting your server in config and logging in"
log_exec bw config server "$VAULTWARDEN_SERVER"
SESSION=$(bw login --raw)
trap bw_logout EXIT

# Check if the folder exists
FOLDER_ID=$(bw list folders --session "$SESSION" | jq -r --arg name "$FOLDER_NAME" '.[] | select(.name==$name) | .id')

if [[ -z "$FOLDER_ID" ]]; then
  log_error "Folder '$FOLDER_NAME' not found."
  exit 1
else
  log_info "Found folder '$FOLDER_NAME' with ID '$FOLDER_ID'."
fi

# Check if the secret exists in the folder
ITEM_ID=$(bw list items --session "$SESSION" | jq -r --arg folderId "$FOLDER_ID" --arg name "$SECRET_NAME" '.[] | select(.folderId==$folderId and .name==$name) | .id')

if [[ -z "$ITEM_ID" ]]; then
  log_error "Item '$SECRET_NAME' not found in folder '$FOLDER_NAME'."
  exit 1
fi

log_info "Getting secret '$SECRET_NAME' from folder '$FOLDER_NAME'"
JSON_RESPONSE=$(bw get item "$ITEM_ID" --session "$SESSION" --response)

log_info "Parsing fields"
AGE_KEY_BASE64=$(echo "$JSON_RESPONSE" | jq -r '.data.fields[] | select(.name == "agekey") | .value')
FLUX_GITHUB_READ_KEY_BASE64=$(echo "$JSON_RESPONSE" | jq -r '.data.fields[] | select(.name == "fluxGithubReadKeyK3s") | .value')
FLUX_GITHUB_READ_PUB_KEY_BASE64=$(echo "$JSON_RESPONSE" | jq -r '.data.fields[] | select(.name == "fluxGithubReadKeyK3s.pub") | .value')
FLUX_SECRETS_GITHUB_READ_KEY_BASE64=$(echo "$JSON_RESPONSE" | jq -r '.data.fields[] | select(.name == "fluxGithubSecretsReadKey") | .value')
FLUX_SECRETS_GITHUB_READ_PUB_KEY_BASE64=$(echo "$JSON_RESPONSE" | jq -r '.data.fields[] | select(.name == "fluxGithubSecretsReadKey.pub") | .value')

log_info "Writing secrets to files"
echo "$AGE_KEY_BASE64" | base64 -d > "$HOME"/.age/key.text
echo "$FLUX_GITHUB_READ_KEY_BASE64" | base64 -d > $HOME/.ssh/fluxGithubReadKeyK3s
echo "$FLUX_GITHUB_READ_PUB_KEY_BASE64" | base64 -d > $HOME/.ssh/fluxGithubReadKeyK3s.pub
echo "$FLUX_SECRETS_GITHUB_READ_KEY_BASE64" | base64 -d > $HOME/.ssh/fluxGithubSecretsReadKey
echo "$FLUX_SECRETS_GITHUB_READ_PUB_KEY_BASE64" | base64 -d > $HOME/.ssh/fluxGithubSecretsReadKey.pub

log_success "Successfully wrote all secrets from '$SECRET_NAME' in folder '$FOLDER_NAME' to local files"
