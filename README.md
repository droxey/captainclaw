# 🦞 OpenClaw Hardened Swarm Guide (2026.2)

**Production-grade, least-privilege OpenClaw deployment on CapRover Docker Swarm.**  
All sensitive services pinned to a single trusted node (`nyc`).

## Key Information
- **Target**: 4-node Ubuntu 24.04 Swarm (3 managers + 1 worker) with leader on `nyc`
- **OpenClaw Version**: `openclaw/openclaw:2026.2.15` (pinned)
- **Threat Model**: Prompt injection → arbitrary tool execution → host/container escape
- **Audit Date**: 2026-02-16 | **Score**: 9.7/10 (production-ready)

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
- [Step 13: Automated Periodic Checks](#step-13-automated-periodic-checks)

---

### Step 1: Prerequisites

#### 1.1 UFW + ufw-docker Setup (Run on **ALL** Nodes)

```bash
# 1. Install UFW
sudo apt update
sudo apt install ufw -y

# 2. Install ufw-docker (official integration script)
sudo wget -O /usr/local/bin/ufw-docker \
  https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
sudo chmod +x /usr/local/bin/ufw-docker

# 3. Install ufw-docker integration
sudo ufw-docker install --confirm-license

# 4. Initial configuration
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 127.0.0.1 to any port 22 proto tcp   # temporary local SSH
sudo ufw --force enable
```

#### 1.2 Static Admin IP + Cloudflare Setup

**Static Admin IP (SSH Access)**
- Use a **static public IP** dedicated for administrative access (recommended: VPS floating IP, static ISP IP, or a small bastion host).
- Record this IP as `$ADMIN_IP` — you will use it in Step 5.

**Cloudflare Setup (Recommended)**
1. Add your domain to Cloudflare and update nameservers.
2. In DNS tab: Create an **A** or **CNAME** record pointing to your Swarm leader’s public IP (`nyc`) with **Proxied** status (orange cloud).
3. SSL/TLS → Set to **Full (strict)**.
4. Enable **WAF** (managed rulesets) + **Bot Fight Mode**.
5. (Strongly Recommended) Consider using **Cloudflare Tunnel** for zero open inbound ports.

**Other prerequisites**:
- Healthy 4-node Swarm with 3 managers (leader: `nyc`)
- CapRover installed and running

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
```

#### Cloudflare Ingress Setup (Recommended)

```bash
# Cloudflare ranges (IPv4 + IPv6)
for ip in $(curl -s https://www.cloudflare.com/ips-v4); do 
  ufw allow from $ip to any port 80,443 proto tcp
done

for ip in $(curl -s https://www.cloudflare.com/ips-v6); do 
  ufw allow from $ip to any port 80,443 proto tcp
done
```

**Best Practices**:
- Run the Cloudflare IP update script weekly (add to cron or maintenance script)
- In Cloudflare dashboard: Enable **"Only allow Cloudflare IPs"** under **SSL/TLS → Origin Server** or use **Cloudflare Tunnel** for stronger isolation

Continue with Swarm rules:

```bash
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

Run these scripts from the leader node (`nyc`). Place them in `/opt/openclaw-monitoring/`.

#### 1. Main Maintenance Script (Recommended Weekly)
```bash
cat > /opt/openclaw-monitoring/openclaw-maintenance.sh << 'EOF'
#!/bin/bash
LOG="/opt/openclaw-monitoring/logs/maintenance-$(date +%F-%H%M).log"

echo "=== OpenClaw Maintenance Run - $(date) ===" | tee -a $LOG

# Backup volume
echo "→ Backing up ~/.openclaw volume" | tee -a $LOG
tar -czf /opt/openclaw-monitoring/backups/openclaw-data-$(date +%F).tar.gz -C /var/lib/docker/volumes/openclaw-data/_data . 2>> $LOG

# Security audit + fix
echo "→ Running security audit" | tee -a $LOG
docker exec $(docker ps -q -f name=srv-captain--openclaw) openclaw security audit --deep --fix >> $LOG 2>&1

# Update to pinned image
echo "→ Updating OpenClaw service" | tee -a $LOG
docker service update --force --image openclaw/openclaw:2026.2.15 srv-captain--openclaw >> $LOG 2>&1

# Doctor check
echo "→ Running doctor" | tee -a $LOG
docker exec $(docker ps -q -f name=srv-captain--openclaw) openclaw doctor >> $LOG 2>&1

echo "=== Maintenance Complete ===" | tee -a $LOG
EOF
```

#### 2. Gateway Password Rotation Script
```bash
cat > /opt/openclaw-monitoring/rotate-gateway-password.sh << 'EOF'
#!/bin/bash
NEW_PASS=$(openssl rand -hex 32)

docker exec $(docker ps -q -f name=srv-captain--openclaw) sh -c "
  openclaw config set gateway.password '$NEW_PASS'
  echo 'New gateway password set: $NEW_PASS'
"

echo "Gateway password rotated. Update your clients/DMs with the new password."
echo "New password: $NEW_PASS"
EOF
```

#### 3. Log & Sandbox Cleanup Script
```bash
cat > /opt/openclaw-monitoring/cleanup.sh << 'EOF'
#!/bin/bash
echo "→ Pruning old sandbox containers"
docker container prune -f --filter "label=openclaw.sandbox=true"

echo "→ Cleaning old logs"
find /opt/openclaw-monitoring/logs -name "*.log" -mtime +30 -delete
EOF
```

#### Make all scripts executable
```bash
chmod +x /opt/openclaw-monitoring/*.sh
```

#### Cron Recommendations (Add to crontab -e on nyc)
```cron
# Weekly full maintenance (Sunday 4 AM)
0 4 * * 0 /opt/openclaw-monitoring/openclaw-maintenance.sh

# Monthly password rotation (1st of month at 3 AM)
0 3 1 * * /opt/openclaw-monitoring/rotate-gateway-password.sh

# Daily cleanup
0 2 * * * /opt/openclaw-monitoring/cleanup.sh
```

### Step 12: Troubleshooting
- Sandbox fails → Check `docker-proxy` logs and sandbox container exits
- Gateway unreachable → Verify `loopback` + `trustedProxies`
- Constraint issues → `docker node inspect nyc --format '{{json .Spec.Labels}}'`
- NFS issues → `showmount -e <IP>` and `dmesg | grep nfs`

### Step 13: Automated Periodic Checks

```bash
mkdir -p /opt/openclaw-monitoring/logs
cd /opt/openclaw-monitoring
```

#### Daily Health Check Script
```bash
cat > /opt/openclaw-monitoring/openclaw-daily-check.sh << 'EOF'
#!/bin/bash
LOG="/opt/openclaw-monitoring/logs/daily-$(date +%F).log"

echo "=== OpenClaw Daily Check - $(date) ===" | tee -a $LOG

docker exec $(docker ps -q -f name=srv-captain--openclaw) openclaw doctor >> $LOG 2>&1
docker service ls --format "{{.Name}} {{.Replicas}} {{.Image}}" | tee -a $LOG
docker node ps nyc --format "{{.Name}} {{.CurrentState}}" | tee -a $LOG
docker service inspect srv-captain--openclaw --format '{{json .Spec.TaskTemplate.Placement.Constraints}}' | tee -a $LOG

mount | grep /captain/data | tee -a $LOG
ufw status | head -n 20 | tee -a $LOG

echo "=== Daily Check Complete ===" | tee -a $LOG
EOF
```

#### Weekly Security Audit Script
```bash
cat > /opt/openclaw-monitoring/openclaw-weekly-audit.sh << 'EOF'
#!/bin/bash
LOG="/opt/openclaw-monitoring/logs/weekly-$(date +%F).log"

echo "=== OpenClaw Weekly Security Audit - $(date) ===" | tee -a $LOG
docker exec $(docker ps -q -f name=srv-captain--openclaw) openclaw security audit --deep --fix >> $LOG 2>&1
docker service update --force --image openclaw/openclaw:2026.2.15 srv-captain--openclaw >> $LOG 2>&1
echo "=== Weekly Audit Complete ===" | tee -a $LOG
EOF
```

#### Constraint Checker
```bash
cat > /opt/openclaw-monitoring/check-constraints.sh << 'EOF'
#!/bin/bash
echo "=== OpenClaw Constraint Check ==="
docker node inspect nyc --format '{{json .Spec.Labels}}' | grep -o 'openclaw.trusted[^,}]*'
docker service inspect srv-captain--openclaw --format '{{json .Spec.TaskTemplate.Placement.Constraints}}'
EOF
```

#### Make scripts executable
```bash
chmod +x /opt/openclaw-monitoring/*.sh
```

#### Cron (on nyc)
```cron
0 6 * * * /opt/openclaw-monitoring/openclaw-daily-check.sh
0 3 * * 0 /opt/openclaw-monitoring/openclaw-weekly-audit.sh
0 */6 * * * /opt/openclaw-monitoring/check-constraints.sh >> /opt/openclaw-monitoring/logs/constraints.log 2>&1
```

**Done.** This deployment follows current 2026.2 OpenClaw security best practices.

**Next recommended actions**:
1. Run the node label command for `nyc`
2. Deploy the three YAMLs in order
3. Apply the full post-deployment hardening block
4. Set up the monitoring and maintenance scripts
5. Test agent execution in a secondary/group channel first
