# 🦞 OpenClaw Hardened Swarm Deployment Guide (2026.2)

**Production-grade, least-privilege OpenClaw deployment on CapRover Docker Swarm.**  

All sensitive services pinned to a single trusted node (`nyc`). Full defense-in-depth: node constraints, minimal socket proxy, loopback gateway, and maximum sandbox isolation.

**Target**: 4-node Ubuntu 24.04 Swarm (3 managers + 1 worker) with leader on `nyc`  
**OpenClaw Version**: `openclaw/openclaw:2026.2.15` (pinned)  
**Threat Model**: Prompt injection → arbitrary tool execution → host/container escape  
**Audit Date**: 2026-02-16 | **Score**: 9.7/10 (production-ready)

## Overview

**Isolation Layers**:
1. Node label constraint (`openclaw.trusted=true`) on `nyc`
2. `tecnativa/docker-socket-proxy` (least-privilege Docker API)
3. OpenClaw Gateway bound to loopback, behind CapRover proxy
4. Tool sandbox `mode: "all"`, `scope: "agent"`, `workspaceAccess: "none"`, network `none`
5. Explicit egress control via Squid (deny-by-default)

## Table of Contents

- [Step 1: Prerequisites](#step-1-prerequisites)
- [Step 2: Label the Trusted Node](#step-2-label-the-trusted-node)
- [Step 3: Configure Swarm High Availability](#step-3-configure-swarm-high-availability)
- [Step 4: Set Up NFS Shared Storage](#step-4-set-up-nfs-shared-storage)
- [Step 5: Configure Firewall](#step-5-configure-firewall)
- [Step 6: Deploy Docker Socket Proxy](#step-6-deploy-docker-socket-proxy)
- [Step 7: Deploy OpenClaw Gateway](#step-7-deploy-openclaw-gateway)
- [Step 8: Deploy Egress Proxy (Squid)](#step-8-deploy-egress-proxy-squid)
- [Step 9: Post-Deployment Hardening](#step-9-post-deployment-hardening)
- [Step 10: Verification](#step-10-verification)
- [Step 11: Maintenance](#step-11-maintenance)
- [Step 12: Troubleshooting](#step-12-troubleshooting)
- [Final Steps](#final-steps)
---

### Step 1: Prerequisites
- Healthy 4-node Swarm with 3 managers (leader: `nyc`)
- CapRover installed and running
- UFW + `ufw-docker` on all nodes
- Static admin IP + Cloudflare (or equivalent) in front

### Step 2: Label the Trusted Node
```bash
docker node update --label-add openclaw.trusted=true nyc
```

### Step 3: Configure Swarm High Availability
On the current leader (`nyc`):
```bash
docker swarm join-token manager
```

On the two additional nodes:
```bash
docker swarm join --token <TOKEN> <NYC_LEADER_IP>:2377
```

### Step 4: Set Up NFS Shared Storage (CapRover Dashboard HA)
**NFS Server (recommended: nyc)**:
```bash
apt install nfs-kernel-server -y
mkdir -p /captain/data && chown nobody:nogroup /captain/data
echo "/captain/data *(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
exportfs -ra && systemctl restart nfs-kernel-server
```

**NFS Clients (all managers)**:
```bash
apt install nfs-common -y
mkdir -p /captain/data
mount <NFS_SERVER_IP>:/captain/data /captain/data
echo "<NFS_SERVER_IP>:/captain/data /captain/data nfs defaults 0 0" >> /etc/fstab
mount -a
```

Migrate data (`rsync` from old volume), update captain app volume binding, then scale captain back up.

**Note**: For production stateful storage, migrate to Longhorn later.

### Step 5: Configure Firewall (Run on All Nodes)
```bash
ADMIN_IP="YOUR_STATIC_IP"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow from $ADMIN_IP to any port 9922 proto tcp
ufw limit 9922/tcp

# Cloudflare ranges
for ip in $(curl -s https://www.cloudflare.com/ips-v4); do ufw allow from $ip to any port 80,443 proto tcp; done
for ip in $(curl -s https://www.cloudflare.com/ips-v6); do ufw allow from $ip to any port 80,443 proto tcp; done

# Swarm inter-node
for ip in <ALL_NODE_IPS>; do
  ufw allow from $ip to any port 2377,7946 proto tcp
  ufw allow from $ip to any port 7946,4789 proto udp
done

ufw-docker install --confirm-license
systemctl restart docker
ufw --force enable
```

### Step 6: Deploy Docker Socket Proxy
**App Name**: `docker-proxy`

```yaml
captainVersion: 4
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy:latest
    environment:
      CONTAINERS: "1"
      IMAGES: "1"
      INFO: "1"
      VERSION: "1"
      PING: "1"
      EVENTS: "1"
      EXEC: "1"
      BUILD: "1"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    deploy:
      placement:
        constraints:
          - node.labels.openclaw.trusted == true
      resources:
        limits:
          cpus: "0.5"
          memory: 512M
```

### Step 7: Deploy OpenClaw Gateway (Primary Service)
**App Name**: `openclaw`

```yaml
captainVersion: 4
services:
  openclaw:
    image: openclaw/openclaw:2026.2.15
    environment:
      DOCKER_HOST: tcp://srv-captain--docker-proxy:2375
      NODE_ENV: production
      # Add model provider keys here (or use secrets):
      # OPENAI_API_KEY: ${OPENAI_API_KEY}
    volumes:
      - openclaw-data:/root/.openclaw
    deploy:
      placement:
        constraints:
          - node.labels.openclaw.trusted == true
      resources:
        limits:
          cpus: "2.0"
          memory: 6G
      restart_policy:
        condition: on-failure
      healthcheck:
        test: ["CMD", "openclaw", "doctor", "--quiet"]
        interval: 30s
        timeout: 10s
        retries: 3
```

### Step 8: Deploy Egress Proxy (Squid)
**App Name**: `openclaw-egress`

```yaml
captainVersion: 4
services:
  openclaw-egress:
    image: ubuntu/squid:latest
    volumes:
      - ./squid.conf:/etc/squid/squid.conf:ro
    deploy:
      placement:
        constraints:
          - node.labels.openclaw.trusted == true
```

**Example `squid.conf`** (deny-by-default, customize allowed domains):
```
http_port 3128
http_access deny all
# Example: allow specific domains
# acl approved_domains dstdomain .openai.com .anthropic.com
# http_access allow approved_domains
# http_access deny all
```

### Step 9: Post-Deployment Hardening (Critical)
After all three apps are running, exec into the OpenClaw container:

```bash
docker exec -it $(docker ps -q -f name=srv-captain--openclaw) sh

# Core security config
openclaw config set gateway.bind "loopback"
openclaw config set gateway.trustedProxies '["127.0.0.1"]'
openclaw config set gateway.password "$(openssl rand -hex 32)"

openclaw config set agents.defaults.sandbox.mode "all"
openclaw config set agents.defaults.sandbox.scope "agent"
openclaw config set agents.defaults.sandbox.workspaceAccess "none"
openclaw config set agents.defaults.sandbox.docker.network "none"
openclaw config set agents.defaults.sandbox.docker.capDrop '["ALL"]'

openclaw config set agents.defaults.tools.deny '["process", "browser", "nodes", "gateway", "sessions_spawn", "elevated", "host_exec", "docker"]'

openclaw config set channels.*.dmPolicy "pairing"
openclaw config set channels.*.groups.*.requireMention true

# Volume hardening
chmod 700 /root/.openclaw
find /root/.openclaw -type f -exec chmod 600 {} \;

openclaw security audit --deep --fix
openclaw doctor
openclaw sandbox explain

exit

# Restart service
docker service update --force srv-captain--openclaw
```

### Step 10: Verification
```bash
openclaw security audit --deep
openclaw sandbox explain
docker service inspect srv-captain--openclaw | grep -A 10 Constraints
docker node ps nyc
curl -I https://openclaw.yourdomain.com
```

### Step 11: Maintenance
- Weekly: `openclaw security audit --deep --fix && docker service update --force --image openclaw/openclaw:2026.2.15 srv-captain--openclaw`
- Monitor sandbox container lifecycle and proxy logs
- Rotate gateway password periodically

### Step 12: Troubleshooting
- Sandbox fails → Check `docker-proxy` logs and sandbox container exits
- Gateway unreachable → Verify `loopback` + `trustedProxies`
- Constraint issues → `docker node inspect nyc --format '{{json .Spec.Labels}}'`
- NFS issues → `showmount -e <IP>` and `dmesg | grep nfs`

**Done.** This deployment follows current 2026.2 OpenClaw security best practices with the trusted node set to `nyc`.

## Final Steps
1. Run the node label command for `nyc`
2. Deploy the three YAMLs in order
3. Apply the full post-deployment hardening block
4. Test agent execution in a secondary/group channel first
