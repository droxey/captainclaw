#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# run-sandboxed.sh — Launch a command inside a sandbox-exec policy.
#
# Reads the static profile from ~/.config/sandbox-exec/agent.sb, appends
# dynamic workdir rules (ancestor literals, subpath RW, worktree grants),
# writes a temporary policy file, then exec's sandbox-exec.
#
# Usage:
#   run-sandboxed.sh [--workdir=PATH] COMMAND [ARGS...]
#
# Workdir resolution order:
#   1. --workdir flag (explicit)
#   2. git rev-parse --show-toplevel (auto-detected git root)
#   3. pwd -P (current directory)
#
# Reference: https://github.com/eugene1g/agent-safehouse
# ===========================================================================

PROFILE="${HOME}/.config/sandbox-exec/agent.sb"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

WORKDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir=*) WORKDIR="${1#--workdir=}"; shift ;;
    --workdir)   WORKDIR="${2:?--workdir requires a path}"; shift 2 ;;
    --)          shift; break ;;
    *)           break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  printf 'Usage: run-sandboxed.sh [--workdir=PATH] COMMAND [ARGS...]\n' >&2
  exit 1
fi

if [[ ! -f "$PROFILE" ]]; then
  printf 'Error: static profile not found: %s\n' "$PROFILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve effective workdir
# ---------------------------------------------------------------------------

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
fi

if [[ ! -d "$WORKDIR" ]]; then
  printf 'Error: workdir does not exist: %s\n' "$WORKDIR" >&2
  exit 1
fi

WORKDIR="$(cd "$WORKDIR" && pwd -P)"

# ---------------------------------------------------------------------------
# Emit ancestor file-read* literals for a path
# ---------------------------------------------------------------------------

emit_ancestors() {
  local target="$1" current
  local -a parts=()

  current="$(dirname "$target")"
  while [[ "$current" != "/" ]]; do
    parts=("$current" "${parts[@]}")
    current="$(dirname "$current")"
  done

  [[ ${#parts[@]} -gt 0 ]] || return 0

  printf ';; Ancestor traversal for workdir\n'
  printf '(allow file-read*\n'
  for p in "${parts[@]}"; do
    printf '    (literal "%s")\n' "$p"
  done
  printf ')\n'
}

# ---------------------------------------------------------------------------
# Emit git worktree rules
# ---------------------------------------------------------------------------

emit_worktree_rules() {
  # Bail if workdir is not a git repo.
  git -C "$WORKDIR" rev-parse --git-dir &>/dev/null || return 0

  local git_dir
  git_dir="$(cd "$WORKDIR" && git rev-parse --git-dir 2>/dev/null)" || return 0

  # Make git_dir absolute.
  [[ "$git_dir" == /* ]] || git_dir="${WORKDIR}/${git_dir}"
  git_dir="$(cd "$git_dir" && pwd -P)"

  # --- Linked worktree: grant shared common dir read-write ----------------
  if [[ -f "${git_dir}/commondir" ]]; then
    local raw common_dir
    raw="$(< "${git_dir}/commondir")"
    if [[ "$raw" == /* ]]; then
      common_dir="$(cd "$raw" && pwd -P)"
    else
      common_dir="$(cd "${git_dir}/${raw}" && pwd -P)"
    fi

    # Only emit if the common dir is outside the workdir (otherwise the
    # workdir subpath grant already covers it).
    if [[ "$common_dir" != "$WORKDIR"* ]]; then
      printf '\n;; Git worktree shared common dir (refs, objects, hooks)\n'
      printf '(allow file-read* file-write*\n    (subpath "%s")\n)\n' "$common_dir"
    fi
  fi

  # --- Sibling worktrees: read-only snapshot ------------------------------
  local line wt resolved
  while IFS= read -r line; do
    wt="${line#worktree }"
    [[ -n "$wt" && -d "$wt" ]] || continue
    resolved="$(cd "$wt" && pwd -P)"
    [[ "$resolved" != "$WORKDIR" ]] || continue

    printf '\n;; Sibling worktree (read-only snapshot)\n'
    printf '(allow file-read*\n    (subpath "%s")\n)\n' "$resolved"
  done < <(git -C "$WORKDIR" worktree list --porcelain 2>/dev/null | grep '^worktree ')
}

# ---------------------------------------------------------------------------
# Assemble temporary policy
# ---------------------------------------------------------------------------

TMPFILE="$(mktemp /tmp/sandbox-agent.XXXXXX.sb)"
trap 'rm -f "$TMPFILE"' EXIT

{
  cat "$PROFILE"

  printf '\n'
  printf ';; ---------------------------------------------------------------------------\n'
  printf ';; 80 · Workdir: %s\n' "$WORKDIR"
  printf ';; Generated at launch by run-sandboxed.sh\n'
  printf ';; ---------------------------------------------------------------------------\n'
  printf '\n'

  emit_ancestors "$WORKDIR"

  printf '\n;; Workdir read-write access\n'
  printf '(allow file-read* file-write*\n    (subpath "%s")\n)\n' "$WORKDIR"

  emit_worktree_rules
} > "$TMPFILE"

# ---------------------------------------------------------------------------
# Launch sandboxed process
# ---------------------------------------------------------------------------

exec sandbox-exec -f "$TMPFILE" "$@"
