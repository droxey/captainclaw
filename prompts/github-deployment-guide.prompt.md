---
name: github-deployment-guide
description: |
  Generate a complete GitHub deployment guide for an Ansible project.
  Covers CI/CD workflows, security, environments, containerization,
  GitOps, deployment strategies, observability, and optimization.
  Do not use for non-Ansible projects or Kubernetes-native deployments.
---

# GitHub Deployment Guide — Ansible Playbook (2026)

Generate a production-grade GitHub deployment guide for the provided Ansible project. Apply 2026 best practices for CI/CD, security, containerization, and observability using GitHub-native tools.

## Executive summary

By March 2026 the GitHub ecosystem has converged on five non-negotiable defaults for every production Ansible project:

1. **OIDC everywhere** — long-lived secrets in repository settings are gone. Every cloud action authenticates with short-lived OIDC tokens.
2. **Reusable workflows + composite actions** — `.github/workflows/` is itself a library. `ci.yml` calls `_lint.yml`, `_molecule.yml`, and `_deploy.yml` rather than duplicating steps.
3. **Environments with required reviewers** — `staging` auto-deploys; `production` gates on human approval. GitHub Environments replaced every home-grown approval gate.
4. **Dependency review + CodeQL in the merge queue** — nothing reaches `main` without a passing security scan.
5. **Molecule as the unit test for roles** — `molecule test` is the Ansible equivalent of `pytest`. If it doesn't have a Molecule scenario, it isn't production-ready.

---

## Procedure

### 1. Examine repository structure and branching strategy

Establish trunk-based development with short-lived feature branches:

```text
main          ← protected, requires PR + passing CI + 1 review
├── feature/  ← merged in < 2 days; triggers CI on push
├── fix/      ← hotfix; fast-path to main
└── release/  ← optional; tag-triggered deploys to production
```

**Branch protection rules for `main`:**
- Require a pull request before merging (1 required reviewer)
- Require status checks: `ci / lint`, `ci / molecule`, `security / codeql`
- Require branches to be up to date before merging
- Restrict who can push to matching branches
- Do not allow bypassing the above settings (including admins)

**Tag convention:** CalVer `v2026.3.7` matching OpenClaw's tagging scheme; release candidates use `v2026.3.7-rc.1`.

---

### 2. Generate CI/CD workflows

**Workflow file layout:**

```text
.github/
├── workflows/
│   ├── ci.yml                    ← orchestrator; calls reusable workflows
│   ├── deploy.yml                ← environment-gated deployment
│   ├── ee-build.yml              ← builds Ansible Execution Environment
│   ├── notify-deploy-failure.yml ← workflow_run failure alerts
│   ├── drift.yml                 ← cron drift detection
│   ├── security.yml              ← CodeQL + dependency review
│   ├── _lint.yml                 ← reusable: ansible-lint + yamllint
│   ├── _molecule.yml             ← reusable: Molecule test matrix
│   └── _syntax.yml               ← reusable: ansible-playbook --syntax-check
└── dependabot.yml                ← Actions SHA bumps + pip updates
```

**CI orchestrator (`ci.yml`):** Calls `_lint.yml`, `_syntax.yml`, and `_molecule.yml` as reusable workflows. Molecule runs after lint and syntax pass. Concurrency cancels in-flight runs on new pushes.
Read `references/ci-workflow.yml` for the complete workflow definition.

**Lint workflow (`_lint.yml`):** Runs ansible-lint (production profile) + yamllint. Uploads SARIF to the GitHub Security tab.
Read `references/lint-workflow.yml` for the complete workflow definition.

**Syntax check workflow (`_syntax.yml`):** Runs `ansible-playbook --syntax-check` against the staging inventory. Catches template errors before Molecule.
Read `references/syntax-workflow.yml` for the complete workflow definition.

