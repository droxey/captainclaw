#!/usr/bin/env bash
# bootstrap.sh — Single-command OpenClaw deployment on Ubuntu 24.04
#
# Usage (as root on a fresh VPS):
#   curl -fsSL https://raw.githubusercontent.com/droxey/clincher/main/bootstrap.sh | bash
#
# Or inspect first:
#   curl -fsSL https://raw.githubusercontent.com/droxey/clincher/main/bootstrap.sh -o bootstrap.sh
#   less bootstrap.sh
#   bash bootstrap.sh
#
# Non-interactive:
#   bash bootstrap.sh --config deploy.yml
#   bash bootstrap.sh --anthropic-key sk-ant-... --voyage-key pa-... --domain openclaw.example.com --admin-ip 1.2.3.4
#   CLINCHER_ANTHROPIC_KEY=sk-ant-... CLINCHER_DOMAIN=example.com bash bootstrap.sh
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────
VERSION="1.1.0"
REPO_URL="https://github.com/droxey/clincher.git"
INSTALL_DIR="/opt/clincher"
VAULT_PASS_FILE="${INSTALL_DIR}/.vault-pass"
LOG_FILE="/var/log/clincher-bootstrap.log"
REQUIRED_ID="ubuntu"
REQUIRED_VERSION="24.04"

# ── Colors (with no-color fallback) ────────────────────────────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null; then
  BOLD=$(tput bold)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  RED=$(tput setaf 1)
  CYAN=$(tput setaf 6)
  RESET=$(tput sgr0)
else
  BOLD="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

# ── Validators (pure functions, no side effects) ──────────────────────────
validate_ip() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  # Reject 0.0.0.0 — opens firewall to everything
  [[ "$1" != "0.0.0.0" ]] || return 1
}

