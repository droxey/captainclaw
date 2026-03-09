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
# GitHub Small-Project Virality Adapter

Analyze the target repository (or tech stack) and generate a trend-adapter skill file matching the style and star-velocity of small focused projects (<10k stars, single-purpose tools/libs/CLIs) that trended Dec 2025–Mar 2026.

## Process

1. **Tech detection.** Classify the repo: primary language + framework (e.g. Python+FastAPI, TypeScript+Next.js, Rust+Axum). If not provided, ask once.

2. **Live 2026 research (last 3 months only).** Search for:
   - Top 10 trending small focused repos (<10k stars) in this exact tech stack from Dec 2025–Mar 2026.
   - Patterns in READMEs, structure, one-command install, visuals/GIFs, minimal deps, AI polish, DX.

3. **Within-stack benchmark.** Compare only apples-to-apples (small projects only; ignore mega-repos).

4. **Output** the full skill file (start directly with `# GitHub 2026 Small-Project Trend Adapter Skill`).

## Required skill file structure

```text
# GitHub 2026 Small-Project Trend Adapter Skill

## Last-3-Months Star Drivers (small-project summary)
## Tech Stack Detector (one-shot classification prompt)
## Universal Transformation Checklist (max 12 high-impact steps)
## Tech-Specific Blueprints (TS/Next micro-tools, Python/AI agents, Rust/CLIs, etc.)
## Golden README Template (hero GIF/demo + one painful problem + one-command install + minimal badges + fast DX)
## Modern Repo Structure (flat & minimal + monorepo tips for small scope)
## .github/ Power Pack (lightweight Actions, issue templates, Dependabot, security)
## Virality Playbook (solve 1 problem perfectly, visuals, one-command, AI polish, star-growth levers)
## Agent Execution Protocol (step-by-step refactor script)
## Validation Rubric (1-10 small-project trend score + before/after checklist)
```

## Rules

- Concise, checklist + copy-paste templates only.
- Prioritize minimal changes with maximum star impact for small focused repos.
- Solve one painful problem perfectly, visual hero READMEs with GIFs/demos, one-command install, minimal deps, AI polish.
- Use real Dec 2025–Mar 2026 examples (Qwen-Agent style, Memori-style micro-tools, lightweight LLM wrappers).
- Output only the skill file.
