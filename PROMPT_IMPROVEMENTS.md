# Prompt & Skill Improvement Plan

Audit of every prompt and skill in this repository against the best practices from [mgechev/skills-best-practices](https://github.com/mgechev/skills-best-practices). That framework targets agent skills (SKILL.md files in dedicated directories), but its principles — progressive disclosure, procedural instructions, frontmatter for discoverability, and consistent terminology — apply equally to standalone prompts and Claude commands. Each section covers one file, lists the violations found, and provides a step-by-step implementation plan to fix them.

---

## Best Practices Summary (Reference)

The following principles from `mgechev/skills-best-practices` were used as the evaluation criteria:

| # | Principle | Key Rule |
|---|-----------|----------|
| 1 | **Directory structure** | `SKILL.md` + `scripts/` + `references/` + `assets/` — flat, one level deep |
| 2 | **Frontmatter** | `name` (1-64 chars, lowercase+hyphens, matches directory) and `description` (max 1024 chars, trigger-optimized with negative triggers) |
| 3 | **Progressive disclosure** | `SKILL.md` under 500 lines; offload bulky context to `references/` and `assets/` with JiT loading |
| 4 | **Procedural instructions** | Numbered steps, third-person imperative ("Extract the text…"), concrete templates in `assets/` |
| 5 | **Consistent terminology** | One term per concept; use domain-native vocabulary |
| 6 | **Deterministic scripts** | Offload fragile/repetitive parsing to tested scripts in `scripts/` |
| 7 | **No documentation cruft** | No README, CHANGELOG, or installation guides inside a skill |
| 8 | **Validation** | Test discovery, logic, edge cases, and architecture refinement with an LLM |

---

## File Inventory

> **Status:** The improvements recommended below were implemented in PRs #95-#97. Line counts, frontmatter, and directory structure reflect the post-implementation state. The per-file violation analysis (sections 1-10) is preserved as a historical audit trail — most violations listed have been resolved.

| File | Type | Lines (before) | Lines (after) | Location |
|------|------|------:|------:|----------|
| `humanizer.prompt.md` | Portable prompt | 469 | 101 | `prompts/` |
| `ansible-review.prompt.md` | Portable prompt | 121 | 122 | `prompts/` |
| `github-deployment-guide.prompt.md` | Portable prompt | 1207 | 311 | `prompts/` |
| `github-smallproject-virality.prompt.md` | Portable prompt | 45 | 48 | `prompts/` |
| `humanizer.md` | Claude command | 488 | 112 | `.claude/commands/` |
| `ansible-review.md` | Claude command | 133 | 125 | `.claude/commands/` |
| ~~`code-review-ansible.md`~~ | ~~Claude command~~ | ~~118~~ | — | Merged into `ansible-review.md` |
| `github-deployment-guide.md` | Claude command | 1207 | 318 | `.claude/commands/` |
| `github-smallproject-virality.md` | Claude command | 45 | 56 | `.claude/commands/` |
| `GitHub_SmallProject_Trend_Adapter_Skill_2026.md` | Generated skill output | 621 | 621 | `prompts/assets/` |

---

## 1. `prompts/humanizer.prompt.md` (469 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | Progressive disclosure | At 469 lines, the file is right at the 500-line limit. The 60-line full example (lines 399-462) and the 24 pattern sections with before/after samples inflate the context window. |
| 2 | Procedural instructions | The opening uses second-person ("You are a writing editor…", "Your Task"). Best practice is third-person imperative ("Scan the text for AI patterns…"). |
| 3 | Procedural instructions | Steps 1-6 in "Your Task" mix imperative and descriptive modes. Step 6 nests two sub-prompts inside a single bullet. |
| 4 | Progressive disclosure | Before/after examples for all 24 patterns are inline. These could live in `references/ai-writing-patterns.md` and be loaded JiT. |
| 5 | Consistent terminology | The file uses both "AI patterns" and "AI-isms" interchangeably. Pick one. |

### Implementation Plan

1. **Extract pattern catalog to a reference file.**
   - Create `prompts/references/ai-writing-patterns.md` containing sections 1-24 (the full pattern catalog with before/after examples, currently lines 52-398).
   - Replace the inline catalog in `humanizer.prompt.md` with a JiT loading instruction: "Read `references/ai-writing-patterns.md` for the complete pattern catalog with examples."
   - Keep only a summary checklist of the 24 pattern names in the main file for quick scanning.

2. **Extract full example to an asset file.**
   - Create `prompts/assets/humanizer-example.md` containing the full before/draft/audit/final example (currently lines 399-462).
   - Replace inline with: "See `assets/humanizer-example.md` for a complete worked example."

3. **Switch to third-person imperative.**
   - Change "You are a writing editor that identifies…" → "Identify and remove signs of AI-generated text…"
   - Change "Your Task" → "Procedure"
   - Rewrite steps: "Identify AI patterns" → "1. Scan the input text for patterns listed in `references/ai-writing-patterns.md`."

4. **Flatten nested sub-steps.**
   - Split step 6 (the anti-AI pass with two nested prompts) into two separate numbered steps (step 6 and step 7).

5. **Standardize terminology.**
   - Replace all instances of "AI-isms" with "AI patterns" throughout.

**Expected result:** Main file drops from 469 lines to ~80 lines. Pattern catalog and example are available on demand.

---

## 2. `prompts/ansible-review.prompt.md` (121 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | Procedural instructions | The role is stated twice: line 3 ("You are a senior Ansible engineer…") and line 19 ("You are a strict senior Ansible reviewer."). |
| 2 | Procedural instructions | Uses second-person framing ("You are…", "Your reviews…"). |
| 3 | Consistent terminology | The file says "Review the following Ansible code" (line 5) then "Review the pasted Ansible repo content" (line 21). Pick one. |
| 4 | Progressive disclosure | The output format template (lines 73-117) is detailed and works well inline, but the constraints block (lines 109-117) partially duplicates the category checklist. |

### Implementation Plan

1. **Remove the duplicate role statement.**
   - Delete lines 19-20 ("You are a strict senior Ansible reviewer." and the blank line). The role is already established on line 3.

2. **Switch to third-person imperative.**
   - Change "You are a senior Ansible engineer…" → "Act as a senior Ansible engineer…" or rephrase the opening as a direct instruction: "Review the provided Ansible code for production readiness. Apply ansible-lint production profile, FQCN rigor, and 2026 Red Hat/community best practices."

3. **Unify input terminology.**
   - Replace "Review the following Ansible code (playbook/role/tasks/vars/templates)." and "Review the pasted Ansible repo content…" with a single instruction: "Review the Ansible repository content provided below."

4. **Deduplicate constraints vs. categories.**
   - The constraints section (lines 109-117) repeats guidance already covered in categories A-F. Trim to only the constraints that add new information (e.g., "Do not invent files" and "needs repo/runtime context").

**Expected result:** File drops from 121 to ~100 lines. Cleaner, no redundancy.

---

## 3. `prompts/github-deployment-guide.prompt.md` (1207 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | **Progressive disclosure (critical)** | At 1207 lines, this file is ~2.4× the 500-line limit. It embeds complete YAML workflow files, HCL configs, Caddyfile snippets, and issue templates inline. |
| 2 | Progressive disclosure | Entire workflow definitions (`_lint.yml`, `_syntax.yml`, `_molecule.yml`, `deploy.yml`, `security.yml`, `drift.yml`, `ee-build.yml`, `notify-deploy-failure.yml`) are pasted in full — hundreds of lines of YAML. |
| 3 | Procedural instructions | The file is more of a reference document than a skill prompt. It reads like a deployment guide rather than agent instructions. |
| 4 | Procedural instructions | Uses second-person ("You are a Principal DevOps Engineer…"). |
| 5 | No documentation cruft | Contains a progress tracker (lines 7-30) that is a project management artifact, not an agent instruction. |
| 6 | Consistent terminology | Mixes "workflow" and "pipeline" in some contexts. |

### Implementation Plan

1. **Split into main prompt + reference files.**
   - Create `prompts/references/` directory (if not already present).
   - Move each embedded workflow YAML to its own reference file:
     - `prompts/references/ci-workflow.yml` — the `ci.yml` orchestrator
     - `prompts/references/lint-workflow.yml` — `_lint.yml`
     - `prompts/references/syntax-workflow.yml` — `_syntax.yml`
     - `prompts/references/molecule-workflow.yml` — `_molecule.yml`
     - `prompts/references/deploy-workflow.yml` — `deploy.yml`
     - `prompts/references/security-workflow.yml` — `security.yml`
     - `prompts/references/drift-workflow.yml` — `drift.yml`
     - `prompts/references/ee-build-workflow.yml` — `ee-build.yml`
     - `prompts/references/notify-failure-workflow.yml` — `notify-deploy-failure.yml`
   - Move non-YAML configs similarly:
     - `prompts/references/vault-oidc-policy.hcl`
     - `prompts/references/renovate-config.json`
     - `prompts/references/dependabot-config.yml`
     - `prompts/references/copilot-instructions.md`
     - `prompts/assets/pr-template.md`
     - `prompts/assets/issue-template-deploy-failure.yml`

2. **Replace inline blocks with JiT instructions.**
   - For each extracted file, replace the inline code block with: "Read `references/deploy-workflow.yml` for the complete workflow definition."
   - Keep a 2-3 line summary of what each workflow does before the JiT instruction.

3. **Remove the progress tracker.**
   - Delete lines 7-30 (Phase 1-4 tracker). This is a project artifact that does not belong in agent instructions.

4. **Restructure as procedural steps.**
   - Convert the current section-based layout (§1-§10) into a numbered procedure:
     1. "Examine the repository structure and identify the branching strategy."
     2. "Generate CI/CD workflows. Read `references/ci-workflow.yml` for the orchestrator template."
     3. Continue for each section.

5. **Switch to third-person imperative.**
   - Change "You are a Principal DevOps Engineer…" → "Generate a production-grade GitHub deployment guide for the provided Ansible project."

**Expected result:** Main file drops from 1207 lines to ~200-250 lines. All workflow templates are loadable on demand.

---

## 4. `prompts/github-smallproject-virality.prompt.md` (45 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | Procedural instructions | Uses second-person framing: "You are GitHub's Principal Engineer…", "Your sole job…" |
| 2 | Consistent terminology | "skill file" and "Markdown skill file" are used inconsistently — settle on one. |

### Implementation Plan

1. **Switch to third-person imperative.**
   - Change "You are GitHub's Principal Engineer…" → "Act as a GitHub small-project virality specialist." or rephrase as direct instruction: "Analyze the target repository and generate a trend-adapter skill file."

2. **Standardize terminology.**
   - Use "skill file" consistently throughout (drop "Markdown skill file").

**Expected result:** Minor wording changes. File stays at ~45 lines. Already well-structured.

---

## 5. `.claude/commands/humanizer.md` (488 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | Frontmatter | Has frontmatter with `name`, `version`, `description`, and `allowed-tools`. The description is good but lacks **negative triggers** (when NOT to use this skill). |
| 2 | Progressive disclosure | Same 469 lines of content as `humanizer.prompt.md`, plus 19 lines of frontmatter. Same inline pattern catalog and full example. |
| 3 | Procedural instructions | Same second-person framing issues as the portable version. |

### Implementation Plan

1. **Add negative triggers to the description.**
   - Append to the description: "Do not use for technical documentation, API references, or code comments where neutral tone is expected."

2. **Apply the same progressive disclosure changes as the portable version.**
   - After extracting pattern catalog and example to `prompts/references/` and `prompts/assets/`, update this file to reference those paths or inline the trimmed version.
   - Since Claude commands cannot reference external files the same way, keep a condensed pattern checklist (names only, no examples) and the procedure steps inline.

3. **Switch to third-person imperative** (same changes as the portable version).

**Expected result:** File drops from 488 lines to ~100 lines.

---

## 6. `.claude/commands/ansible-review.md` (133 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | Frontmatter | Has frontmatter. Description is good and specific. Lacks negative triggers. |
| 2 | Procedural instructions | Duplicate role statement (same as portable version). |
| 3 | Procedural instructions | Second-person framing. |

### Implementation Plan

1. **Add negative triggers to the description.**
   - Append: "Do not use for non-Ansible code reviews, Terraform, or Docker-only projects."

2. **Apply the same deduplication and framing fixes** described for `prompts/ansible-review.prompt.md`.

3. **Keep the `$ARGUMENTS` input variable** — this is correct Claude command syntax.

**Expected result:** File drops from 133 to ~110 lines.

---

## 7. `.claude/commands/code-review-ansible.md` (118 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | **Frontmatter (critical)** | Missing entirely. No `name`, `description`, `version`, or `allowed-tools`. While Claude discovers commands by filename (so the command still works), frontmatter improves description-based routing and is required by the best practices framework. |
| 2 | **DRY / redundancy (critical)** | Content is nearly identical to `ansible-review.md` (lines 1-116 match lines 15-131 of `ansible-review.md`). Only the input source differs ("this codebase" vs. `$ARGUMENTS`). |
| 3 | Procedural instructions | Same duplicate role statement and second-person framing. |

### Implementation Plan

1. **Decide: merge or differentiate.**
   - **Option A (recommended): Merge into `ansible-review.md`.** Add a note in the frontmatter description that the skill can review either pasted code or the current codebase. Change the input instruction to: "Review the Ansible repository content below. If no content is provided, review the current codebase." Delete `code-review-ansible.md`.
   - **Option B: Keep both, differentiate clearly.** Add frontmatter to `code-review-ansible.md` with a distinct name and description:
     ```yaml
     ---
     name: code-review-ansible-codebase
     version: 1.0.0
     description: |
       Review the current codebase's Ansible code for production readiness.
       Use when reviewing the repo you are currently working in, not pasted code.
       Do not use for non-Ansible repos or pasted code snippets.
     allowed-tools:
       - Read
       - Grep
       - Glob
     ---
     ```

2. **If keeping both, extract shared content.**
   - Move the shared checklist (categories A-F, output format, constraints) to a shared reference file and include it from both commands.

**Expected result:** Either one file deleted (Option A) or both files get distinct frontmatter and reduced duplication.

---

## 8. `.claude/commands/github-deployment-guide.md` (1207 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | **Frontmatter (critical)** | Missing entirely. |
| 2 | **Progressive disclosure (critical)** | Same 1207-line problem as the portable version. |
| 3 | Procedural instructions | Second-person framing. |

### Implementation Plan

1. **Add frontmatter.**
   ```yaml
   ---
   name: github-deployment-guide
   version: 1.0.0
   description: |
     Generate a complete GitHub deployment guide for an Ansible project.
     Covers CI/CD workflows, security, environments, containerization,
     GitOps, deployment strategies, observability, and optimization.
     Use when setting up or auditing GitHub Actions pipelines for Ansible.
     Do not use for non-Ansible projects or Kubernetes-native deployments.
   allowed-tools:
     - Read
     - Write
     - Edit
     - Grep
     - Glob
   ---
   ```

2. **Apply the same progressive disclosure refactoring** described for `prompts/github-deployment-guide.prompt.md` — extract workflow YAMLs and config blocks to reference files.

3. **Remove the progress tracker** (lines 7-30).

4. **Switch to third-person imperative.**

**Expected result:** File drops from 1207 to ~250 lines with frontmatter.

---

## 9. `.claude/commands/github-smallproject-virality.md` (45 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | **Frontmatter (critical)** | Missing entirely. |
| 2 | Procedural instructions | Second-person framing. |

### Implementation Plan

1. **Add frontmatter.**
   ```yaml
   ---
   name: github-smallproject-virality
   version: 1.0.0
   description: |
     Modernize a GitHub repo to match 2026 small-project virality patterns.
     Generates a trend-adapter skill file based on Dec 2025-Mar 2026 trending
     repos. Use when optimizing a small focused project for GitHub star growth.
     Do not use for large enterprise repos, monorepos, or non-GitHub platforms.
   allowed-tools:
     - Read
     - Write
     - Edit
     - Grep
     - Glob
     - WebSearch
   ---
   ```

2. **Switch to third-person imperative** (same as portable version).

**Expected result:** File grows by ~15 lines of frontmatter. Content stays concise.

---

## 10. `GitHub_SmallProject_Trend_Adapter_Skill_2026.md` (621 lines)

### Violations

| # | Principle Violated | Detail |
|---|-------------------|--------|
| 1 | **Directory structure** | Lives at the repo root instead of in a proper skill directory (`github-smallproject-virality/SKILL.md`). |
| 2 | **Progressive disclosure** | At 621 lines, exceeds the 500-line limit. The trending repos table, tech-specific blueprints, and README template sections are bulky. |
| 3 | **No documentation cruft** | This file is an output artifact, not a reusable skill. It should either be restructured as a proper skill or moved to a non-skill location. |

### Implementation Plan

1. **Decide: skill or output artifact.**
   - **Option A (recommended): Treat as output.** Move to `docs/GitHub_SmallProject_Trend_Adapter_Skill_2026.md` or `assets/`. It was generated by the virality prompt and is not itself a skill that agents load.
   - **Option B: Restructure as a proper skill.** Create `skills/github-smallproject-virality/SKILL.md` with the core procedure, and move bulky sections to `skills/github-smallproject-virality/references/`:
     - `references/trending-repos-2026.md` — the star drivers table
     - `references/tech-blueprints.md` — tech-specific blueprints
     - `assets/readme-template.md` — the golden README template
     - `assets/github-power-pack.md` — the .github/ templates

2. **If keeping as a skill, trim to <500 lines.**
   - The main `SKILL.md` should contain only the Universal Transformation Checklist, Agent Execution Protocol, and Validation Rubric — the actionable parts.
   - Move reference material (trending data, blueprints) to `references/`.

**Expected result:** Either relocated as an output artifact, or restructured into a proper skill directory under 500 lines.

---

## Cross-Cutting Issues

> **Status:** Issues A-C below have been resolved. Issue D remains open.

### A. ~~Portable prompts lack discoverability metadata~~ (Resolved)

All four `.prompt.md` files now have YAML frontmatter with `name` and `description` fields, including negative triggers. Implemented in PR #96.

### B. ~~Second-person framing is universal~~ (Resolved)

Prompts were rewritten to use third-person imperative framing. Implemented in PRs #95-#96.

### C. ~~No `references/` or `assets/` directories exist~~ (Resolved)

Both directories now exist and are populated:
- `prompts/references/` — 14 files (workflow YAMLs, HCL, JSON, markdown)
- `prompts/assets/` — 4 files (templates, examples, generated output)

Implemented in PRs #95-#96.

### D. No validation has been performed

None of the prompts have been tested through the recommended validation pipeline (Discovery → Logic → Edge Case → Architecture Refinement).

**Recommendation:** Run each prompt through the four-step validation process documented in `mgechev/skills-best-practices`:

1. **Discovery validation** — paste frontmatter into an LLM and check trigger accuracy
2. **Logic validation** — simulate step-by-step execution and flag ambiguities
3. **Edge case testing** — have the LLM attack the skill for gaps
4. **Architecture refinement** — enforce progressive disclosure and error handling

---

## Implementation Priority

> **Status:** All priorities below have been completed except P3 (validation pipeline).

| Priority | File | Status |
|----------|------|--------|
| **P0** | `github-deployment-guide.prompt.md` + `.claude/commands/github-deployment-guide.md` | Done (PR #96) |
| **P0** | `.claude/commands/code-review-ansible.md` | Done — merged into `ansible-review.md` (PR #96) |
| **P1** | `humanizer.prompt.md` + `.claude/commands/humanizer.md` | Done (PR #96) |
| **P1** | `.claude/commands/github-smallproject-virality.md` | Done — frontmatter added (PR #96) |
| **P1** | `.claude/commands/github-deployment-guide.md` | Done — frontmatter added (PR #96) |
| **P2** | `ansible-review.prompt.md` + `.claude/commands/ansible-review.md` | Done (PR #96) |
| **P2** | `github-smallproject-virality.prompt.md` | Done (PR #96) |
| **P2** | `GitHub_SmallProject_Trend_Adapter_Skill_2026.md` | Done — moved to `prompts/assets/` (PR #96) |
| **P3** | All files — second-person → third-person | Done (PR #96) |
| **P3** | All files — add negative triggers | Done (PR #96) |
| **P3** | All prompts — run validation pipeline | **Open** |

---

## Line Count Impact (Actual)

| File | Before | After | Reduction |
|------|-------:|------:|----------:|
| `humanizer.prompt.md` | 469 | 101 | -78% |
| `ansible-review.prompt.md` | 121 | 122 | -1% |
| `github-deployment-guide.prompt.md` | 1207 | 311 | -74% |
| `github-smallproject-virality.prompt.md` | 45 | 48 | +7% |
| `.claude/commands/humanizer.md` | 488 | 112 | -77% |
| `.claude/commands/ansible-review.md` | 133 | 125 | -6% |
| `.claude/commands/code-review-ansible.md` | 118 | — | Merged |
| `.claude/commands/github-deployment-guide.md` | 1207 | 318 | -74% |
| `.claude/commands/github-smallproject-virality.md` | 45 | 56 | +24% |
| **Total** | **3833** | **1193** | **-69%** |

Content extracted to `prompts/references/` (14 files) and `prompts/assets/` (4 files), loadable on demand via JiT instructions.