validate_domain() {
  [[ "$1" == *.* && "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 ))
}

validate_anthropic_key() {
  [[ "$1" == sk-ant-* ]]
}

validate_voyage_key() {
  [[ "$1" == pa-* ]]
}

validate_proxy_choice() {
  [[ "$1" == "caddy" || "$1" == "tunnel" || "$1" == "tailscale" ]]
}

validate_nonempty() {
  [[ -n "$1" ]]
}

# ── Helpers ────────────────────────────────────────────────────────────────
info()   { printf '%s==>%s %s\n' "$GREEN"  "$RESET" "$1"; }
warn()   { printf '%s==>%s %s\n' "$YELLOW" "$RESET" "$1"; }
err()    { printf '%s==> ERROR:%s %s\n' "$RED" "$RESET" "$1" >&2; }
header() { printf '\n%s%s── Phase %s ──%s\n\n' "$BOLD" "$CYAN" "$1" "$RESET"; }

mask_key() {
  local key="$1"
  if [[ ${#key} -gt 8 ]]; then
    printf '%s...%s' "${key:0:4}" "${key: -4}"
  else
    printf '****'
  fi
}

# Track temp files for cleanup
_TEMP_FILES=()

cleanup() {
  local exit_code=$?
  # Scrub any plaintext secret temp files
  if [[ ${#_TEMP_FILES[@]} -gt 0 ]]; then
    for f in "${_TEMP_FILES[@]}"; do
      rm -f "$f" 2>/dev/null || true
    done
  fi
  if [[ $exit_code -ne 0 ]]; then
    err "Bootstrap failed (exit code $exit_code)."
    if [[ -f "$LOG_FILE" ]]; then
      err "Check log: $LOG_FILE"
    fi
    err "Fix the issue and re-run — the script is idempotent."
  fi
}
trap cleanup EXIT

# ── Prompt functions (safe — no eval) ──────────────────────────────────────
prompt_required() {
  local varname="$1" prompt_text="$2" validate="${3:-}" silent="${4:-}"
  local value=""

  # Non-interactive: check if already set
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    value="${!varname:-}"
    if [[ -z "$value" ]]; then
      err "$varname is required but not set. Provide via --config, CLI flag, or CLINCHER_* env var."
      exit 1
    fi
    if [[ -n "$validate" ]] && ! "$validate" "$value"; then
      err "$varname failed validation."
      exit 1
    fi
    return
  fi

  while true; do
    if [[ "$silent" == "silent" ]]; then
      printf '%s: ' "$prompt_text"
      read -rs value
      printf '\n'
    else
      printf '%s: ' "$prompt_text"
      read -r value
    fi
    if [[ -z "$value" ]]; then
      warn "This field is required."
      continue
    fi
    if [[ -n "$validate" ]] && ! "$validate" "$value"; then
      warn "Invalid input. Please try again."
      continue
    fi
    break
  done
  declare -g "$varname=$value"
}

prompt_default() {
  local varname="$1" prompt_text="$2" default="$3" validate="${4:-}"
  local value=""

  # Non-interactive: use existing value or default
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    value="${!varname:-}"
    value="${value:-$default}"
    if [[ -n "$validate" ]] && ! "$validate" "$value"; then
      warn "$varname='$value' failed validation — using default: $default"
      value="$default"
    fi
    declare -g "$varname=$value"
    return
  fi

  printf '%s [%s]: ' "$prompt_text" "$default"
  read -r value
  value="${value:-$default}"
  if [[ -n "$validate" ]] && ! "$validate" "$value"; then
    warn "Invalid input — using default: $default"
    value="$default"
  fi
  declare -g "$varname=$value"
}

prompt_optional() {
  local varname="$1" prompt_text="$2"
  local value=""

  # Non-interactive: use existing value or empty
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    value="${!varname:-}"
    declare -g "$varname=${value:-}"
    return
  fi

  printf '%s (Enter to skip): ' "$prompt_text"
  read -rs value
  printf '\n'
  declare -g "$varname=${value:-}"
}

# ── Argument Parser ────────────────────────────────────────────────────────
SHOW_HELP=false
SHOW_VERSION=false
DRY_RUN=false
SKIP_DEPS=false
SKIP_CLONE=false
FORCE_INTERACTIVE=false
VERBOSE=false
CONFIG_FILE=""
NON_INTERACTIVE=false

# Config variables (populated from flags/config/env/prompts)
# Precedence: CLI flags > config file > env vars > CLINCHER_* env vars > prompts
# Both unprefixed (ANTHROPIC_API_KEY) and prefixed (CLINCHER_ANTHROPIC_KEY) env
# vars are supported. Unprefixed takes priority — careful if your shell already
# exports ANTHROPIC_API_KEY for other tools.
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
VOYAGE_API_KEY="${VOYAGE_API_KEY:-}"
DOMAIN="${DOMAIN:-}"
ADMIN_IP="${ADMIN_IP:-}"
REVERSE_PROXY="${REVERSE_PROXY:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
SSH_PORT="${SSH_PORT:-}"

show_help() {
  cat <<'USAGE'
Usage: bootstrap.sh [OPTIONS]

Single-command OpenClaw deployment on Ubuntu 24.04.

Options:
  -c, --config FILE      Read configuration from FILE
  -d, --domain DOMAIN    Set deployment domain
  -p, --ssh-port PORT    Set SSH port (default: 9922)
  -i, --interactive      Force interactive prompts (even with config/env)
  -n, --dry-run          Show what would happen without making changes
  -v, --verbose          Verbose Ansible output
  -V, --version          Show version and exit
  -h, --help             Show this help and exit

  --anthropic-key KEY    Anthropic API key (starts with sk-ant-)
  --voyage-key KEY       Voyage API key (starts with pa-)
  --admin-ip IP          Admin IP for firewall whitelist
  --reverse-proxy TYPE   caddy, tunnel, or tailscale (default: caddy)
  --tunnel-token TOKEN   Cloudflare Tunnel token (required if --reverse-proxy=tunnel)
  --telegram-token TOKEN Telegram bot token (optional)
  --skip-deps            Skip dependency installation
  --skip-clone           Skip repository clone/update

Environment variables (lowest priority, overridden by flags and config):
  CLINCHER_ANTHROPIC_KEY, CLINCHER_VOYAGE_KEY, CLINCHER_DOMAIN,
  CLINCHER_ADMIN_IP, CLINCHER_REVERSE_PROXY, CLINCHER_TUNNEL_TOKEN,
  CLINCHER_TELEGRAM_TOKEN, CLINCHER_SSH_PORT, CLINCHER_CONFIG

Examples:
  # Interactive (default)
  bash bootstrap.sh

  # Non-interactive with flags
  bash bootstrap.sh --anthropic-key sk-ant-... --voyage-key pa-... \
    --domain openclaw.example.com --admin-ip 1.2.3.4

  # From config file
  bash bootstrap.sh --config deploy.yml

  # CI/CD with environment variables
  CLINCHER_ANTHROPIC_KEY=sk-ant-... CLINCHER_DOMAIN=example.com bash bootstrap.sh
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config)         CONFIG_FILE="$2";         shift 2 ;;
      -d|--domain)         DOMAIN="$2";              shift 2 ;;
      -p|--ssh-port)       SSH_PORT="$2";            shift 2 ;;
      -i|--interactive)    FORCE_INTERACTIVE=true;    shift ;;
      -n|--dry-run)        DRY_RUN=true;             shift ;;
      -v|--verbose)        VERBOSE=true;             shift ;;
      -V|--version)        SHOW_VERSION=true;        shift ;;
      -h|--help)           SHOW_HELP=true;           shift ;;
      --anthropic-key)     ANTHROPIC_API_KEY="$2";   shift 2 ;;
      --voyage-key)        VOYAGE_API_KEY="$2";      shift 2 ;;
      --admin-ip)          ADMIN_IP="$2";            shift 2 ;;
      --reverse-proxy)     REVERSE_PROXY="$2";       shift 2 ;;
      --tunnel-token)      TUNNEL_TOKEN="$2";        shift 2 ;;
      --telegram-token)    TELEGRAM_BOT_TOKEN="$2";  shift 2 ;;
      --skip-deps)         SKIP_DEPS=true;           shift ;;
      --skip-clone)        SKIP_CLONE=true;          shift ;;
      --)                  shift; break ;;
      -*)                  err "Unknown option: $1"; show_help; exit 1 ;;
      *)                   break ;;
    esac
  done
}

