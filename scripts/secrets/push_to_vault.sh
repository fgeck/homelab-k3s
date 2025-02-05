#!/bin/bash

# Check if the script is executed at the root of the repository
if [[ ! -d ".git" ]]; then
  COLOR_RED="\033[1;31m"
  echo -e "${COLOR_RED}[ERROR] This script must be run from the root of the repository.${COLOR_RESET}" >&2
  exit 1
fi
# Source the helper script
source ./scripts/helper/helper.sh
assert_tools_installed bw yq

# --------------------------------CONFIG----------------------------------------
VAULTWARDEN_SERVER=$(yq eval '.vaultwardenURL' config.yaml)
FOLDER_NAME="Homelab"
SECRET_NAME="K3s"
# --------------------------------CONFIG----------------------------------------

log_info "Setting your server in config and logging in"
log_exec bw config server "$VAULTWARDEN_SERVER"
SESSION=$(bw login --raw)
trap bw_logout EXIT

AGE_KEY_BASE64=$(cat $HOME/.age/key.txt | base64)
FLUX_GITHUB_READ_KEY_BASE64=$(cat $HOME/.ssh/fluxGithubReadKeyK3s | base64)
FLUX_GITHUB_READ_PUB_KEY_BASE64=$(cat $HOME/.ssh/fluxGithubReadKeyK3s.pub | base64)
FLUX_SECRETS_GITHUB_READ_KEY_BASE64=$(cat $HOME/.ssh/fluxGithubSecretsReadKey | base64)
FLUX_SECRETS_GITHUB_READ_PUB_KEY_BASE64=$(cat $HOME/.ssh/fluxGithubSecretsReadKey.pub | base64)

# Check if the folder exists or create it
FOLDER_ID=$(bw list folders --session "$SESSION" | jq -r --arg name "$FOLDER_NAME" '.[] | select(.name==$name) | .id')

if [[ -z "$FOLDER_ID" ]]; then
    FOLDER_ID=$(bw get template folder | jq ".name=\"$FOLDER_NAME\"" | bw encode | bw create folder --session "$SESSION" | jq -r '.id')
    log_info "Created folder '$FOLDER_NAME' with ID '$FOLDER_ID'."
else
    log_info "Found folder '$FOLDER_NAME' with ID '$FOLDER_ID'."
fi

# Check if the item exists within the folder
ITEM_ID=$(bw list items --session "$SESSION" | jq -r --arg folderId "$FOLDER_ID" --arg name "$SECRET_NAME" '.[] | select(.folderId==$folderId and .name==$name) | .id')

if [[ -z "$ITEM_ID" ]]; then
    log_info "Item with name '$SECRET_NAME' not found in folder '$FOLDER_NAME'."
    log_info "Creating new item with name '$SECRET_NAME' in folder '$FOLDER_NAME'"

    bw get template item --session "$SESSION" | \
    jq ".name=\"$SECRET_NAME\" |
        .type = 2 |
        .folderId=\"$FOLDER_ID\" |
        .secureNote.type = 0 |
        .notes=\"Base64 encoded Kubernetes on TalOS secrets\" |
        .fields += [
            {\"name\": \"ageKey\", \"value\": \"$AGE_KEY_BASE64\", \"type\": 1},
            {\"name\": \"fluxGithubReadKeyK3s\", \"value\": \"$FLUX_GITHUB_READ_KEY_BASE64\", \"type\": 1},
            {\"name\": \"fluxGithubReadKeyK3s.pub\", \"value\": \"$FLUX_GITHUB_READ_PUB_KEY_BASE64\", \"type\": 1},
            {\"name\": \"fluxGithubSecretsReadKey\", \"value\": \"$FLUX_SECRETS_GITHUB_READ_KEY_BASE64\", \"type\": 1},
            {\"name\": \"fluxGithubSecretsReadKey.pub\", \"value\": \"$FLUX_SECRETS_GITHUB_READ_PUB_KEY_BASE64\", \"type\": 1}
        ]" | \
    bw encode | \
    bw create item --session "$SESSION" > /dev/null
else
    log_info "Item with name '$SECRET_NAME' and ID '$ITEM_ID' found in folder '$FOLDER_NAME'."
    log_info "Updating existing item with name '$SECRET_NAME' in folder '$FOLDER_NAME'"

    bw get item "$ITEM_ID" --session "$SESSION" | \
    jq ".fields = [
            {\"name\": \"ageKey\", \"value\": \"$AGE_KEY_BASE64\", \"type\": 1},
            {\"name\": \"fluxGithubReadKey\", \"value\": \"$FLUX_GITHUB_READ_KEY_BASE64\", \"type\": 1},
            {\"name\": \"fluxGithubReadKey.pub\", \"value\": \"$FLUX_GITHUB_READ_PUB_KEY_BASE64\", \"type\": 1},
            {\"name\": \"fluxGithubSecretsReadKey\", \"value\": \"$FLUX_SECRETS_GITHUB_READ_KEY_BASE64\", \"type\": 1},
            {\"name\": \"fluxGithubSecretsReadKey.pub\", \"value\": \"$FLUX_SECRETS_GITHUB_READ_PUB_KEY_BASE64\", \"type\": 1}
        ]" | \
    bw encode | \
    bw edit item "$ITEM_ID" --session "$SESSION" > /dev/null
fi

log_success "Successfully pushed all Keys to $VAULTWARDEN_SERVER in folder '$FOLDER_NAME'"
