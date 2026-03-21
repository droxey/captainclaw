#!/usr/bin/env bash
# update-pins.sh — Fetch latest commit SHAs for all pinned git dependencies.
#
# Parses group_vars/all/vars.yml for "git ls-remote" comments and updates
# the SHA on the line immediately following each comment.
#
# Usage:
#   scripts/update-pins.sh [--dry-run] [--parallel] [FILE]
#
# Options:
#   --dry-run   Show what would change without modifying the file
#   --parallel  Run git ls-remote calls concurrently (faster, non-deterministic output)
#
# Exit codes:
#   0  All SHAs fetched and applied (or unchanged)
#   1  One or more git ls-remote calls failed
#   2  Usage error

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────
VARS_FILE="group_vars/all/vars.yml"
DRY_RUN=false
PARALLEL=false

# ── Parse arguments ─────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=true ;;
    --parallel) PARALLEL=true ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    -*)
      printf 'error: unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
    *)
      VARS_FILE="$arg"
      ;;
  esac
done

if [[ ! -f "$VARS_FILE" ]]; then
  printf 'error: vars file not found: %s\n' "$VARS_FILE" >&2
  exit 2
fi

# ── Phase 1: Collect (line_number, url, ref) tuples ─────────────────────
declare -a LINE_NUMS=() URLS=() REFS=()

while IFS= read -r match; do
  line_num="${match%%:*}"
  rest="${match#*:}"
  # Extract the git ls-remote command from the comment.
  # Pattern: #   git ls-remote <url> <ref>
  if [[ "$rest" =~ git[[:space:]]+ls-remote[[:space:]]+(https://[^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
    LINE_NUMS+=("$line_num")
    URLS+=("${BASH_REMATCH[1]}")
    REFS+=("${BASH_REMATCH[2]}")
  fi
done < <(grep -n 'git ls-remote' "$VARS_FILE")

count=${#LINE_NUMS[@]}
if [[ "$count" -eq 0 ]]; then
  printf 'No git ls-remote comments found in %s\n' "$VARS_FILE"
  exit 0
fi

printf 'Found %d pinned SHA(s) in %s\n\n' "$count" "$VARS_FILE"

# ── Phase 2: Fetch new SHAs ─────────────────────────────────────────────
declare -a NEW_SHAS=()
FAILURES=0
TMPDIR_PARALLEL=""

fetch_sha() {
  local idx="$1" url="$2" ref="$3"
  local sha
  if ! sha=$(git ls-remote "$url" "$ref" 2>/dev/null | awk 'NR==1{print $1}'); then
    return 1
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    return 1
  fi
  if [[ -n "${TMPDIR_PARALLEL:-}" ]]; then
    printf '%s' "$sha" > "${TMPDIR_PARALLEL}/${idx}"
  else
    NEW_SHAS[idx]="$sha"
  fi
}

if "$PARALLEL" && [[ "$count" -gt 1 ]]; then
  TMPDIR_PARALLEL=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_PARALLEL"' EXIT

  pids=()
  for i in "${!LINE_NUMS[@]}"; do
    fetch_sha "$i" "${URLS[$i]}" "${REFS[$i]}" &
    pids+=($!)
  done

  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      printf 'error: git ls-remote failed for %s %s\n' "${URLS[$i]}" "${REFS[$i]}" >&2
      FAILURES=$((FAILURES + 1))
      NEW_SHAS[i]=""
      continue
    fi
    sha_file="${TMPDIR_PARALLEL}/${i}"
    if [[ -f "$sha_file" ]]; then
      NEW_SHAS[i]=$(cat "$sha_file")
    else
      printf 'error: no SHA returned for %s %s\n' "${URLS[$i]}" "${REFS[$i]}" >&2
      FAILURES=$((FAILURES + 1))
      NEW_SHAS[i]=""
    fi
  done
else
  for i in "${!LINE_NUMS[@]}"; do
    if ! fetch_sha "$i" "${URLS[$i]}" "${REFS[$i]}"; then
      printf 'error: git ls-remote failed for %s %s\n' "${URLS[$i]}" "${REFS[$i]}" >&2
      FAILURES=$((FAILURES + 1))
      NEW_SHAS[i]=""
    fi
  done
fi

# ── Phase 3: Apply updates ──────────────────────────────────────────────
UPDATED=0
UNCHANGED=0

for i in "${!LINE_NUMS[@]}"; do
  new_sha="${NEW_SHAS[$i]:-}"
  [[ -z "$new_sha" ]] && continue

  comment_line="${LINE_NUMS[$i]}"
  sha_line=$((comment_line + 1))
  current_line=$(sed -n "${sha_line}p" "$VARS_FILE")

  # Extract the current SHA from the line (40 hex chars inside quotes).
  if [[ "$current_line" =~ \"([0-9a-f]{40})\" ]]; then
    old_sha="${BASH_REMATCH[1]}"
  else
    printf 'warning: no SHA found on line %d, skipping: %s\n' "$sha_line" "$current_line" >&2
    continue
  fi

  # Short repo name for display (last two path segments).
  short_repo="${URLS[$i]#https://github.com/}"
  short_repo="${short_repo%.git}"

  if [[ "$old_sha" == "$new_sha" ]]; then
    printf '  . %-50s  unchanged\n' "${short_repo} ${REFS[$i]}"
    UNCHANGED=$((UNCHANGED + 1))
  else
    printf '  * %-50s  %s -> %s\n' "${short_repo} ${REFS[$i]}" "${old_sha:0:12}" "${new_sha:0:12}"
    if ! "$DRY_RUN"; then
      sed -i '' "s/\"${old_sha}\"/\"${new_sha}\"/" "$VARS_FILE"
    fi
    UPDATED=$((UPDATED + 1))
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────
printf '\n'
if "$DRY_RUN"; then
  printf 'Dry run: %d would update, %d unchanged' "$UPDATED" "$UNCHANGED"
else
  printf 'Done: %d updated, %d unchanged' "$UPDATED" "$UNCHANGED"
fi
if [[ "$FAILURES" -gt 0 ]]; then
  printf ', %d failed' "$FAILURES"
fi
printf '\n'

[[ "$FAILURES" -gt 0 ]] && exit 1
exit 0