# ── Config File Loader ─────────────────────────────────────────────────────
load_config() {
  local config_file="$1"
  if [[ ! -f "$config_file" ]]; then
    err "Config file not found: $config_file"
    exit 1
  fi

  info "Loading config from $config_file"

  # Map config keys to variable names
  while IFS= read -r line; do
    # Strip comments and whitespace-only lines
    line="${line%%#*}"
    [[ -z "${line// /}" ]] && continue

    # Split on first colon
    local key="${line%%:*}"
    local val="${line#*:}"
    # Trim whitespace
    key="${key## }"; key="${key%% }"
    val="${val## }"; val="${val%% }"
    # Strip surrounding quotes
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"

    case "$key" in
      anthropic_key)     [[ -z "$ANTHROPIC_API_KEY" ]]   && ANTHROPIC_API_KEY="$val" ;;
      voyage_key)        [[ -z "$VOYAGE_API_KEY" ]]      && VOYAGE_API_KEY="$val" ;;
      domain)            [[ -z "$DOMAIN" ]]              && DOMAIN="$val" ;;
      admin_ip)          [[ -z "$ADMIN_IP" ]]            && ADMIN_IP="$val" ;;
      reverse_proxy)     [[ -z "$REVERSE_PROXY" ]]       && REVERSE_PROXY="$val" ;;
      tunnel_token)      [[ -z "$TUNNEL_TOKEN" ]]        && TUNNEL_TOKEN="$val" ;;
      telegram_token)    [[ -z "$TELEGRAM_BOT_TOKEN" ]]  && TELEGRAM_BOT_TOKEN="$val" ;;
      ssh_port)          [[ -z "$SSH_PORT" ]]            && SSH_PORT="$val" ;;
      *)                 warn "Unknown config key: $key (ignored)" ;;
    esac
  done < "$config_file"
}

# ── Environment Variable Loader ────────────────────────────────────────────
load_env_defaults() {
  [[ -z "$ANTHROPIC_API_KEY" ]]   && ANTHROPIC_API_KEY="${CLINCHER_ANTHROPIC_KEY:-}"
  [[ -z "$VOYAGE_API_KEY" ]]      && VOYAGE_API_KEY="${CLINCHER_VOYAGE_KEY:-}"
  [[ -z "$DOMAIN" ]]              && DOMAIN="${CLINCHER_DOMAIN:-}"
  [[ -z "$ADMIN_IP" ]]            && ADMIN_IP="${CLINCHER_ADMIN_IP:-}"
  [[ -z "$REVERSE_PROXY" ]]       && REVERSE_PROXY="${CLINCHER_REVERSE_PROXY:-}"
  [[ -z "$TUNNEL_TOKEN" ]]        && TUNNEL_TOKEN="${CLINCHER_TUNNEL_TOKEN:-}"
  [[ -z "$TELEGRAM_BOT_TOKEN" ]]  && TELEGRAM_BOT_TOKEN="${CLINCHER_TELEGRAM_TOKEN:-}"
  [[ -z "$SSH_PORT" ]]            && SSH_PORT="${CLINCHER_SSH_PORT:-}"
  [[ -z "$CONFIG_FILE" ]]         && CONFIG_FILE="${CLINCHER_CONFIG:-}"
}

