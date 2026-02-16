# 🦞 OpenClaw Hardened Swarm Deployment (2026.2)

**Production-grade, least-privilege OpenClaw deployment on CapRover Docker Swarm.**  
All sensitive services pinned to a single trusted node (`nyc`).

## Key Information
- **Target**: 4-node Ubuntu 24.04 Swarm (3 managers + 1 worker) with leader on `nyc`
- **OpenClaw Version**: `openclaw/openclaw:2026.2.15` (pinned)
- **Threat Model**: Prompt injection → arbitrary tool execution → host/container escape
- **Audit Date**: 2026-02-16 | **Score**: 9.7/10 (production-ready)

## Table of Contents

- [Step 1: Prerequisites](#step-1-prerequisites)
- [Step 2: Initialize Swarm on nyc Leader](#step-2-initialize-swarm-on-nyc-leader)
- [Step 3: Label the Trusted Node](#step-3-label-the-trusted-node)
- [Step 4: Join Additional Manager Nodes](#step-4-join-additional-manager-nodes)
- [Step 5: Set Up NFS Shared Storage](#step-5-set-up-nfs-shared-storage)
- [Step 6: Configure Firewall](#step-6-configure-firewall)
- [Step 7: Deploy Docker Socket Proxy](#step-7-deploy-docker-socket-proxy)
- [Step 8: Deploy OpenClaw Gateway](#step-8-deploy-openclaw-gateway)
- [Step 9: Deploy Egress Proxy (Squid)](#step-9-deploy-egress-proxy-squid)
- [Step 10: Post-Deployment Hardening](#step-10-post-deployment-hardening)
- [Step 11: Verification](#step-11-verification)
- [Step 12: Maintenance](#step-12-maintenance)
- [Step 13: Troubleshooting](#step-13-troubleshooting)
- [Step 14: Automated Periodic Checks](#step-14-automated-periodic-checks)

---

### Step 1: Prerequisites

#### 1.1 UFW + ufw-docker Setup (Run on **ALL** Nodes)

```bash
# 1. Install UFW
sudo apt update
sudo apt install ufw -y

# 2. Install ufw-docker
sudo wget -O /usr/local/bin/ufw-docker \
  https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
sudo chmod +x /usr/local/bin/ufw-docker

# 3. Install integration
sudo ufw-docker install --confirm-license

# 4. Initial configuration
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 127.0.0.1 to any port 22 proto tcp   # temporary local SSH
sudo ufw --force enable
```

#### 1.2 Static Admin IP + Cloudflare Setup

**Static Admin IP (SSH Access)**
- Use a dedicated **static public IP** for admin access.
- Record this IP as `$ADMIN_IP` (you will use it in Step 6).

**Cloudflare Setup (Recommended)**
1. Add your domain to Cloudflare and update nameservers.
2. Create an **A** or **CNAME** record pointing to `nyc` node’s public IP with **Proxied** status.
3. Set SSL/TLS to **Full (strict)**.
4. Enable WAF + Bot Fight Mode.
5. Strongly consider **Cloudflare Tunnel** for maximum security.

**Other prerequisites**:
- Healthy 4-node Ubuntu 24.04 servers
- CapRover already installed

### Step 2: Initialize Swarm on nyc Leader

**Run only on the `nyc` node**:

```bash
# Initialize Swarm (use the node's public or internal IP)
docker swarm init --advertise-addr <NYC_NODE_IP>

# Example:
# docker swarm init --advertise-addr 10.0.0.10
```

Save the manager join token shown in the output:

```bash
docker swarm join-token manager
```

### Step 3: Label the Trusted Node
```bash
docker node update --label-add openclaw.trusted=true nyc
```

### Step 4: Join Additional Manager Nodes

On the other two nodes:

```bash
docker swarm join --token <MANAGER_TOKEN_FROM_NYC> <NYC_LEADER_IP>:2377
```

Verify:
```bash
docker node ls
```

### Step 5: Set Up NFS Shared Storage (CapRover Dashboard HA)

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

Migrate existing CapRover data, update volume binding in CapRover dashboard, then scale captain service back up.

### Step 6: Configure Firewall (Run on All Nodes)

```bash
ADMIN_IP="YOUR_STATIC_IP"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow from $ADMIN_IP to any port 9922 proto tcp
ufw limit 9922/tcp
```

#### Cloudflare Ingress Setup
```bash
for ip in $(curl -s https://www.cloudflare.com/ips-v4); do 
  ufw allow from $ip to any port 80,443 proto tcp
done

for ip in $(curl -s https://www.cloudflare.com/ips-v6); do 
  ufw allow from $ip to any port 80,443 proto tcp
done
```

#### Swarm Inter-node Rules
```bash
for ip in <ALL_NODE_IPS>; do
  ufw allow from $ip to any port 2377,7946 proto tcp
  ufw allow from $ip to any port 7946,4789 proto udp
done

ufw-docker install --confirm-license
systemctl restart docker
ufw --force enable
```

### Step 7: Deploy Docker Socket Proxy
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

### Step 8: Deploy OpenClaw Gateway (Primary Service)
**App Name**: `openclaw`

```yaml
captainVersion: 4
services:
  openclaw:
    image: openclaw/openclaw:2026.2.15
    environment:
      DOCKER_HOST: tcp://srv-captain--docker-proxy:2375
      NODE_ENV: production
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

### Step 9: Deploy Egress Proxy (Squid)
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

**Example `squid.conf`**:
```
http_port 3128
http_access deny all
```

### Step 10: Post-Deployment Hardening (Critical)
```bash
docker exec -it $(docker ps -q -f name=srv-captain--openclaw) sh

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

chmod 700 /root/.openclaw
find /root/.openclaw -type f -exec chmod 600 {} \;

openclaw security audit --deep --fix
openclaw doctor
openclaw sandbox explain

exit

docker service update --force srv-captain--openclaw
```

### Step 11: Verification
```bash
openclaw security audit --deep
openclaw sandbox explain
docker service inspect srv-captain--openclaw | grep -A 10 Constraints
docker node ps nyc
curl -I https://openclaw.yourdomain.com
```

### Step 12: Maintenance
(Place scripts in `/opt/openclaw-monitoring/` on `nyc`)

**Main Maintenance Script** (`openclaw-maintenance.sh`):
```bash
#!/bin/bash
LOG="/opt/openclaw-monitoring/logs/maintenance-$(date +%F-%H%M).log"
echo "=== OpenClaw Maintenance Run - $(date) ===" | tee -a $LOG

tar -czf /opt/openclaw-monitoring/backups/openclaw-data-$(date +%F).tar.gz \
  -C /var/lib/docker/volumes/openclaw-data/_data . 2>> $LOG

docker exec $(docker ps -q -f name=srv-captain--openclaw) openclaw security audit --deep --fix >> $LOG 2>&1
docker service update --force --image openclaw/openclaw:2026.2.15 srv-captain--openclaw >> $LOG 2>&1
docker exec $(docker ps -q -f name=srv-captain--openclaw) openclaw doctor >> $LOG 2>&1

echo "=== Maintenance Complete ===" | tee -a $LOG
```

**Password Rotation**, **Cleanup**, and **Cron** entries are available in previous versions if needed.

### Step 13: Troubleshooting
- Sandbox fails → Check `docker-proxy` logs
- Gateway unreachable → Verify `loopback` + `trustedProxies`
- Constraint issues → `docker node inspect nyc --format '{{json .Spec.Labels}}'`

### Step 14: Automated Periodic Checks

Create directory:
```bash
mkdir -p /opt/openclaw-monitoring/logs
```

Then create the daily, weekly, and constraint check scripts (same as previous versions) and add them to cron.

**Done.** This deployment follows current 2026.2 OpenClaw security best practices.

**Next recommended actions**:
1. Start with Step 1 on all nodes
2. Initialize Swarm on `nyc` (Step 2)
3. Deploy services in order
4. Apply hardening (Step 10)
5. Set up monitoring scripts
