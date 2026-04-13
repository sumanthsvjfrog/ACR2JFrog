#!/bin/bash

JFROG_REGISTRY_HOST="${1:?please enter JPD ID. ex - target-server}"
JFROG_USERNAME="${2:?please enter JFrog Username: Ex: Sumanth}"
JFROG_TOKEN="${3:?please enter JFrog Token}"
ACR_REGISTRY_URL="${4:?please enter ACR login server (e.g., sumacr2.azurecr.io)}"
JFROG_REPO="${5:-}"
repo_file="${6:-}"

#  LOGGING
LOG_FILE="acr_to_jfrog_$(date '+%Y%m%d_%H%M%S').log"
SUMMARY_FILE="summary_$(date '+%Y%m%d_%H%M%S').log"

# Track results for summary table
declare -a SUMMARY_ROWS=()

log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  local line="[$ts] [$level] $msg"

  # Colour for terminal only
  case "$level" in
    INFO)  printf "\033[0;36m%s\033[0m\n" "$line" ;;
    OK)    printf "\033[0;32m%s\033[0m\n" "$line" ;;
    WARN)  printf "\033[0;33m%s\033[0m\n" "$line" ;;
    ERROR) printf "\033[0;31m%s\033[0m\n" "$line" ;;
    *)     printf "%s\n" "$line" ;;
  esac

  # Plain text to log file
  echo "$line" >> "$LOG_FILE"
}

log_section() {
  local title="$1"
  local sep="────────────────────────────────────────────────────"
  log INFO "$sep"
  log INFO "  $title"
  log INFO "$sep"
}

print_summary() {
  local col1=25 col2=12 col3=32 col4=10

  local header
  header=$(printf "%-${col1}s %-${col2}s %-${col3}s %-${col4}s" \
    "REPOSITORY" "TAG" "TARGET_REPO" "STATUS")
  local divider
  divider=$(printf "%-${col1}s %-${col2}s %-${col3}s %-${col4}s" \
    "$(printf '%.0s-' {1..25})" \
    "$(printf '%.0s-' {1..12})" \
    "$(printf '%.0s-' {1..32})" \
    "$(printf '%.0s-' {1..10})")

  echo ""
  echo "$header"
  echo "$divider"
  for row in "${SUMMARY_ROWS[@]}"; do
    IFS='|' read -r repo tag target status <<< "$row"
    if [[ "$status" == "SUCCESS" ]]; then
      printf "\033[0;32m%-${col1}s %-${col2}s %-${col3}s ✔ %s\033[0m\n" \
        "$repo" "$tag" "$target" "$status"
    else
      printf "\033[0;31m%-${col1}s %-${col2}s %-${col3}s ✘ %s\033[0m\n" \
        "$repo" "$tag" "$target" "$status"
    fi
  done
  echo ""

  # Also write plain summary to file
  {
    echo ""
    echo "$header"
    echo "$divider"
    for row in "${SUMMARY_ROWS[@]}"; do
      IFS='|' read -r repo tag target status <<< "$row"
      printf "%-${col1}s %-${col2}s %-${col3}s %s\n" "$repo" "$tag" "$target" "$status"
    done
    echo ""
  } >> "$SUMMARY_FILE"
}

# ─────────────────────────────────────────
#  INIT
# ─────────────────────────────────────────
log_section "ACR → JFrog Migration Script"
log INFO "Log file      : $LOG_FILE"
log INFO "Summary file  : $SUMMARY_FILE"
log INFO "ACR Registry  : $ACR_REGISTRY_URL"
log INFO "JFrog Host    : $JFROG_REGISTRY_HOST"
log INFO "JFrog User    : $JFROG_USERNAME"
log INFO "JFrog Repo    : ${JFROG_REPO:-"(from repo_file)"}"
log INFO "Repo file     : ${repo_file:-"(not provided)"}"

#  VALIDATION
repo_file_flag="no"
if [ -n "$repo_file" ]; then
  repo_file_flag="yes"
fi

if [ "$repo_file_flag" = "no" ] && [ -z "$JFROG_REPO" ]; then
  log ERROR "Either repo_file or JFROG_REPO must be provided."
  exit 1
fi

registry_name=$(echo "$ACR_REGISTRY_URL" | cut -d. -f1)

#  FUNCTIONS
GetACRToken() {
  log_section "--- ACR Authenticationi ---"
  log INFO "Fetching ACR access token for registry: $registry_name"
  ACR_ACCESS_TOKEN=$(az acr login --name "$registry_name" \
    --expose-token --output tsv --query accessToken 2>>"$LOG_FILE")
  if [ -z "$ACR_ACCESS_TOKEN" ]; then
    log ERROR "Failed to obtain ACR access token. Aborting."
    exit 1
  fi
  log OK "ACR access token obtained."
}

ListACRRepos() {
  log_section "--- Listing ACR Repositories ---"
  log INFO "Fetching repository list from ACR: $registry_name"
  az acr repository list --name "$registry_name" -o tsv > acrrepos.txt 2>>"$LOG_FILE"
  local count
  count=$(wc -l < acrrepos.txt | tr -d ' ')
  log OK "Found $count repository/repositories in ACR."
  log INFO "Repositories: $(tr '\n' ',' < acrrepos.txt | sed 's/,$//')"
}