# ── Config Resolver (interactive fallback) ─────────────────────────────────
resolve_config() {
  header "4/6: Configuration"

  # Detect non-interactive mode
  if [[ ! -t 0 ]] && [[ "$FORCE_INTERACTIVE" != "true" ]]; then
    NON_INTERACTIVE=true
  fi

  # If non-interactive, validate what we have and fail on missing required vars
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    local missing=()
    [[ -z "$ANTHROPIC_API_KEY" ]] && missing+=("ANTHROPIC_API_KEY (--anthropic-key or CLINCHER_ANTHROPIC_KEY)")
    [[ -z "$VOYAGE_API_KEY" ]]    && missing+=("VOYAGE_API_KEY (--voyage-key or CLINCHER_VOYAGE_KEY)")
    [[ -z "$DOMAIN" ]]            && missing+=("DOMAIN (--domain or CLINCHER_DOMAIN)")
    [[ -z "$ADMIN_IP" ]]          && missing+=("ADMIN_IP (--admin-ip or CLINCHER_ADMIN_IP)")
    if [[ ${#missing[@]} -gt 0 ]]; then
      err "Non-interactive mode: the following required variables are missing:"
      for m in "${missing[@]}"; do
        printf '  - %s\n' "$m" >&2
      done
      exit 1
    fi

    # Apply defaults for optional values
    REVERSE_PROXY="${REVERSE_PROXY:-caddy}"
    SSH_PORT="${SSH_PORT:-9922}"

    # Validate all values
    validate_anthropic_key "$ANTHROPIC_API_KEY" || { err "Invalid Anthropic key (must start with sk-ant-)"; exit 1; }
    validate_voyage_key "$VOYAGE_API_KEY"       || { err "Invalid Voyage key (must start with pa-)"; exit 1; }
    validate_domain "$DOMAIN"                   || { err "Invalid domain: $DOMAIN"; exit 1; }
    validate_ip "$ADMIN_IP"                     || { err "Invalid admin IP: $ADMIN_IP"; exit 1; }
    validate_proxy_choice "$REVERSE_PROXY"      || { err "Invalid reverse_proxy: $REVERSE_PROXY (must be caddy/tunnel/tailscale)"; exit 1; }
    validate_port "$SSH_PORT"                   || { err "Invalid SSH port: $SSH_PORT"; exit 1; }
    if [[ "$REVERSE_PROXY" == "tunnel" && -z "$TUNNEL_TOKEN" ]]; then
      err "tunnel_token is required when reverse_proxy is 'tunnel'"
      exit 1
    fi

    TELEGRAM_ENABLED="false"
    [[ -n "$TELEGRAM_BOT_TOKEN" ]] && TELEGRAM_ENABLED="true"

    info "Non-interactive mode — all required variables provided."
    return
  fi

  # ── Interactive mode ──
  printf '%sEnter your deployment settings below.%s\n' "$BOLD" "$RESET"
  printf 'API keys are entered silently (no echo).\n\n'

  # Anthropic API key
  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    local anthropic_key=""
    while true; do
      printf 'Anthropic API key: '
      read -rs anthropic_key
      printf '\n'
      if [[ -z "$anthropic_key" ]]; then
        warn "Required."
        continue
      fi
      if ! validate_anthropic_key "$anthropic_key"; then
        warn "Must start with 'sk-ant-'."
        continue
      fi
      break
    done
    ANTHROPIC_API_KEY="$anthropic_key"
  else
    info "Anthropic key: $(mask_key "$ANTHROPIC_API_KEY") (from flags/config/env)"
  fi

  # Voyage API key
  if [[ -z "$VOYAGE_API_KEY" ]]; then
    local voyage_key=""
    while true; do
      printf 'Voyage API key: '
      read -rs voyage_key
      printf '\n'
      if [[ -z "$voyage_key" ]]; then
        warn "Required."
        continue
      fi
      if ! validate_voyage_key "$voyage_key"; then
        warn "Must start with 'pa-'."
        continue
      fi
      break
    done
    VOYAGE_API_KEY="$voyage_key"
  else
    info "Voyage key: $(mask_key "$VOYAGE_API_KEY") (from flags/config/env)"
  fi

  # Domain
  if [[ -z "$DOMAIN" ]]; then
    local domain=""
    while true; do
      printf 'Domain name (e.g., openclaw.example.com): '
      read -r domain
      if ! validate_domain "$domain"; then
        warn "Enter a valid domain name."
        continue
      fi
      break
    done
    DOMAIN="$domain"
  else
    info "Domain: $DOMAIN (from flags/config/env)"
  fi

  # Admin IP (auto-detect with safe fallback)
  if [[ -z "$ADMIN_IP" ]]; then
    local detected_ip=""
    detected_ip=$(curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null || echo "")
    if [[ -n "$detected_ip" ]] && validate_ip "$detected_ip"; then
      prompt_default ADMIN_IP "Admin IP for SSH/firewall whitelist" "$detected_ip" "validate_ip"
    else
      warn "Could not auto-detect your IP (VPN/proxy may be active)."
      prompt_required ADMIN_IP "Admin IP for SSH/firewall whitelist" "validate_ip"
    fi
  else
    info "Admin IP: $ADMIN_IP (from flags/config/env)"
  fi

  # Reverse proxy
  if [[ -z "$REVERSE_PROXY" ]]; then
    prompt_default REVERSE_PROXY "Reverse proxy (caddy/tunnel/tailscale)" "caddy" "validate_proxy_choice"
  else
    if ! validate_proxy_choice "$REVERSE_PROXY"; then
      warn "Invalid reverse proxy '$REVERSE_PROXY' — defaulting to caddy."
      REVERSE_PROXY="caddy"
    fi
    info "Reverse proxy: $REVERSE_PROXY (from flags/config/env)"
  fi

  # Tunnel token (only if tunnel selected)
  if [[ "$REVERSE_PROXY" == "tunnel" && -z "$TUNNEL_TOKEN" ]]; then
    while true; do
      printf 'Cloudflare Tunnel token: '
      read -rs TUNNEL_TOKEN
      printf '\n'
      if [[ -z "$TUNNEL_TOKEN" ]]; then
        warn "Required when using Cloudflare Tunnel."
        continue
      fi
      break
    done
  fi

  # Optional: Telegram bot token
  if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    printf 'Telegram bot token (Enter to skip): '
    read -rs TELEGRAM_BOT_TOKEN
    printf '\n'
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  else
    info "Telegram: $(mask_key "$TELEGRAM_BOT_TOKEN") (from flags/config/env)"
  fi
  TELEGRAM_ENABLED="false"
  [[ -n "$TELEGRAM_BOT_TOKEN" ]] && TELEGRAM_ENABLED="true"

  # SSH port
  if [[ -z "$SSH_PORT" ]]; then
    prompt_default SSH_PORT "SSH port" "9922" "validate_port"
  else
    info "SSH port: $SSH_PORT (from flags/config/env)"
  fi

  # Confirmation
  printf '\n%s── Configuration Summary ────────────────────────%s\n' "$BOLD" "$RESET"
  printf '  Anthropic key:  %s\n' "$(mask_key "$ANTHROPIC_API_KEY")"
  printf '  Voyage key:     %s\n' "$(mask_key "$VOYAGE_API_KEY")"
  printf '  Domain:         %s\n' "$DOMAIN"
  printf '  Admin IP:       %s\n' "$ADMIN_IP"
  printf '  Reverse proxy:  %s\n' "$REVERSE_PROXY"
  printf '  Telegram:       %s\n' "$( [[ "$TELEGRAM_ENABLED" == "true" ]] && echo "enabled" || echo "disabled" )"
  printf '  SSH port:       %s\n' "$SSH_PORT"
  printf '%s─────────────────────────────────────────────────%s\n\n' "$BOLD" "$RESET"

  local confirm=""
  printf 'Proceed? [Y/n] '
  read -r confirm
  if [[ "${confirm,,}" == "n" ]]; then
    info "Aborted. Re-run bootstrap.sh to try again."
    exit 0
  fi
}

# ── Phase 1: Preflight ────────────────────────────────────────────────────
preflight() {
  header "1/6: Preflight checks"

  # Must be root
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
  fi

  # Must be Ubuntu 24.04
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" != "$REQUIRED_ID" || "${VERSION_ID:-}" != "$REQUIRED_VERSION" ]]; then
      err "Requires Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown}"
      exit 1
    fi
    info "OS: ${PRETTY_NAME}"
  else
    err "Cannot detect OS — /etc/os-release missing."
    exit 1
  fi

  # Internet connectivity
  if ! curl -fsSL --max-time 10 https://github.com -o /dev/null 2>/dev/null; then
    err "No internet connectivity. Cannot reach github.com."
    exit 1
  fi
  info "Internet connectivity OK"

  # Existing installation?
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    warn "Existing installation found at $INSTALL_DIR — will update."
    UPDATE_MODE=true
  else
    UPDATE_MODE=false
  fi
}

# ── Phase 2: Install Dependencies ─────────────────────────────────────────
install_deps() {
  header "2/6: Installing dependencies"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  info "Installing system packages..."
  apt-get install -y -qq \
    python3-pip python3-venv python3-full \
    pipx git curl openssl sshpass \
    > /dev/null 2>&1

  # Ansible via pipx
  if command -v ansible &>/dev/null; then
    info "Ansible already installed: $(ansible --version | head -1)"
  else
    info "Installing Ansible via pipx..."
    if ! PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin \
      pipx install --include-deps ansible >>"$LOG_FILE" 2>&1; then
      warn "pipx install failed — falling back to apt..."
      apt-get install -y -qq ansible > /dev/null 2>&1
    fi
  fi

  # Verify
  if ! command -v ansible &>/dev/null; then
    err "Ansible installation failed."
    exit 1
  fi
  info "$(ansible --version | head -1)"
}

verify_deps() {
  info "Verifying dependencies (--skip-deps)..."
  local missing=()
  command -v python3  &>/dev/null || missing+=("python3")
  command -v ansible  &>/dev/null || missing+=("ansible")
  command -v git      &>/dev/null || missing+=("git")
  command -v curl     &>/dev/null || missing+=("curl")
  command -v openssl  &>/dev/null || missing+=("openssl")
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required commands: ${missing[*]}"
    err "Remove --skip-deps or install them manually."
    exit 1
  fi
  info "All dependencies present."
}

# ── Phase 3: Clone / Update Repo ──────────────────────────────────────────
clone_repo() {
  header "3/6: Setting up clincher repository"

  if [[ "$UPDATE_MODE" == "true" ]]; then
    info "Updating existing repository..."
    cd "$INSTALL_DIR"
    git pull --ff-only origin main 2>/dev/null || {
      local stash_name
      stash_name="clincher-bootstrap-$(date +%Y%m%d%H%M%S)"
      warn "Fast-forward pull failed — stashing local changes as '$stash_name'..."
      git stash push -m "$stash_name"
      git pull --ff-only origin main
    }
  else
    info "Cloning repository..."
    git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
  fi

  info "Installing Ansible Galaxy collections..."
  if ! ansible-galaxy collection install -r requirements.yml --force >>"$LOG_FILE" 2>&1; then
    err "Failed to install Ansible Galaxy collections. Check $LOG_FILE"
    exit 1
  fi
  info "Repository ready at $INSTALL_DIR"
}

# ── Phase 5: Generate Configuration ────────────────────────────────────────
generate_config() {
  header "5/6: Generating configuration"

  cd "$INSTALL_DIR"

  # ── Check for existing vault ──
  SKIP_VAULT=false
  if [[ -f "group_vars/all/vault.yml" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      info "Existing vault.yml found — keeping (non-interactive mode)."
      SKIP_VAULT=true
    else
      local overwrite=""
      printf 'Existing vault.yml found. Overwrite? [y/N] '
      read -r overwrite
      if [[ "${overwrite,,}" != "y" ]]; then
        info "Keeping existing vault.yml. Skipping secret generation."
        SKIP_VAULT=true
      fi
    fi

    # Ensure we have a vault password file to decrypt the existing vault
    if [[ "$SKIP_VAULT" == "true" && ! -f "$VAULT_PASS_FILE" ]]; then
      if [[ "$NON_INTERACTIVE" == "true" ]]; then
        err "Existing vault.yml found but no vault password file at $VAULT_PASS_FILE."
        err "Provide the vault password file or remove vault.yml to regenerate."
        exit 1
      fi
      info "Existing vault.yml detected but no vault password file found."
      while true; do
        read -rs -p "Enter existing Ansible vault password for this host: " vault_pass_1
        echo
        read -rs -p "Confirm vault password: " vault_pass_2
        echo
        if [[ -n "$vault_pass_1" && "$vault_pass_1" == "$vault_pass_2" ]]; then
          printf '%s\n' "$vault_pass_1" > "$VAULT_PASS_FILE"
          chmod 0600 "$VAULT_PASS_FILE"
          unset vault_pass_1 vault_pass_2
          break
        else
          warn "Passwords did not match or were empty. Please try again."
        fi
      done
    fi
  fi

  if [[ "$SKIP_VAULT" == "false" ]]; then
    # ── Generate internal secrets ──
    info "Generating internal secrets..."
    local LITELLM_MASTER_KEY GATEWAY_TOKEN BACKUP_ENCRYPTION_KEY
    LITELLM_MASTER_KEY=$(openssl rand -hex 32)
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    BACKUP_ENCRYPTION_KEY=$(openssl rand -hex 32)

    # ── Vault password ──
    if [[ -f "$VAULT_PASS_FILE" ]]; then
      info "Reusing existing vault password."
    else
      info "Generating vault password..."
      openssl rand -base64 32 > "$VAULT_PASS_FILE"
      chmod 0600 "$VAULT_PASS_FILE"
    fi

    # ── Write vault.yml (plaintext) to a secure temporary file ──
    info "Writing vault.yml..."
    local vault_dir="group_vars/all"
    mkdir -p "$vault_dir"
    local tmp_vault
    tmp_vault=$(mktemp -p "$vault_dir" .vault.yml.XXXXXX)
    chmod 0600 "$tmp_vault"
    _TEMP_FILES+=("$tmp_vault")

    cat > "$tmp_vault" <<VAULT
---
anthropic_api_key: "${ANTHROPIC_API_KEY}"
voyage_api_key: "${VOYAGE_API_KEY}"
litellm_master_key: "${LITELLM_MASTER_KEY}"
gateway_token: "${GATEWAY_TOKEN}"
backup_encryption_key: "${BACKUP_ENCRYPTION_KEY}"
telegram_bot_token: "${TELEGRAM_BOT_TOKEN:-}"
tunnel_token: "${TUNNEL_TOKEN:-}"
github_token: ""
VAULT

    # ── Encrypt vault ──
    info "Encrypting vault.yml..."
    ansible-vault encrypt "$tmp_vault" \
      --vault-password-file "$VAULT_PASS_FILE" \
      --output "${vault_dir}/vault.yml"
    rm -f "$tmp_vault"

    info "IMPORTANT: Back up $VAULT_PASS_FILE to a secure, offline location."
    info "If lost, the encrypted vault.yml cannot be decrypted."
  fi

  # ── Write inventory for local execution ──
  info "Configuring inventory for local execution..."
  cat > "inventory/hosts.yml" <<'INVENTORY'
---
all:
  hosts:
    openclaw:
      ansible_host: 127.0.0.1
      ansible_connection: local
      ansible_user: root
      ansible_become: false
INVENTORY

  # ── Write bootstrap overrides (preserves vars.yml for clean git pulls) ──
  info "Writing bootstrap overrides..."
  cat > "group_vars/all/zzz_bootstrap.yml" <<OVERRIDES
---
# Auto-generated by bootstrap.sh — do not edit manually.
# This file overrides vars.yml defaults for this deployment.
admin_ip: "${ADMIN_IP}"
domain: "${DOMAIN}"
ssh_port: ${SSH_PORT}
reverse_proxy: "${REVERSE_PROXY}"
telegram_enabled: ${TELEGRAM_ENABLED}
OVERRIDES

  # ── Update .gitignore ──
  for entry in ".vault-pass" "group_vars/all/zzz_bootstrap.yml"; do
    if ! grep -qxF "$entry" .gitignore 2>/dev/null; then
      echo "$entry" >> .gitignore
    fi
  done

  info "Configuration complete."
}

# ── Phase 6: Run the Playbook ──────────────────────────────────────────────
run_playbook() {
  header "6/6: Deploying OpenClaw"

  cd "$INSTALL_DIR"

  # Determine how to supply the Ansible vault password
  local vault_args=()
  if [[ -f "$VAULT_PASS_FILE" ]]; then
    vault_args=(--vault-password-file "$VAULT_PASS_FILE")
  elif [[ "$NON_INTERACTIVE" == "true" ]]; then
    err "Vault password file '$VAULT_PASS_FILE' not found (required in non-interactive mode)."
    exit 1
  else
    read -r -p "Path to an existing Ansible vault password file (leave empty to have Ansible prompt for the password): " custom_vault_path
    if [[ -n "${custom_vault_path:-}" ]]; then
      if [[ ! -f "$custom_vault_path" ]]; then
        err "Provided vault password file '$custom_vault_path' does not exist."
        exit 1
      fi
      vault_args=(--vault-password-file "$custom_vault_path")
    else
      info "Proceeding without --vault-password-file; Ansible will prompt for the vault password if needed."
    fi
  fi

  # Build ansible-playbook command
  local ansible_args=(
    ansible-playbook playbook.yml
    "${vault_args[@]}"
    --skip-tags bootstrap
  )
  [[ "$VERBOSE" == "true" ]] && ansible_args+=(-vv)
  [[ "$DRY_RUN" == "true" ]]  && ansible_args+=(--check --diff)

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN — showing what would happen (no changes will be made)."
    info "Command: ${ansible_args[*]}"
  fi

  info "Running Ansible playbook (this will take a while)..."
  info "Log: $LOG_FILE"
  printf '\n'

  "${ansible_args[@]}" 2>&1 | tee "$LOG_FILE"

  local exit_code=${PIPESTATUS[0]}
  if [[ $exit_code -ne 0 ]]; then
    err "Playbook failed with exit code $exit_code."
    err "Review the log: $LOG_FILE"
    exit "$exit_code"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '\n'
    info "Dry run complete. No changes were made."
    info "Remove --dry-run to deploy for real."
    return
  fi

  printf '\n'
  printf '%s════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
  printf '%s  OpenClaw deployed successfully!%s\n' "$GREEN" "$RESET"
  printf '\n'
  printf '  Dashboard:    https://%s\n' "$DOMAIN"
  printf '  Vault pass:   %s\n' "$VAULT_PASS_FILE"
  printf '  Log:          %s\n' "$LOG_FILE"
  printf '  Re-deploy:    cd %s && make deploy\n' "$INSTALL_DIR"
  printf '\n'
  printf '  %sNext steps:%s\n' "$BOLD" "$RESET"
  printf '  1. Ensure DNS points %s to this server\n' "$DOMAIN"
  printf '  2. Wait for DNS propagation and TLS certificate issuance (may take a few minutes)\n'
  printf '  3. Test: curl -I https://%s\n' "$DOMAIN"
  printf '  4. Back up %s to a secure, offline location\n' "$VAULT_PASS_FILE"
  printf '%s════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  if [[ "$SHOW_HELP" == "true" ]]; then
    show_help
    exit 0
  fi
  if [[ "$SHOW_VERSION" == "true" ]]; then
    printf 'clincher bootstrap v%s\n' "$VERSION"
    exit 0
  fi

  # Load environment variables (lowest priority)
  load_env_defaults

  # Load config file (overrides env for unset values)
  if [[ -n "$CONFIG_FILE" ]]; then
    load_config "$CONFIG_FILE"
  fi

  # Detect non-interactive early for preflight messaging
  if [[ ! -t 0 ]] && [[ "$FORCE_INTERACTIVE" != "true" ]]; then
    NON_INTERACTIVE=true
  fi

  printf '\n%s%s  OpenClaw Bootstrap — clincher v%s%s\n' "$BOLD" "$CYAN" "$VERSION" "$RESET"
  printf '  https://github.com/droxey/clincher\n\n'

  preflight

  if [[ "$SKIP_DEPS" == "true" ]]; then
    verify_deps
  else
    install_deps
  fi

  if [[ "$SKIP_CLONE" == "true" ]]; then
    info "Skipping repository setup (--skip-clone)"
    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
      err "$INSTALL_DIR is not a git repository. Remove --skip-clone on first run."
      exit 1
    fi
    cd "$INSTALL_DIR"
  else
    clone_repo
  fi

  resolve_config
  generate_config
  run_playbook
}

main "$@"
