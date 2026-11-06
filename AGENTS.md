# Working on Fuzzing Infrastructure

Instructions for coding agents (and a reminder for humans). Read this before changing anything.

## What this is

Reusable fuzzing infrastructure (harnesses, build scripts, campaign orchestration and crash triage) for my
personal fuzzing campaigns against public targets, starting with Valve's GameNetworkingSockets.

## Rules

- **Follow [docs/STYLE.md](docs/STYLE.md) for all code, scripts, comments, docs and commit messages.** The
  essentials: every file starts with a banner and an overview; every type, field and function has a comment
  explaining why, not just what; the logic inside functions is walked through in numbered steps (`1:`, `2:`),
  enough to follow a function from its comments alone; plain line comments only (no Doxygen or docstring
  scaffolding); names spelled out in full, folders and files included; and never an em dash.
- **Code that patches a target follows the target's style,** not ours.
- **Pin every version that affects results** (compilers, fuzzers, base images, the target's commit).
- **Never invent results.** No made-up numbers, crashes or coverage; leave a `todo:` instead.
- **Crashes stay private until they're fixed.** Reproducers and triage notes for unpatched bugs never go in a
  public repo, issue, commit message or writeup. See "Security rules" in docs/STYLE.md.
- **Each main folder has a short `README.md`.** When you add, move or rename something it lists, update it in the
  same change.
