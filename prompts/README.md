# Reusable Prompts

Agent-agnostic prompt files that work with any AI coding assistant and in any repository. Each prompt uses YAML frontmatter for discoverability and follows progressive disclosure — bulky reference material and examples are extracted to `references/` and `assets/` directories, loaded on demand.

## Available Prompts

| Prompt | Description |
| --- | --- |
| [humanizer.prompt.md](humanizer.prompt.md) | Remove signs of AI-generated writing. Detects 24 AI patterns from Wikipedia's guide. |
| [ansible-review.prompt.md](ansible-review.prompt.md) | Production-grade Ansible code review against ansible-lint production profile and 2026 best practices. |
| [github-deployment-guide.prompt.md](github-deployment-guide.prompt.md) | Generate a complete GitHub deployment guide for an Ansible project. |
| [github-smallproject-virality.prompt.md](github-smallproject-virality.prompt.md) | Modernize a repo to match 2026 small-project virality patterns. |

## Directory Structure

```text
prompts/
├── *.prompt.md           ← portable prompt files (agent-agnostic)
├── references/           ← reference material loaded on demand (JiT)
│   ├── ai-writing-patterns.md    ← 24 AI writing patterns with before/after examples
│   ├── ci-workflow.yml           ← CI orchestrator workflow template
│   ├── lint-workflow.yml         ← ansible-lint + yamllint workflow
│   ├── syntax-workflow.yml       ← syntax-check workflow
│   ├── molecule-workflow.yml     ← Molecule test matrix workflow
│   ├── deploy-workflow.yml       ← environment-gated deployment workflow
│   ├── security-workflow.yml     ← CodeQL + dependency-review workflow
│   ├── drift-workflow.yml        ← cron drift detection workflow
│   ├── ee-build-workflow.yml     ← Execution Environment build workflow
│   ├── notify-failure-workflow.yml ← deploy failure notification workflow
│   ├── vault-oidc-policy.hcl     ← Vault OIDC trust policy
│   ├── renovate-config.json      ← Renovate Bot configuration
│   ├── dependabot-config.yml     ← Dependabot configuration
│   └── copilot-instructions.md   ← GitHub Copilot project instructions
└── assets/               ← examples and templates loaded on demand
    ├── humanizer-example.md      ← full worked example for the humanizer
    ├── pr-template.md            ← pull request template
    ├── issue-template-deploy-failure.yml ← deploy failure issue template
    └── GitHub_SmallProject_Trend_Adapter_Skill_2026.md ← generated skill output
```

## Using Across Repos

### Option 1 — Git Submodule (recommended for teams)

Add this repo as a submodule in any project:

```bash
git submodule add https://github.com/droxey/clincher.git .prompts
```

Prompts are then available at `.prompts/prompts/*.prompt.md` and stay in sync when you run `git submodule update --remote`.

### Option 2 — Copy Individual Files

Download a single prompt directly:

```bash
curl -O https://raw.githubusercontent.com/droxey/clincher/main/prompts/humanizer.prompt.md
```

Review the file contents before use — prompts influence code generation and should be treated like code.

### Option 3 — Reference via URL

Most agents accept a URL or pasted content. Use the raw GitHub URL:

```text
https://raw.githubusercontent.com/droxey/clincher/main/prompts/humanizer.prompt.md
```

## Using With Different Agents

### Claude Code

Claude Code discovers prompts in `.claude/commands/`. This repo ships those too — see [../.claude/commands/](../.claude/commands/). The `.prompt.md` files here are the agent-agnostic source; the Claude commands add Claude-specific metadata (allowed tools, version).

To use a portable prompt with Claude Code, paste the `.prompt.md` content into a chat or copy it to `.claude/commands/`:

```bash
cp prompts/humanizer.prompt.md .claude/commands/humanizer.md
```

### GitHub Copilot

Copilot reads instructions from `.github/copilot-instructions.md` or individual files referenced there. Copy a prompt into your repo:

```bash
mkdir -p .github
cp prompts/humanizer.prompt.md .github/copilot-instructions.md
```

Or reference multiple prompts by adding them to `.github/instructions/`:

```bash
mkdir -p .github/instructions
cp prompts/*.prompt.md .github/instructions/
```

### Cursor

Cursor reads project rules from `.cursor/rules/`. Copy prompts there:

```bash
mkdir -p .cursor/rules
cp prompts/humanizer.prompt.md .cursor/rules/humanizer.mdc
```

### ChatGPT / Generic LLMs

Copy-paste the prompt content into your conversation, or use a Custom GPT with the prompt as its system instructions.

### OpenClaw / Other Agent Frameworks

Reference prompts by raw URL in your agent's skill configuration, or include the file content in your system prompt.

## File Format

Each `.prompt.md` file includes optional YAML frontmatter with `name` and `description` fields for agent discoverability. Agents that do not parse frontmatter will ignore it. The format is:

```markdown
---
name: prompt-name
description: |
  What the prompt does. When to use it.
  When NOT to use it (negative triggers).
---

# Prompt Title

Task description and procedure.

## Sections

Instructions, checklists, references...
```

Prompts reference content in `references/` and `assets/` using relative paths (e.g., "Read `references/ai-writing-patterns.md` for the complete pattern catalog"). Placeholders like `{{ANSIBLE_CODE}}` indicate where to insert input.
