# Migrating from OpenClaw to ZeroClaw

**A step-by-step guide to replacing OpenClaw with ZeroClaw in the ClawSwarm hardened deployment.**

This guide assumes you have a working OpenClaw deployment following the [single-server guide](README.md) or the [Swarm guide](SWARM.md). It covers every file, service, configuration, and Ansible role that needs to change.

## Key Information

| | OpenClaw (Current) | ZeroClaw (Target) |
|---|---|---|
| **Language** | Node.js | Rust |
| **Image** | `openclaw/openclaw:2026.2.17` | `ghcr.io/zeroclaw-labs/zeroclaw:latest` |
| **RAM footprint** | >1 GB (gateway alone) | <5 MB (entire runtime) |
| **Binary size** | ~300 MB container | ~3.4 MB binary / ~15 MB distroless container |
| **Config format** | JSON (`config.json`) via `openclaw config set` | TOML (`config.toml`) via file editing or `zeroclaw onboard` |
| **Gateway port** | 18789 | 3000 |
| **Gateway bind** | `0.0.0.0` (default) | `127.0.0.1` (default — secure) |
| **Sandbox model** | Docker socket proxy + `openclaw sandbox` | Native workspace scoping + optional Docker runtime |
| **Memory/RAG** | External (Voyage AI required) | Built-in SQLite hybrid (FTS5 + vector), Voyage optional |
| **Model routing** | Requires LiteLLM proxy | Built-in 28+ provider support, LiteLLM optional |
| **Auth model** | Token-based (`gateway.auth.token`) | Pairing code → bearer token exchange |
| **Channel config** | `openclaw config set channels.*` | `[channels_config.*]` in `config.toml` |
| **Healthcheck** | `openclaw doctor --quiet` | `zeroclaw doctor` or `GET /health` |
| **Repo** | [github.com/openclaw](https://github.com/openclaw) | [github.com/zeroclaw-labs/zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) |

## Before You Start

### Decision: Keep or Drop LiteLLM?

ZeroClaw has built-in provider support for 28+ models (OpenRouter, Anthropic, OpenAI, Groq, Mistral, etc.) with native API key management. LiteLLM is **optional** but still valuable if you need:

- **Spend caps and per-model rate limiting** — ZeroClaw has no built-in budget enforcement
- **Redis semantic caching** — saves 15-30% on LLM costs by deduplicating similar prompts
- **Centralized audit logging** — LiteLLM logs every request with token counts and costs
- **Multi-provider failover routing** — automatic retry across providers

**Recommendation**: Keep LiteLLM for production deployments where cost control matters. Drop it for dev/personal instances where simplicity is more valuable than budget guardrails.

### Decision: Keep or Drop the Docker Socket Proxy?

OpenClaw needs the socket proxy because its sandbox model executes tools inside Docker containers spawned via the Docker API. ZeroClaw's sandbox model is fundamentally different:

- **Native runtime** (default): Commands execute in a sandboxed subprocess with filesystem scoping, command allowlists, and path traversal prevention. No Docker API access needed.
- **Docker runtime** (optional): If you want container-level isolation, ZeroClaw can spawn its own Docker containers using a `[runtime.docker]` config section — but it manages this internally, not through a socket proxy.

**Recommendation**: Drop the socket proxy. ZeroClaw's native sandbox with workspace scoping is sufficient for most deployments and eliminates an entire attack surface. If you need container isolation, use ZeroClaw's built-in Docker runtime instead.

### Decision: Keep or Drop the Squid Egress Proxy?

The egress proxy whitelists outbound HTTPS traffic to LLM provider domains. ZeroClaw's localhost-first gateway and built-in provider routing reduce the blast radius of a compromise, but an egress proxy still adds defense-in-depth.

**Recommendation**: Keep the egress proxy for production deployments. ZeroClaw's process could still be coerced into making arbitrary outbound requests via prompt injection — the Squid whitelist prevents data exfiltration to non-LLM domains.

### Backup Current Deployment

Before touching anything:

```bash
# Snapshot OpenClaw data and config
/opt/openclaw/monitoring/backup.sh

# Extra safety: export full OpenClaw config
docker exec openclaw openclaw config export > /opt/openclaw/monitoring/backups/openclaw-config-export.json

# Save current Compose file
cp /opt/openclaw/docker-compose.yml /opt/openclaw/docker-compose.yml.openclaw-backup
```

---

## Migration Overview

The migration touches **every layer** of the deployment:

| Layer | What Changes | Effort |
|-------|-------------|--------|
| Docker Compose | New image, new ports, new env vars, service removals | High |
| Gateway hardening | TOML config replaces 30+ `config set` commands | High |
| Ansible roles | Every `openclaw-*` role needs rewriting | High |
| Channel integration | Different config format (TOML sections vs CLI commands) | Medium |
| Memory/RAG | Built-in SQLite replaces Voyage AI dependency | Medium |
| Reverse proxy | Port change (18789 → 3000) | Low |
| Firewall/SSH/Docker daemon | No changes needed | None |
| Backup scripts | Container name + CLI command changes | Low |
| Monitoring | Container name changes, healthcheck endpoint changes | Low |

---

## Step 1: Import OpenClaw Configuration

ZeroClaw includes a built-in migration tool that imports OpenClaw configurations.

```bash
# Install ZeroClaw on the host (needed for migration — will run in Docker after)
curl -fsSL https://raw.githubusercontent.com/zeroclaw-labs/zeroclaw/main/scripts/bootstrap.sh | bash

# Preview what will be imported (safe — no changes made)
zeroclaw migrate openclaw --source /opt/openclaw --dry-run

# Run the migration
zeroclaw migrate openclaw --source /opt/openclaw
```

This creates `~/.zeroclaw/config.toml` with translated settings. Review it carefully — the tool handles identity files (SOUL.md) and basic configuration, but security hardening and service topology need manual attention.

> **What the migration tool does NOT cover**: Docker Compose topology, network architecture, Squid configuration, LiteLLM integration, Ansible roles, backup scripts, cron jobs, or monitoring. All of those are covered below.

---

## Step 2: Update Docker Compose File

This is the highest-impact change. The service topology simplifies significantly because ZeroClaw handles provider routing and memory internally.

### Minimal Topology (ZeroClaw + Egress Proxy)

If you chose to **drop LiteLLM and the socket proxy** (recommended for personal/dev deployments):

```bash
cat > /opt/openclaw/docker-compose.yml << 'COMPOSE_EOF'
services:
  zeroclaw:
    image: ghcr.io/zeroclaw-labs/zeroclaw:latest
    container_name: zeroclaw
    user: "65534:65534"
    environment:
      ZEROCLAW_WORKSPACE: /zeroclaw-data
      ZEROCLAW_GATEWAY_PORT: "3000"
      # Egress proxy — all outbound HTTPS routes through Squid
      HTTP_PROXY: http://zeroclaw-egress:3128
      HTTPS_PROXY: http://zeroclaw-egress:3128
      NO_PROXY: localhost,127.0.0.1
    volumes:
      - zeroclaw-data:/zeroclaw-data
    networks:
      - zeroclaw-net
      - proxy-net
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=64M
    depends_on:
      zeroclaw-egress:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "zeroclaw", "doctor"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 256M
        reservations:
          memory: 64M
    restart: unless-stopped

  zeroclaw-egress:
    image: ubuntu/squid:6.6-24.04_edge
    container_name: zeroclaw-egress
    volumes:
      - ./config/squid.conf:/etc/squid/squid.conf:ro
    networks:
      - zeroclaw-net
      - egress-net
    read_only: true
    tmpfs:
      - /var/spool/squid:size=64M
      - /var/log/squid:size=32M
      - /var/run:size=8M
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "squidclient -h localhost mgr:info 2>&1 | grep -q 'Squid Object Cache' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "0.25"
          memory: 128M
    restart: unless-stopped

networks:
  zeroclaw-net:
    driver: bridge
    internal: true
  proxy-net:
    driver: bridge
  egress-net:
    driver: bridge

volumes:
  zeroclaw-data:
COMPOSE_EOF
```

> **Resource impact**: The OpenClaw deployment used ~5.4 GB across 5 containers. This minimal ZeroClaw topology uses ~384 MB across 2 containers — freeing ~5 GB of RAM on the same 8 GB host.

### Full Topology (ZeroClaw + LiteLLM + Egress + Redis)

If you chose to **keep LiteLLM** for cost control and caching:

```bash
cat > /opt/openclaw/docker-compose.yml << 'COMPOSE_EOF'
services:
  zeroclaw:
    image: ghcr.io/zeroclaw-labs/zeroclaw:latest
    container_name: zeroclaw
    user: "65534:65534"
    environment:
      ZEROCLAW_WORKSPACE: /zeroclaw-data
      ZEROCLAW_GATEWAY_PORT: "3000"
      HTTP_PROXY: http://zeroclaw-egress:3128
      HTTPS_PROXY: http://zeroclaw-egress:3128
      NO_PROXY: zeroclaw-litellm,localhost,127.0.0.1
    volumes:
      - zeroclaw-data:/zeroclaw-data
    networks:
      - zeroclaw-net
      - proxy-net
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=64M
    depends_on:
      zeroclaw-egress:
        condition: service_healthy
      litellm:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "zeroclaw", "doctor"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 256M
        reservations:
          memory: 64M
    restart: unless-stopped

  litellm:
    image: ghcr.io/berriai/litellm:main-v1.81.3-stable
    container_name: zeroclaw-litellm
    volumes:
      - ./config/litellm-config.yaml:/app/config.yaml:ro
    environment:
      LITELLM_MASTER_KEY: "${LITELLM_MASTER_KEY}"
      ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"
      VOYAGE_API_KEY: "${VOYAGE_API_KEY}"
      REDIS_HOST: "zeroclaw-redis"
      REDIS_PORT: "6379"
      HTTP_PROXY: http://zeroclaw-egress:3128
      HTTPS_PROXY: http://zeroclaw-egress:3128
      NO_PROXY: zeroclaw-redis,localhost,127.0.0.1
    networks:
      - zeroclaw-net
    security_opt:
      - no-new-privileges:true
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:4000/health/liveliness || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 1G
    restart: unless-stopped

  zeroclaw-egress:
    image: ubuntu/squid:6.6-24.04_edge
    container_name: zeroclaw-egress
    volumes:
      - ./config/squid.conf:/etc/squid/squid.conf:ro
    networks:
      - zeroclaw-net
      - egress-net
    read_only: true
    tmpfs:
      - /var/spool/squid:size=64M
      - /var/log/squid:size=32M
      - /var/run:size=8M
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "squidclient -h localhost mgr:info 2>&1 | grep -q 'Squid Object Cache' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "0.25"
          memory: 128M
    restart: unless-stopped

  redis:
    image: redis/redis-stack-server:7.4.0-v3
    container_name: zeroclaw-redis
    volumes:
      - redis-data:/data
    networks:
      - zeroclaw-net
    read_only: true
    tmpfs:
      - /tmp:size=32M
    security_opt:
      - no-new-privileges:true
    command: >
      redis-server
      --maxmemory 96mb
      --maxmemory-policy allkeys-lru
      --save 300 10
      --appendonly no
      --protected-mode no
      --loadmodule /opt/redis-stack/lib/redisearch.so
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "0.25"
          memory: 128M
    restart: unless-stopped

networks:
  zeroclaw-net:
    driver: bridge
    internal: true
  proxy-net:
    driver: bridge
  egress-net:
    driver: bridge

volumes:
  zeroclaw-data:
  redis-data:
COMPOSE_EOF
```

### Key Compose Changes Explained

| Change | Why |
|--------|-----|
| `image: ghcr.io/zeroclaw-labs/zeroclaw:latest` | ZeroClaw uses GHCR, not Docker Hub |
| `user: "65534:65534"` | ZeroClaw's distroless image runs as nonroot by default |
| Port `3000` instead of `18789` | ZeroClaw's default gateway port |
| `read_only: true` + `tmpfs` | ZeroClaw's Rust binary supports read-only rootfs natively |
| `memory: 256M` instead of `4G` | ZeroClaw uses <5 MB RAM — 256 MB is generous headroom |
| No `DOCKER_HOST` env var | Socket proxy removed — ZeroClaw doesn't need Docker API access |
| No `OPENCLAW_DISABLE_BONJOUR` | ZeroClaw has no mDNS discovery to disable |
| No `NODE_OPTIONS` | Not Node.js — no V8 runtime tuning needed |
| `docker-proxy` service removed | ZeroClaw's native sandbox doesn't use a Docker socket proxy |
| Container names: `openclaw-*` → `zeroclaw-*` | Namespace consistency |

---

## Step 3: Create ZeroClaw Configuration

ZeroClaw uses a single TOML file instead of OpenClaw's `config set` CLI commands. Create the config and mount it into the container.

### Minimal Configuration (Without LiteLLM)

```bash
mkdir -p /opt/openclaw/config/zeroclaw

cat > /opt/openclaw/config/zeroclaw/config.toml << 'EOF'
# ── Provider ──────────────────────────────────────────────────────────
api_key = ""
default_provider = "anthropic"
default_model = "claude-opus-4-6"
default_temperature = 0.7

# ── Gateway ───────────────────────────────────────────────────────────
# ZeroClaw binds 127.0.0.1 by default. For Docker bridge access from
# the reverse proxy, we need 0.0.0.0 — but ONLY with a tunnel or
# reverse proxy in front. Never expose 0.0.0.0 directly to the internet.
[gateway]
host = "0.0.0.0"
port = 3000
allow_public_bind = true

# ── Autonomy ──────────────────────────────────────────────────────────
# "supervised" requires explicit approval for destructive commands.
# "readonly" blocks all writes. "full" is unrestricted (not recommended).
[autonomy]
level = "supervised"
workspace_only = true
allowed_commands = ["git", "ls", "cat", "grep", "find", "curl", "wget"]
forbidden_paths = ["/etc", "/root", "/proc", "/sys", "~/.ssh", "~/.gnupg", "~/.aws"]

# ── Memory ────────────────────────────────────────────────────────────
# Built-in SQLite hybrid search — no external vector DB needed.
# FTS5 handles keyword search, SQLite BLOBs store vector embeddings.
[memory]
backend = "sqlite"
auto_save = true
embedding_provider = "none"
vector_weight = 0.7
keyword_weight = 0.3

# ── Channels ──────────────────────────────────────────────────────────
[channels_config.telegram]
bot_token = ""
allowed_users = []
mention_only = true

# ── Identity ──────────────────────────────────────────────────────────
# Import SOUL.md from OpenClaw. ZeroClaw supports both OpenClaw markdown
# format and AIEOS JSON format for agent identity.
[identity]
format = "openclaw"

# ── Runtime ───────────────────────────────────────────────────────────
# Native sandbox with workspace scoping. For container isolation,
# change kind to "docker" and configure [runtime.docker].
[runtime]
kind = "native"

# ── Tunnel ────────────────────────────────────────────────────────────
# Set to "cloudflare", "tailscale", or "ngrok" if using a tunnel.
# With an external reverse proxy (Caddy), set to "none".
[tunnel]
provider = "none"
EOF
```

### Configuration with LiteLLM

If keeping LiteLLM, point ZeroClaw at it as a custom endpoint:

```bash
cat > /opt/openclaw/config/zeroclaw/config.toml << 'EOF'
# ── Provider (via LiteLLM) ────────────────────────────────────────────
# Route through LiteLLM for spend caps, caching, and audit logging.
# LiteLLM presents an OpenAI-compatible API on port 4000.
api_key = ""
default_provider = "custom:http://zeroclaw-litellm:4000"
default_model = "anthropic/claude-opus-4-6"
default_temperature = 0.7

# ── Gateway ───────────────────────────────────────────────────────────
[gateway]
host = "0.0.0.0"
port = 3000
allow_public_bind = true

# ── Autonomy ──────────────────────────────────────────────────────────
[autonomy]
level = "supervised"
workspace_only = true
allowed_commands = ["git", "ls", "cat", "grep", "find", "curl", "wget"]
forbidden_paths = ["/etc", "/root", "/proc", "/sys", "~/.ssh", "~/.gnupg", "~/.aws"]

# ── Memory ────────────────────────────────────────────────────────────
[memory]
backend = "sqlite"
auto_save = true
embedding_provider = "none"
vector_weight = 0.7
keyword_weight = 0.3

# ── Channels ──────────────────────────────────────────────────────────
[channels_config.telegram]
bot_token = ""
allowed_users = []
mention_only = true

# ── Identity ──────────────────────────────────────────────────────────
[identity]
format = "openclaw"

# ── Runtime ───────────────────────────────────────────────────────────
[runtime]
kind = "native"

# ── Tunnel ────────────────────────────────────────────────────────────
[tunnel]
provider = "none"
EOF
```

### Mount the Config in Docker Compose

Add the config volume mount to the `zeroclaw` service in your Compose file:

```diff
--- docker-compose.yml
+++ docker-compose.yml
@@ zeroclaw service
     volumes:
       - zeroclaw-data:/zeroclaw-data
+      - ./config/zeroclaw/config.toml:/zeroclaw-data/.zeroclaw/config.toml:ro
```

---

## Step 4: Security Hardening Translation

The biggest migration effort. OpenClaw uses 30+ `config set` CLI commands. ZeroClaw handles most of this through the TOML config and different architectural defaults.

### OpenClaw → ZeroClaw Security Mapping

| OpenClaw Setting | ZeroClaw Equivalent | Notes |
|---|---|---|
| `gateway.bind "0.0.0.0"` | `[gateway] host = "0.0.0.0"` | ZeroClaw defaults to `127.0.0.1` (more secure) |
| `gateway.auth.mode "token"` | Pairing code on startup | ZeroClaw uses 6-digit pairing → bearer token. No static tokens |
| `gateway.auth.token "<token>"` | N/A — auto-generated | Bearer token exchanged via `/pair` endpoint |
| `gateway.auth.allowTailscale false` | N/A | ZeroClaw has no Tailscale header auth |
| `discovery.mdns.mode "off"` | N/A | ZeroClaw has no mDNS discovery |
| `gateway.nodes.browser.mode "off"` | N/A | ZeroClaw has no browser node feature |
| `logging.redactSensitive "tools"` | N/A — ZeroClaw redacts by default | Secrets never appear in logs |
| `session.dmScope "per-channel-peer"` | `channels.*.dmPolicy "pairing"` equivalent | ZeroClaw's allowlist is deny-by-default |
| `plugins.allow '[]'` | `[autonomy] allowed_commands = [...]` | Allowlist instead of denylist |
| `agents.defaults.sandbox.mode "all"` | `[autonomy] workspace_only = true` | Different model — workspace scoping vs container sandbox |
| `agents.defaults.sandbox.docker.network "none"` | `[runtime.docker] network = "none"` | Only if using Docker runtime |
| `agents.defaults.sandbox.docker.capDrop '["ALL"]'` | Built into distroless image | ZeroClaw runs as UID 65534, no capabilities by default |
| `agents.defaults.sandbox.docker.memoryLimit "512m"` | `[runtime.docker] memory_limit_mb = 512` | Only if using Docker runtime |
| `agents.defaults.tools.deny '[...]'` | `[autonomy] allowed_commands = [...]` | ZeroClaw uses allowlist (safer) vs OpenClaw's denylist |
| `channels.telegram.token "..."` | `[channels_config.telegram] bot_token = "..."` | TOML config instead of CLI |
| `channels.telegram.streamMode "off"` | N/A | ZeroClaw's Telegram doesn't have this bug |
| `channels.*.dmPolicy "pairing"` | `[channels_config.telegram] allowed_users = []` | Empty list = deny all (same effect) |
| `memory.provider "voyage"` | `[memory] backend = "sqlite"` | Built-in — Voyage not required |
| `agents.defaults.apiBase "http://..."` | `default_provider = "custom:http://..."` | If keeping LiteLLM |
| `agents.defaults.model "anthropic/claude-opus-4-6"` | `default_model = "claude-opus-4-6"` | Slightly different naming |
| `agents.defaults.maxTokens 4096` | No direct equivalent | ZeroClaw handles context internally |
| `agents.defaults.model.heartbeat "..."` | No equivalent | ZeroClaw has no heartbeat system |

### What You Gain

- **Pairing-code auth** is more secure than static tokens — no token to leak, no token to rotate
- **Allowlist-based command control** is safer than denylist — new tools are blocked by default
- **Workspace scoping** prevents filesystem traversal without needing container isolation
- **Deny-by-default channels** block all senders until explicitly allowlisted
- **No mDNS, no browser nodes, no Bonjour** — these attack surfaces don't exist in ZeroClaw

### What You Lose

- **Per-model budget enforcement** — ZeroClaw has no built-in spend caps (keep LiteLLM if you need this)
- **Docker-level sandbox resource caps** — ZeroClaw's native sandbox doesn't enforce memory/CPU limits (use Docker runtime if needed)
- **Heartbeat model routing** — no ability to route background tasks to cheaper models
- **Session history compaction** — ZeroClaw manages context differently

---

## Step 5: Update Reverse Proxy Configuration

The only change is the gateway port: `18789` → `3000`.

### Caddy

```diff
--- Caddyfile
+++ Caddyfile
@@ -1,3 +1,3 @@
 openclaw.yourdomain.com {
-    reverse_proxy openclaw:18789
+    reverse_proxy zeroclaw:3000
 }
```

### Cloudflare Tunnel

Update the tunnel configuration in the Cloudflare dashboard:
- **Old**: `http://openclaw:18789`
- **New**: `http://zeroclaw:3000`

### Tailscale Serve

```bash
# Remove old serve rule
sudo tailscale serve reset

# Add new rule with ZeroClaw's port
sudo tailscale serve --bg https+insecure://localhost:3000
```

---

## Step 6: Update Squid Egress Configuration

The Squid config itself doesn't change — it whitelists LLM provider domains, which are the same regardless of the agent runtime. But container names change in diagnostic commands:

```diff
--- squid references
+++ squid references
-docker exec openclaw curl -x http://openclaw-egress:3128 -I https://api.anthropic.com
+docker exec zeroclaw curl -x http://zeroclaw-egress:3128 -I https://api.anthropic.com
```

If you dropped LiteLLM and ZeroClaw makes direct API calls, add any additional provider domains to the Squid whitelist:

```bash
# In /opt/openclaw/config/squid.conf, add as needed:
acl llm_apis dstdomain .groq.com
acl llm_apis dstdomain .x.ai
acl llm_apis dstdomain .googleapis.com
acl llm_apis dstdomain .deepseek.com
acl llm_apis dstdomain .together.xyz
```

---

## Step 7: Update Environment Variables File

```bash
cat > /opt/openclaw/.env << 'EOF'
# ── ZeroClaw Direct Provider Keys ────────────────────────────────────
# Only needed if NOT using LiteLLM. ZeroClaw reads these from config.toml.
# ANTHROPIC_API_KEY=sk-ant-your-key-here

# ── LiteLLM (if keeping) ─────────────────────────────────────────────
LITELLM_MASTER_KEY=your-existing-master-key
ANTHROPIC_API_KEY=sk-ant-your-key-here
VOYAGE_API_KEY=pa-your-key-here

# ── Optional ──────────────────────────────────────────────────────────
# OPENAI_API_KEY=sk-your-key-here
# TUNNEL_TOKEN=your-tunnel-token
EOF
chmod 600 /opt/openclaw/.env
```

> **Key difference**: If running without LiteLLM, ZeroClaw reads the API key from `config.toml` (`api_key = "sk-ant-..."`) — not from environment variables. Secrets in `config.toml` are encrypted at rest using ChaCha20-Poly1305 (the `enc2:` prefix). Use `zeroclaw onboard --api-key sk-...` to set it securely, or edit the config file directly.

---

## Step 8: Update LiteLLM Configuration (If Keeping)

The LiteLLM config itself doesn't change — it's provider-facing, not agent-facing. The only update is container name references in the Redis host:

```diff
--- config/litellm-config.yaml
+++ config/litellm-config.yaml
@@ cache_params
-    host: "openclaw-redis"
+    host: "zeroclaw-redis"
```

And the `.env` `REDIS_HOST` variable:

```diff
--- .env (LiteLLM section)
+++ .env (LiteLLM section)
-REDIS_HOST: "openclaw-redis"
+REDIS_HOST: "zeroclaw-redis"
```

---

## Step 9: Migrate SOUL.md (Agent Identity)

ZeroClaw supports OpenClaw's markdown identity format natively. Copy your existing SOUL.md:

```bash
# Extract SOUL.md from OpenClaw data volume
docker run --rm \
  -v openclaw_openclaw-data:/source:ro \
  -v /opt/openclaw/config/zeroclaw:/dest \
  alpine:3.21 cp /source/SOUL.md /dest/SOUL.md

# Mount it in the Compose file (add to zeroclaw service volumes):
#   - ./config/zeroclaw/SOUL.md:/zeroclaw-data/.zeroclaw/SOUL.md:ro
```

Update the SOUL.md content to reference ZeroClaw:

```diff
--- SOUL.md
+++ SOUL.md
-# OpenClaw Agent — System Guidelines
+# ZeroClaw Agent — System Guidelines

 ## Identity
-You are a helpful AI assistant running on a hardened OpenClaw deployment.
+You are a helpful AI assistant running on a hardened ZeroClaw deployment.
```

---

## Step 10: Execute the Migration

### Stop OpenClaw

```bash
cd /opt/openclaw
docker compose down
```

### Migrate Data Volume

ZeroClaw's data directory structure differs from OpenClaw's. The migration tool handles this, but verify manually:

```bash
# Create ZeroClaw data directory
docker volume create zeroclaw-data

# If the migration tool already ran (Step 1), the config is at ~/.zeroclaw/
# Copy it into the Docker volume:
docker run --rm \
  -v zeroclaw-data:/dest \
  -v /opt/openclaw/config/zeroclaw:/src:ro \
  alpine:3.21 sh -c '
    mkdir -p /dest/.zeroclaw /dest/workspace
    cp /src/config.toml /dest/.zeroclaw/config.toml
    [ -f /src/SOUL.md ] && cp /src/SOUL.md /dest/.zeroclaw/SOUL.md
    chown -R 65534:65534 /dest
  '
```

### Start ZeroClaw

```bash
docker compose up -d
```

### First-Run Pairing

ZeroClaw prints a 6-digit pairing code to the container logs on first start:

```bash
docker compose logs zeroclaw 2>&1 | grep -i "pairing"
# Look for: "Pairing code: 123456"
```

Exchange the pairing code for a bearer token:

```bash
# From the host or reverse proxy
curl -X POST http://localhost:3000/pair \
  -H "X-Pairing-Code: 123456" \
  -H "Content-Type: application/json"
# Response includes the bearer token — save it
```

> **This replaces the old token rotation workflow.** ZeroClaw's pairing model means you don't need `rotate-token.sh` — the pairing code is single-use and the bearer token is session-scoped.

---

## Step 11: Update Verification Commands

### CLI Command Mapping

| OpenClaw Command | ZeroClaw Equivalent |
|---|---|
| `openclaw doctor --quiet` | `zeroclaw doctor` |
| `openclaw security audit --deep` | `zeroclaw status` (no direct equivalent) |
| `openclaw sandbox explain` | `zeroclaw status` (shows runtime info) |
| `openclaw config set <key> <value>` | Edit `config.toml` directly |
| `openclaw config get <key>` | `zeroclaw config schema` or read `config.toml` |
| `openclaw config export` | `cat ~/.zeroclaw/config.toml` |
| `openclaw memory index` | Automatic — SQLite indexes on write |
| `openclaw memory index --verify` | `zeroclaw channel doctor` |
| `openclaw usage cost` | No built-in equivalent (use LiteLLM `/spend/logs`) |
| `openclaw session new` | N/A — ZeroClaw manages sessions internally |

### Updated Verification Script

```bash
# ── Health Check ──────────────────────────────────────────────────────
docker exec zeroclaw zeroclaw doctor

# ── Container Health ──────────────────────────────────────────────────
docker compose ps
# All containers should show "healthy"

# ── Gateway Health (HTTP) ─────────────────────────────────────────────
curl -s http://localhost:3000/health
# Expected: 200 OK

# ── Egress Proxy (whitelisted domain — should succeed) ────────────────
docker exec zeroclaw curl -x http://zeroclaw-egress:3128 -I https://api.anthropic.com

# ── Egress Proxy (non-whitelisted — should fail with 403) ────────────
docker exec zeroclaw curl -x http://zeroclaw-egress:3128 -I https://example.com 2>&1 | head -5

# ── LiteLLM (if keeping) ─────────────────────────────────────────────
docker exec zeroclaw-litellm wget -qO- http://localhost:4000/health/liveliness

# ── Redis (if keeping) ───────────────────────────────────────────────
docker exec zeroclaw-redis redis-cli ping

# ── Resource Usage ────────────────────────────────────────────────────
docker stats --no-stream

# ── Auth Verification ─────────────────────────────────────────────────
# Gateway should reject unauthenticated webhook requests
curl -s -o /dev/null -w "%{http_code}" -X POST https://openclaw.yourdomain.com/webhook
# Expected: 401 or 403
```

---

## Step 12: Update Maintenance Scripts

### Backup Script Changes

```diff
--- monitoring/backup.sh
+++ monitoring/backup.sh
-  docker run --rm \
-    -v openclaw_openclaw-data:/source:ro \
-    -v /opt/openclaw/monitoring/backups:/backup \
-    alpine:3.21 tar -czf "/backup/openclaw-data-$(date +%F).tar.gz" -C /source . 2>> "$LOG"
+  docker run --rm \
+    -v openclaw_zeroclaw-data:/source:ro \
+    -v /opt/openclaw/monitoring/backups:/backup \
+    alpine:3.21 tar -czf "/backup/zeroclaw-data-$(date +%F).tar.gz" -C /source . 2>> "$LOG"

-  docker exec openclaw openclaw security audit --deep >> "$LOG" 2>&1
-  docker exec openclaw openclaw doctor >> "$LOG" 2>&1
+  docker exec zeroclaw zeroclaw doctor >> "$LOG" 2>&1
```

### Token Rotation Script

**This script can be removed.** ZeroClaw uses pairing-code authentication — bearer tokens are exchanged per-session, not stored as static secrets. There is no long-lived token to rotate.

If you still want periodic credential rotation for the LiteLLM master key:

```diff
--- monitoring/rotate-token.sh
+++ monitoring/rotate-token.sh (LiteLLM key rotation only)
-  docker cp "${TOKEN_FILE}.new" openclaw:/tmp/.gw-token
-  docker exec openclaw \
-    sh -c 'openclaw config set gateway.auth.token "$(cat /tmp/.gw-token)" && rm -f /tmp/.gw-token'
+  # Update LiteLLM master key in .env
+  NEW_KEY=$(openssl rand -hex 32)
+  sed -i "s/^LITELLM_MASTER_KEY=.*/LITELLM_MASTER_KEY=${NEW_KEY}/" /opt/openclaw/.env

-  docker compose -f /opt/openclaw/docker-compose.yml restart openclaw
+  docker compose -f /opt/openclaw/docker-compose.yml restart litellm
```

### Watchdog Script Changes

```diff
--- monitoring/watchdog.sh
+++ monitoring/watchdog.sh
-CONTAINERS=("openclaw" "openclaw-docker-proxy" "openclaw-egress" "openclaw-litellm" "openclaw-redis")
+# Minimal topology (without LiteLLM):
+CONTAINERS=("zeroclaw" "zeroclaw-egress")
+# Full topology (with LiteLLM):
+# CONTAINERS=("zeroclaw" "zeroclaw-egress" "zeroclaw-litellm" "zeroclaw-redis")
```

---

## Step 13: Update Ansible Roles

Every `openclaw-*` role needs updating. Here's the mapping:

### Role Renaming

| Old Role | New Role | Changes |
|----------|----------|---------|
| `base` | `base` | **No changes** — SSH, Docker, sysctl, UFW, fail2ban are runtime-agnostic |
| `openclaw-config` | `zeroclaw-config` | New Compose template, TOML config template, remove LiteLLM config (if dropping) |
| `openclaw-deploy` | `zeroclaw-deploy` | `docker compose up`, new health checks, remove Squid ACL tightening step |
| `openclaw-harden` | `zeroclaw-harden` | Replace 30+ `config set` commands with TOML template rendering |
| `openclaw-integrate` | `zeroclaw-integrate` | TOML channel config instead of CLI commands |
| `reverse-proxy` | `reverse-proxy` | Port change in templates (`18789` → `3000`) |
| `verify` | `verify` | New CLI commands (`zeroclaw doctor` instead of `openclaw doctor`) |
| `maintenance` | `maintenance` | Container name updates in all script templates |
| `monitoring` | `monitoring` | Container name updates in Prometheus scrape config |

### Key Template Changes

#### `group_vars/all/vars.yml`

```diff
-# ── OpenClaw ──────────────────────────────────────────────────────────
-openclaw_version: "2026.2.17"
-openclaw_image: "openclaw/openclaw:{{ openclaw_version }}"
-openclaw_memory: "4G"
+# ── ZeroClaw ──────────────────────────────────────────────────────────
+zeroclaw_image: "ghcr.io/zeroclaw-labs/zeroclaw:latest"
+zeroclaw_memory: "256M"
+zeroclaw_gateway_port: 3000

+# ── ZeroClaw Security ────────────────────────────────────────────────
+zeroclaw_autonomy_level: "supervised"
+zeroclaw_workspace_only: true
+zeroclaw_allowed_commands: ["git", "ls", "cat", "grep", "find", "curl", "wget"]
+zeroclaw_memory_backend: "sqlite"
+zeroclaw_default_provider: "anthropic"
+zeroclaw_default_model: "claude-opus-4-6"

 # ── Socket Proxy ──────────────────────────────────────────────────────
-docker_proxy_image: "tecnativa/docker-socket-proxy:0.6.0"
+# REMOVED — ZeroClaw doesn't use a Docker socket proxy

-sandbox_memory: "512m"
-sandbox_cpu: "0.5"
-sandbox_max_concurrent: 3
+# REMOVED — ZeroClaw uses native workspace scoping, not container sandboxes
```

#### `roles/zeroclaw-config/templates/config.toml.j2`

```toml
api_key = "{{ anthropic_api_key }}"
{% if litellm_enabled | default(true) %}
default_provider = "custom:http://zeroclaw-litellm:4000"
{% else %}
default_provider = "{{ zeroclaw_default_provider }}"
{% endif %}
default_model = "{{ zeroclaw_default_model }}"
default_temperature = 0.7

[gateway]
host = "0.0.0.0"
port = {{ zeroclaw_gateway_port }}
allow_public_bind = true

[autonomy]
level = "{{ zeroclaw_autonomy_level }}"
workspace_only = {{ zeroclaw_workspace_only | lower }}
allowed_commands = {{ zeroclaw_allowed_commands | to_json }}
forbidden_paths = ["/etc", "/root", "/proc", "/sys", "~/.ssh", "~/.gnupg", "~/.aws"]

[memory]
backend = "{{ zeroclaw_memory_backend }}"
auto_save = true
embedding_provider = "none"
vector_weight = 0.7
keyword_weight = 0.3

{% if telegram_enabled | default(true) %}
[channels_config.telegram]
bot_token = "{{ telegram_bot_token }}"
allowed_users = {{ telegram_allowed_users | default([]) | to_json }}
mention_only = true
{% endif %}

[identity]
format = "openclaw"

[runtime]
kind = "native"

[tunnel]
provider = "none"
```

#### `roles/reverse-proxy/templates/Caddyfile.j2`

```diff
 {{ domain }} {
-    reverse_proxy openclaw:18789
+    reverse_proxy zeroclaw:{{ zeroclaw_gateway_port | default(3000) }}
 }
```

---

## Step 14: Update System Tuning (Optional)

ZeroClaw's tiny footprint changes the resource math:

```diff
--- /etc/sysctl.d/99-openclaw.conf
+++ /etc/sysctl.d/99-zeroclaw.conf
 # Swap behavior — ZeroClaw uses <5 MB RAM, so swap pressure is unlikely.
-# On an 8 GB box with a 4G+ OpenClaw container, keep swappiness low.
-vm.swappiness = 10
+# With ZeroClaw using <256 MB total, you could increase swappiness or
+# remove the 4 GB swap partition entirely. Keeping it at 10 is safe.
+vm.swappiness = 10
```

The freed RAM (~5 GB) means you can:
- Run more concurrent services on the same box
- Add the Prometheus + Grafana monitoring stack without reducing sandbox concurrency
- Lower the VPS tier from 8 GB to 4 GB (or even 2 GB for ZeroClaw alone)

---

## Step 15: Cleanup

After verifying the migration works:

```bash
# Remove old OpenClaw data volume (AFTER confirming backups)
docker volume rm openclaw_openclaw-data

# Remove old OpenClaw image
docker rmi openclaw/openclaw:2026.2.17

# Remove socket proxy image
docker rmi tecnativa/docker-socket-proxy:0.6.0

# Clean up dangling images
docker image prune -f
```

---

## Rollback Plan

If the migration fails, restore the OpenClaw deployment:

```bash
# Stop ZeroClaw
docker compose down

# Restore the backup Compose file
cp /opt/openclaw/docker-compose.yml.openclaw-backup /opt/openclaw/docker-compose.yml

# Restart OpenClaw
docker compose up -d

# Verify
docker compose ps
docker exec openclaw openclaw doctor
```

The OpenClaw data volume (`openclaw_openclaw-data`) is not touched during migration — it remains intact until you explicitly remove it in Step 15.

---

## Post-Migration Checklist

- [ ] All containers show `healthy` in `docker compose ps`
- [ ] `zeroclaw doctor` passes inside the container
- [ ] `GET /health` returns 200 on the gateway
- [ ] Egress proxy blocks non-whitelisted domains
- [ ] Egress proxy allows whitelisted LLM provider domains
- [ ] Telegram bot responds to messages (if enabled)
- [ ] Pairing code flow works — bearer token accepted for webhook requests
- [ ] Reverse proxy routes traffic to port 3000
- [ ] Backup script runs successfully with new container names
- [ ] Watchdog script monitors correct container names
- [ ] LiteLLM health check passes (if keeping)
- [ ] Redis cache is accessible (if keeping)
- [ ] Old OpenClaw data volume backed up before deletion
- [ ] SOUL.md identity file migrated and readable
- [ ] `docker stats` shows expected resource usage (<256 MB for ZeroClaw)

---

## Sources

- [ZeroClaw GitHub Repository](https://github.com/zeroclaw-labs/zeroclaw)
- [ZeroClaw Releases](https://github.com/zeroclaw-labs/zeroclaw/releases)
- [ZeroClaw Container Package (GHCR)](https://github.com/zeroclaw-labs/zeroclaw/pkgs/container/zeroclaw)
- [ZeroClaw Commands Reference](https://github.com/zeroclaw-labs/zeroclaw/blob/main/docs/commands-reference.md)
- [ZeroClaw Changelog](https://github.com/zeroclaw-labs/zeroclaw/blob/main/CHANGELOG.md)
- [ZeroClaw Dockerfile](https://github.com/zeroclaw-labs/zeroclaw/blob/main/Dockerfile)
- [Cloudron Forum — ZeroClaw Discussion](https://forum.cloudron.io/topic/15080/zeroclaw-rust-based-alternative-to-openclaw-picoclaw-nanobot-agentzero)