**Molecule workflow (`_molecule.yml`):** Runs Molecule scenarios in a matrix. Caches pip and Galaxy collections.
Read `references/molecule-workflow.yml` for the complete workflow definition.

**Deploy workflow (`deploy.yml`):** Environment-gated deployment triggered by version tags. Staging auto-deploys; production requires manual approval. Uses OIDC for SSH certificates via Vault. Includes post-deploy health checks and Slack notifications.
Read `references/deploy-workflow.yml` for the complete workflow definition.

---

### 3. Configure security and compliance

**Security workflow (`security.yml`):** CodeQL + dependency-review on PRs and weekly schedule.
Read `references/security-workflow.yml` for the complete workflow definition.

**Dependabot (`dependabot.yml`):** Weekly PRs for GitHub Actions SHA bumps and pip updates. Galaxy collection bumps use Renovate Bot.
Read `references/dependabot-config.yml` for the complete config.

**OIDC trust policy:** Vault JWT auth role scoped to exact repo and environment.
Read `references/vault-oidc-policy.hcl` for the complete HCL definition.

**Least-privilege `GITHUB_TOKEN` permissions:**

```yaml
permissions:
  contents: read
  id-token: write
  pull-requests: write
```

**GitHub Environments setup:**

1. Go to **Settings → Environments → New environment**
2. Create `staging`: no required reviewers (auto-deploy on tag), deployment branch rule `v*`, add secrets (`ANSIBLE_VAULT_PASS`, `VAULT_ADDR`, `SLACK_WEBHOOK_URL`)
3. Create `production`: 1-2 required reviewers, optional 5-minute wait timer, deployment branch rule `v*`, separate secret values
4. The `environment: production` key in `deploy.yml` causes GitHub to pause for reviewer approval

---

### 4. Configure containerization (Execution Environments)

Ansible playbooks run on a controller node, not in containers. The containerization story is the **Ansible Execution Environment (EE)**.

**EE build workflow (`ee-build.yml`):** Builds and pushes the EE image to GHCR when `execution-environment.yml`, `requirements.yml`, or `requirements.txt` change.
Read `references/ee-build-workflow.yml` for the complete workflow definition.

**Registry options:**

| Registry | Best For | Notes |
| --- | --- | --- |
| GHCR (`ghcr.io`) | OSS projects, GitHub-native | Free for public; `GITHUB_TOKEN` auth |
| AWS ECR | AWS-deployed controllers | OIDC auth via `aws-actions/configure-aws-credentials` |
| Quay.io | Red Hat / AAP users | Native EE registry; robot accounts for CI |

---

### 5. Set up GitOps and drift detection

**Repository as single source of truth:**

```text
.
├── inventory/
│   ├── staging/
│   │   └── hosts.yml     ← staging targets (IPs in vault, not plaintext)
│   └── production/
│       └── hosts.yml     ← production targets
├── group_vars/
│   └── all/
│       ├── vars.yml      ← non-secret config
│       └── vault.yml     ← ansible-vault encrypted; committed to repo
└── playbook.yml
```

**GitOps flow:** Push to `main` → CI deploys to staging. Tag a release → deploy to production after approval. Drift detection runs `--check --diff` on a cron schedule.

**Renovate Bot:** Manages Galaxy collection, GitHub Actions, and pip version bumps.
Read `references/renovate-config.json` for the complete config.

**Drift detection (`drift.yml`):** Runs `ansible-playbook --check --diff` every 6 hours. Opens a GitHub issue on drift.
Read `references/drift-workflow.yml` for the complete workflow definition.

---

### 6. Define deployment strategies

For a single-server project, blue-green and canary apply at the Docker container level.

**Staging → Production promotion flow:**

```text
feature/* ──► PR to main ──► CI passes ──► merge to main
                                                │
                                          auto-deploy to staging
                                                │
                                     manual tag: git tag v2026.3.7
                                                │
                                          deploy.yml triggers
                                                │
                                    staging job runs (auto-approve)
                                                │
                                    production job waits for reviewer
                                                │
                                          reviewer approves
                                                │
                                          production deploy runs
```

