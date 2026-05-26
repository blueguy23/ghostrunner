#!/bin/bash
# Intended to be sourced from entrypoint.sh — not executed directly
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && echo "ERROR: source this script, don't execute it" && exit 1

_get_registration_token() {
  if [ -z "${GITHUB_PAT:-}" ]; then
    log "ERROR: GITHUB_PAT is not set"
    return 1
  fi

  local RESPONSE TOKEN
  RESPONSE=$($CURL_CMD -fsSL -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/registration-token" 2>/dev/null) || {
    log "ERROR: Failed to get registration token (HTTP error or network failure)"
    return 1
  }

  TOKEN=$(echo "$RESPONSE" | jq -r '.token')
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    log "ERROR: Failed to get runner registration token. Check GITHUB_PAT has 'repo' scope."
    return 1
  fi

  echo "$TOKEN"
}

_get_remove_token() {
  if [ -z "${GITHUB_PAT:-}" ]; then
    log "ERROR: GITHUB_PAT is not set"
    return 1
  fi

  local RESPONSE TOKEN
  RESPONSE=$($CURL_CMD -fsSL -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/remove-token" 2>/dev/null) || {
    log "ERROR: Failed to get remove token (HTTP error or network failure)"
    return 1
  }

  TOKEN=$(echo "$RESPONSE" | jq -r '.token')
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    log "ERROR: Failed to get runner remove token. Check GITHUB_PAT has 'repo' scope."
    return 1
  fi

  echo "$TOKEN"
}

_register_runner() {
  local REG_TOKEN="${1:?_register_runner requires a registration token as \$1}"

  rm -f .runner .credentials

  ./config.sh \
    --url           "$REPO_URL" \
    --token         "$REG_TOKEN" \
    --name          "$RUNNER_NAME" \
    --labels        "self-hosted,Linux,X64" \
    --work          _work \
    --unattended \
    --replace \
    --ephemeral \
    --disableupdate
}

_deregister_runner() {
  local RUNNER_ID
  RUNNER_ID=$($CURL_CMD -sf --max-time 10 \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners" \
    | jq -r --arg name "$RUNNER_NAME" '.runners[] | select(.name == $name) | .id') || true

  if [ -n "$RUNNER_ID" ] && [ "$RUNNER_ID" != "null" ]; then
    log "Deregistering runner (id=${RUNNER_ID}) from GitHub..."
    local HTTP_CODE
    HTTP_CODE=$($CURL_CMD -s -o /dev/null -w '%{http_code}' --max-time 10 -X DELETE \
      -H "Authorization: token ${GITHUB_PAT}" \
      -H "Accept: application/vnd.github+json" \
      "${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/${RUNNER_ID}")

    if [ "$HTTP_CODE" = "204" ]; then
      log "Runner deregistered."
    elif [ "$HTTP_CODE" = "403" ]; then
      log "ERROR: Deregistration returned 403 — GITHUB_PAT may lack 'repo' or 'manage_runners:org' scope"
    else
      log "WARNING: Deregistration returned HTTP ${HTTP_CODE} (GitHub will clean up eventually)"
    fi
  fi
}