SkopeoLogin() {
  log_section "--- Skopeo Login ---"

  log INFO "Logging into ACR via Skopeo: $ACR_REGISTRY_URL"
  if skopeo login \
      --username 00000000-0000-0000-0000-000000000000 \
      --password "$ACR_ACCESS_TOKEN" \
      "$ACR_REGISTRY_URL" >> "$LOG_FILE" 2>&1; then
    log OK "Skopeo login to ACR succeeded."
  else
    log ERROR "Skopeo login to ACR failed. Check credentials."
    exit 1
  fi

  log INFO "Logging into JFrog via Skopeo: $JFROG_REGISTRY_HOST"
  if skopeo login \
      --username "$JFROG_USERNAME" \
      --password "$JFROG_TOKEN" \
      "$JFROG_REGISTRY_HOST" >> "$LOG_FILE" 2>&1; then
    log OK "Skopeo login to JFrog succeeded."
  else
    log ERROR "Skopeo login to JFrog failed. Check credentials."
    exit 1
  fi
}

CopyContents() {
  local source_image="$1"
  local target_repo="$2"
  local image_det
  image_det=$(echo "$source_image" | cut -d/ -f2-)

  local repo_name tag_name
  repo_name=$(echo "$image_det" | cut -d: -f1)
  tag_name=$(echo "$image_det"  | cut -d: -f2)

  local target_full="$JFROG_REGISTRY_HOST/$target_repo/$image_det"

  log INFO "Copying image ..."
  log INFO "  Source : docker://$source_image"
  log INFO "  Target : docker://$target_full"

  if skopeo copy \
      docker://"$source_image" \
      docker://"$target_full" \
      --all >> "$LOG_FILE" 2>&1; then
    log OK "Copy succeeded: $repo_name:$tag_name → $target_repo"
    SUMMARY_ROWS+=("$repo_name|$tag_name|$target_repo|SUCCESS")
  else
    log ERROR "Copy FAILED: $repo_name:$tag_name → $target_repo"
    SUMMARY_ROWS+=("$repo_name|$tag_name|$target_repo|FAILED")
  fi
}

Action() {
  log_section "Step 4/4 — Copying Images ACR → JFrog"
  local total_repos total_images=0
  total_repos=$(wc -l < acrrepos.txt | tr -d ' ')
  log INFO "Processing $total_repos ACR repository/repositories ..."

  while IFS= read -r rep; do
    local acrreponame jfrog_reponame
    acrreponame=$(echo "$rep" | cut -d, -f1)

    if [ "$repo_file_flag" = "yes" ]; then
      jfrog_reponame=$(echo "$rep" | cut -d, -f2)
    else
      jfrog_reponame="$JFROG_REPO"
    fi

    log INFO "Repository: $acrreponame  →  JFrog target: $jfrog_reponame"
    log INFO "Fetching last 5 tags for: $ACR_REGISTRY_URL/$acrreponame"

    local tags
    tags=$(az acr manifest list-metadata \
      "$ACR_REGISTRY_URL/$acrreponame" \
      --query "sort_by(@, &lastUpdateTime)[-5:].tags[]" \
      -o tsv 2>>"$LOG_FILE")

    if [ -z "$tags" ]; then
      log WARN "No tags found for $acrreponame — skipping."
      continue
    fi

    local tag_count
    tag_count=$(echo "$tags" | wc -l | tr -d ' ')
    log INFO "Found $tag_count tag(s): $(echo "$tags" | tr '\n' ',' | sed 's/,$//')"

    for tag in $tags; do
      ((total_images++))
      log INFO "[$total_images] Processing tag: $tag"
      CopyContents "$ACR_REGISTRY_URL/$acrreponame:$tag" "$jfrog_reponame"
    done

  done < acrrepos.txt

  log OK "All done. Total images processed: $total_images"
}

# ─────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────
GetACRToken
SkopeoLogin
if [ "$repo_file_flag" = "no" ]; then
  ListACRRepos
else
  log INFO "Using provided repo file: $repo_file"
  cp "$repo_file" acrrepos.txt
  count=$(wc -l < acrrepos.txt | tr -d ' ')
  log OK "Loaded $count repo mapping(s) from $repo_file"
fi
Action

# Print & save summary table
log_section "Migration Summary"
print_summary

# Final counts
SUCCESS_COUNT=$(printf '%s\n' "${SUMMARY_ROWS[@]}" | grep -c '|SUCCESS$' || true)
FAIL_COUNT=$(printf '%s\n'    "${SUMMARY_ROWS[@]}" | grep -c '|FAILED$'  || true)
log INFO "✔ Succeeded : $SUCCESS_COUNT"
log INFO "✘ Failed    : $FAIL_COUNT"
log INFO "Full log    : $LOG_FILE"
log INFO "Summary     : $SUMMARY_FILE"