Blue-green deployment pulls the new image, starts a green container, health-checks it, switches the Caddy upstream, verifies traffic, removes the old container, and renames green to the canonical name. Rollback restores the previous image version.

Canary rollout uses Caddy's weighted round-robin (90/10 split) to route traffic between stable and canary containers.

---

### 7. Instrument observability and monitoring

| Signal | Tool | Where |
| --- | --- | --- |
| Deploy duration | GitHub Actions built-in metrics | Actions → Insights |
| Deploy failure rate | `notify-deploy-failure.yml` (`workflow_run`) | Slack + GitHub Issues |
| Host health post-deploy | Health check step in `deploy.yml` | Actions logs |
| Ansible task failures | ansible-lint SARIF → GitHub Security tab | Security → Code scanning |
| Configuration drift | Drift detection cron (see §5) | GitHub Issues |
| Playbook execution traces | OpenTelemetry callback → Grafana Tempo | Grafana dashboard |

**Deploy failure notifications (`notify-deploy-failure.yml`):** Triggered when the Deploy workflow fails. Sends Slack notification without blocking the deploy pipeline.
Read `references/notify-failure-workflow.yml` for the complete workflow definition.

**OpenTelemetry:** Enable the `community.general.opentelemetry` callback in `ansible.cfg` to emit traces for every task. Wire to Grafana Agent → Tempo for flame graphs.

---

### 8. Optimize for cost, speed, and sustainability

**Speed:** Cache pip installs and Galaxy collections, use `cancel-in-progress: true`, run Molecule scenarios in parallel, consider a self-hosted runner co-located with the target server.

**Cost:** GitHub-hosted `ubuntu-24.04` runners cost ~$0.008/minute (~$0.05 per 6-minute CI run). Self-hosted runners on the VPS cost $0/run.

**Sustainability:** Use `concurrency: cancel-in-progress` to avoid burning minutes on abandoned work. Set `pre_build_image: true` in Molecule where possible.

---

### 9. Configure AI assistance (GitHub Copilot)

Copilot in 2026 autocompletes Ansible tasks, suggests FQCN module names, generates PR descriptions, and bootstraps workflow YAML from natural language.

**Custom Copilot Instructions:** Define project conventions for Copilot.
Read `references/copilot-instructions.md` for the complete instructions file.

---

### 10. Set up documentation and project tracking

**Issue templates:** Structured deploy failure reporting.
Read `assets/issue-template-deploy-failure.yml` for the complete template.

**PR template:** Test plan and security checklist for every PR.
Read `assets/pr-template.md` for the complete template.

**GitHub Projects:** Create columns `Backlog → In Progress → Staged → Released`. Automate: PR merged to `main` → `Staged`; tag pushed → `Released`.

---

## Comprehensive checklist

### Security

- [ ] All GitHub Actions pinned to commit SHA (not tag)
- [ ] `GITHUB_TOKEN` permissions set to minimum required per workflow
- [ ] OIDC used for all cloud/vault authentication — no long-lived secrets
- [ ] `ansible-vault` encrypts all secrets; `vault.yml.example` committed, `vault.yml` gitignored
- [ ] `no_log: true` on every task touching credentials or tokens
- [ ] Dependabot enabled for `github-actions` and `pip` ecosystems
- [ ] Renovate Bot configured for Galaxy collection version bumps
- [ ] CodeQL enabled on `main` and weekly schedule
- [ ] Branch protection: PR required, CI required, admin bypass disabled
- [ ] GitHub Environments: `production` requires 1 named reviewer
- [ ] Secret scanning enabled in repository settings
- [ ] `.gitignore` includes `vault.yml`, `*.key`, `*.pem`, `.env`

### Performance

