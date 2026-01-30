#!/usr/bin/env bash
# PUSH - Upload NAR files to cache repository via GitHub API
# Handles content-addressed storage with proper file size limits
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] FILE...

Upload NAR files and metadata to the cache repository.

Arguments:
  FILE...     Files to upload (NAR, narinfo, logs)

Options:
  --owner OWNER    Repository owner (default: from config or env)
  --repo REPO      Repository name (default: from config or env)
  --branch BRANCH  Target branch (default: main)
  --prefix PATH    Path prefix in repository (default: based on file type)
  --dry-run        Show what would be uploaded without doing it
  -h, --help       Show this help

Environment:
  CACHE_REPO_TOKEN  GitHub token with write access (or GITHUB_TOKEN)
  CACHE_OWNER       Default repository owner
  CACHE_REPO        Default repository name

File size limits:
  < 1 MB      Contents API (base64 in request)
  1-100 MB    Blobs API (base64 upload)
  > 100 MB    Not supported

Storage layout:
  nar/<hash>.nar           Uncompressed NAR files
  <hash>.narinfo           Store path metadata + signatures
  logs/<hash>.log          Build logs (content-addressed)
  manifests/<variant>.json Per-variant latest build
  index.txt                Complete path index
  nix-cache-info           Cache metadata

