---
name: ansible-review
version: 1.0.0
description: |
  Production-grade Ansible code review. Checks FQCN, idempotency, security,
  handlers, check-mode safety, and testability against ansible-lint shared-profile
  and Red Hat/community 2026 best practices. Outputs verdict, ranked findings,
  and a merge recommendation. Do not use for non-Ansible code reviews,
  Terraform, or Docker-only projects.
  Can review either pasted code ($ARGUMENTS) or the current codebase.
allowed-tools:
  - Read
  - Grep
  - Glob
---

Review the Ansible repository content for production readiness. Apply ansible-lint production profile, official Ansible collection review checklist, and 2026 best practices from Red Hat + community (idempotency-first, security, FQCN, check-mode, Molecule).

**Mandatory checks (fail if missing):**
- FQCN for ALL modules/plugins (ansible.builtin., community.general., etc.)
- Idempotency (modules > shell/command; use `creates`/`removes`/`state` where needed)
- Security: ansible-vault for secrets, `no_log: true` on sensitive tasks, no hardcoded creds/IPs
- `become: true` explicitly on privileged tasks
- Descriptive task names, role-prefixed vars, proper variable precedence
- Handlers notified correctly, tags consistent
- Check-mode & `--diff` safe
- No destructive ops without safeguards
- Error handling & retries where critical
- Readability: DRY, modular (prefer roles/collections)

Review as a combination of:
1) ansible-playbook --syntax-check / loadability requirements,
2) ansible-lint shared-profile quality gates, plus applicable production-level FQCN rigor,
3) human review for correctness, idempotency, determinism, security, and testability.

Do not praise the code. Do not restate the code. Report concrete issues only.

Check for these categories:

A. Loadability / structure
- syntax/loadability problems
- missing collections/roles or missing requirements.yml entries
- repo/layout issues that would break linting or execution

B. Correct Ansible usage
- missing FQCNs for modules/plugins/roles
- use of shell where command is sufficient
- use of command/shell where a dedicated Ansible module should be used
- improper conditional syntax, especially {{ }} inside when/changed_when/failed_when/until
- invalid or poorly formatted Jinja
- become_user without become: true
- run_once risks, especially with strategy: free

C. Idempotency / determinism
- command/shell/raw tasks lacking changed_when / failed_when logic
- handlers with weak change detection
- state: latest or unpinned package installs
- VCS checkouts using floating refs such as HEAD / latest-like behavior
- tasks that are not safe in check mode / diff mode

D. Security
- secrets in plaintext that should be handled with Ansible Vault
- secrets that may be logged and need no_log: true, especially in loops
- risky file permissions
- unquoted octal modes
- shell pipelines or patterns that increase risk unnecessarily

E. Maintainability
- unclear task names
- variable naming issues
- duplicated logic
- unnecessary complexity
- places where a smaller fix is better than a rewrite

F. Validation / testing gaps
- missing ansible-lint coverage
- missing yamllint coverage
- missing ansible-playbook --syntax-check
- missing ansible-playbook --check --diff validation
- missing Molecule scenarios where role/playbook behavior should be tested

Output format:

1. Verdict
- PASS
- PASS WITH RISKS
- FAIL

2. Top issues first
List the 5 most important findings first, sorted by severity:
- blocker
- high
- medium
- low

3. For each finding, use this exact structure:
- Severity:
- File / path:
- Task / handler / section:
- Rule or principle violated:
- Evidence:
- Why it matters:
- Minimal fix:
- Corrected snippet or patch:

4. Then group the remaining findings under:
- Definite rule violations
- Likely bugs / idempotency risks
- Security risks
- Maintainability issues
- Missing validation / tests

5. Finish with:
- Merge recommendation: approve / request changes / block
- Exact verification commands to run locally

Constraints:
- Prefer minimal, root-cause fixes over rewrites.
- Do not invent files, vars, modules, or runtime context.
- If a claim cannot be proven from the provided code, say: "needs repo/runtime context".
- Separate definite rule violations from subjective suggestions.

Repository content starts below. If no content is provided via $ARGUMENTS, review the current codebase.

$ARGUMENTS