- [ ] `concurrency: cancel-in-progress: true` in all CI workflows
- [ ] pip cache enabled via `actions/setup-python` `cache: pip`
- [ ] Galaxy collections cached on `hashFiles('requirements.yml')`
- [ ] Matrix strategy used for Molecule multi-scenario runs
- [ ] Self-hosted runner evaluated if deploy latency is a concern

### Reliability

- [ ] `fail-fast: false` in matrix jobs
- [ ] Molecule tests cover all roles
- [ ] `_syntax.yml` defined and referenced correctly from `ci.yml`
- [ ] Drift detection cron opens GitHub issue on non-idempotent state
- [ ] Post-deploy health check step in `deploy.yml`
- [ ] Rollback tasks defined
- [ ] `--diff` flag used in all deploy runs for auditability

---

## Common pitfalls and fixes

| Pitfall | Symptom | Fix |
| --- | --- | --- |
| Tag drift in Actions | Supply-chain compromise via mutable tags | Pin every `uses:` to commit SHA; use Dependabot to update SHAs |
| `ansible-vault` password in plaintext | Vault password visible in workflow logs | Use `--vault-password-file <(echo "$SECRET")` — process substitution keeps it out of argv |
| Molecule not testing idempotency | Role applies changes on every run | Run `converge` twice; assert no changes on second run |
| `become: true` at play level | Entire play runs as root | Move `become: true` to individual privileged tasks only |
| Missing `changed_when` on `command` tasks | Always reports changed; breaks idempotency | Add `changed_when: false` or parse stdout to detect actual change |
| Hardcoded inventory IPs | Real server IPs in git history | Use `ansible_host: "{{ server_ip }}"` in `hosts.yml`; set `server_ip` in vault |
| EE base image not pinned to digest | Silent upstream updates break reproducibility | Use `name: ghcr.io/ansible/community-ee-minimal@sha256:<digest>` |
| Production deploy without staging gate | Untested change goes to prod | `deploy-production` must `needs: deploy-staging` |
| Missing `_syntax.yml` definition | Workflow fails with "Could not find reusable workflow" | Define `_syntax.yml` (see §2) |
| Blue-green cutover without verify step | Broken green container serves traffic | Add health check before removing blue container |

---

## Recommended stack by project type

| Scenario | Controller | Secrets | Registry | Monitoring |
| --- | --- | --- | --- | --- |
| Single VPS (this project) | GitHub Actions + self-hosted runner on VPS | HashiCorp Vault (OIDC) | GHCR | Prometheus + Grafana |
| Multi-host bare metal | AWX / AAP 2.5 | Vault or CyberArk | Quay.io | ELK stack or Grafana Cloud |
| Cloud-native (AWS) | GitHub Actions (ubuntu-24.04) | AWS Secrets Manager (OIDC) | ECR | CloudWatch + Grafana |
| Air-gapped / on-prem | Gitea + Gitea Actions | HashiCorp Vault (offline) | Harbor | Prometheus + Alertmanager |

---

## Future-proofing tips

1. **Migrate to Ansible Execution Environments now** — AAP 2.5+ requires EEs; virtualenvs are deprecated.
2. **OpenTelemetry for Ansible** — the `community.general.opentelemetry` callback emits traces per task. Critical when playbooks grow past 200 tasks.
3. **Renovate Bot over Dependabot for Galaxy** — Dependabot does not natively update `requirements.yml` Galaxy collections as of March 2026.
4. **Merge queues** — enable GitHub Merge Queue once the team grows to eliminate "passing CI then merge broke main" incidents.
5. **GitHub Actions OIDC → Ansible Vault** — the OIDC → Vault pattern is the current best practice. Watch for AWS IAM Roles Anywhere and Azure Workload Identity as alternatives.
6. **Pin `ansible-core` in `requirements.txt`** — minor releases have broken backward compatibility. Pin to `==2.20.x` and bump deliberately.