Examples:
  $(basename "$0") export/nar/*.nar
  $(basename "$0") --prefix logs export/logs/*.log
  $(basename "$0") --dry-run export/
EOF
}

# Configuration
OWNER="${CACHE_OWNER:-}"
REPO="${CACHE_REPO:-}"
BRANCH="main"
PREFIX=""
DRY_RUN=false
FILES=()

# Try to read from PULL config if available
PULL_CONFIG="${SCRIPT_DIR}/../PULL/cache/config.json"
if [[ -f "$PULL_CONFIG" ]]; then
    : "${OWNER:=$(jq -r '.cache_repo.owner' "$PULL_CONFIG")}"
    : "${REPO:=$(jq -r '.cache_repo.repo' "$PULL_CONFIG")}"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner)
            OWNER="$2"
            shift 2
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

# Validate configuration
if [[ -z "$OWNER" ]] || [[ -z "$REPO" ]]; then
    echo "Error: Repository owner and name required" >&2
    echo "Set via --owner/--repo or CACHE_OWNER/CACHE_REPO env vars" >&2
    exit 1
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Error: No files specified" >&2
    usage >&2
    exit 1
fi

# Check for token
TOKEN="${CACHE_REPO_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
    echo "Error: CACHE_REPO_TOKEN or GITHUB_TOKEN required" >&2
    exit 1
fi

echo "Upload target: ${OWNER}/${REPO} (branch: ${BRANCH})"
echo ""

# GitHub API helper
gh_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="https://api.github.com${endpoint}"
    local args=(
        -s
        -X "$method"
        -H "Accept: application/vnd.github+json"
        -H "Authorization: Bearer ${TOKEN}"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    if [[ -n "$data" ]]; then
        args+=(-H "Content-Type: application/json" -d "$data")
    fi

    curl "${args[@]}" "$url"
}

# Determine remote path based on file type and explicit prefix
get_remote_path() {
    local file="$1"
    local basename
    basename=$(basename "$file")

    # If explicit prefix given, use it
    if [[ -n "$PREFIX" ]]; then
        echo "${PREFIX}/${basename}"
        return
    fi

    # Auto-detect based on extension
    case "$basename" in
        *.nar)
            echo "nar/${basename}"
            ;;
        *.narinfo)
            echo "${basename}"
            ;;
        *.log)
            echo "logs/${basename}"
            ;;
        *.json)
            if [[ "$file" == *"/manifests/"* ]]; then
                echo "manifests/${basename}"
            else
                echo "${basename}"
            fi
            ;;
        nix-cache-info|index.txt)
            echo "${basename}"
            ;;
        *)
            echo "${basename}"
            ;;
    esac
}

# Upload file using Contents API (< 1MB)
upload_contents_api() {
    local file="$1"
    local remote_path="$2"
    local message="$3"

    # Get current SHA if file exists
    local current_sha=""
    local current
    current=$(gh_api GET "/repos/${OWNER}/${REPO}/contents/${remote_path}?ref=${BRANCH}" 2>/dev/null || echo "")
    if [[ -n "$current" ]] && echo "$current" | jq -e '.sha' > /dev/null 2>&1; then
        current_sha=$(echo "$current" | jq -r '.sha')
    fi

    # Encode content to temp file to avoid ARG_MAX limits on large files
    local content_file data_file
    content_file=$(mktemp)
    data_file=$(mktemp)
    trap "rm -f '$content_file' '$data_file'" RETURN

    base64 -w0 < "$file" > "$content_file"

    # Build request — use --rawfile to read base64 content from file
    if [[ -n "$current_sha" ]]; then
        jq -n \
            --arg message "$message" \
            --rawfile content "$content_file" \
            --arg sha "$current_sha" \
            --arg branch "$BRANCH" \
            '{message: $message, content: $content, sha: $sha, branch: $branch}' \
            > "$data_file"
    else
        jq -n \
            --arg message "$message" \
            --rawfile content "$content_file" \
            --arg branch "$BRANCH" \
            '{message: $message, content: $content, branch: $branch}' \
            > "$data_file"
    fi

    # Use @file to send payload via curl, avoiding ARG_MAX for large JSON
    local url="https://api.github.com/repos/${OWNER}/${REPO}/contents/${remote_path}"
    curl -s -X PUT \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/json" \
        -d "@${data_file}" \
        "$url"
}

# Upload file using Blobs API (1-100MB)
upload_blobs_api() {
    local file="$1"
    local remote_path="$2"
    local message="$3"

    # Create blob — use temp files to avoid ARG_MAX limits
    local content_file data_file
    content_file=$(mktemp)
    data_file=$(mktemp)
    trap "rm -f '$content_file' '$data_file'" RETURN

    base64 -w0 < "$file" > "$content_file"

    jq -n \
        --rawfile content "$content_file" \
        --arg encoding "base64" \
        '{content: $content, encoding: $encoding}' \
        > "$data_file"

    local blob_response
    local url="https://api.github.com/repos/${OWNER}/${REPO}/git/blobs"
    blob_response=$(curl -s -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/json" \
        -d "@${data_file}" \
        "$url")

    local blob_sha
    blob_sha=$(echo "$blob_response" | jq -r '.sha')

    if [[ -z "$blob_sha" ]] || [[ "$blob_sha" == "null" ]]; then
        echo "Failed to create blob: $(echo "$blob_response" | jq -r '.message // "Unknown error"')"
        return 1
    fi

    # Get current tree
    local ref_response
    ref_response=$(gh_api GET "/repos/${OWNER}/${REPO}/git/refs/heads/${BRANCH}")
    local commit_sha
    commit_sha=$(echo "$ref_response" | jq -r '.object.sha')

    local commit_response
    commit_response=$(gh_api GET "/repos/${OWNER}/${REPO}/git/commits/${commit_sha}")
    local tree_sha
    tree_sha=$(echo "$commit_response" | jq -r '.tree.sha')

    # Create new tree with the file
    local tree_response
    tree_response=$(gh_api POST "/repos/${OWNER}/${REPO}/git/trees" "$(jq -n \
        --arg base_tree "$tree_sha" \
        --arg path "$remote_path" \
        --arg sha "$blob_sha" \
        '{base_tree: $base_tree, tree: [{path: $path, mode: "100644", type: "blob", sha: $sha}]}'
    )")

    local new_tree_sha
    new_tree_sha=$(echo "$tree_response" | jq -r '.sha')

    # Create commit
    local new_commit_response
    new_commit_response=$(gh_api POST "/repos/${OWNER}/${REPO}/git/commits" "$(jq -n \
        --arg message "$message" \
        --arg tree "$new_tree_sha" \
        --arg parent "$commit_sha" \
        '{message: $message, tree: $tree, parents: [$parent]}'
    )")

    local new_commit_sha
    new_commit_sha=$(echo "$new_commit_response" | jq -r '.sha')

    # Update ref
    gh_api PATCH "/repos/${OWNER}/${REPO}/git/refs/heads/${BRANCH}" "$(jq -n \
        --arg sha "$new_commit_sha" \
        '{sha: $sha}'
    )"
}

# Upload a single file
upload_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo "Warning: File not found: $file"
        return 1
    fi

    local size
    size=$(stat -c%s "$file")
    local remote_path
    remote_path=$(get_remote_path "$file")
    local message="Add $(basename "$file")"

    printf "%-50s %10s  " "$remote_path" "$(numfmt --to=iec-i --suffix=B "$size")"

    if $DRY_RUN; then
        echo "[dry-run]"
        return 0
    fi

    # Check size limits
    if [[ $size -gt 104857600 ]]; then
        echo "[ERROR: >100MB]"
        return 1
    fi

    local response
    if [[ $size -lt 1048576 ]]; then
        # Use Contents API for small files
        response=$(upload_contents_api "$file" "$remote_path" "$message")
    else
        # Use Blobs API for larger files
        response=$(upload_blobs_api "$file" "$remote_path" "$message")
    fi

    if echo "$response" | jq -e '.sha // .content.sha' > /dev/null 2>&1; then
        echo "[OK]"
        return 0
    else
        echo "[FAILED: $(echo "$response" | jq -r '.message // "Unknown"')]"
        return 1
    fi
}

# Process all files
SUCCESS=0
FAILED=0

for file in "${FILES[@]}"; do
    if [[ -d "$file" ]]; then
        # If directory, process all files within
        while IFS= read -r -d '' f; do
            if upload_file "$f"; then
                ((SUCCESS++))
            else
                ((FAILED++))
            fi
        done < <(find "$file" -type f -print0)
    else
        if upload_file "$file"; then
            ((SUCCESS++))
        else
            ((FAILED++))
        fi
    fi
done

echo ""
echo "=== Upload Summary ==="
echo "Success: ${SUCCESS}"
echo "Failed: ${FAILED}"

[[ $FAILED -eq 0 ]]
