---
name: matlab-launcher-cli-submit-return
description: Use MatlabLauncher CLI (mlm) to run MATLAB jobs with submit-and-return semantics, replacing direct matlab -batch waits and avoiding long polling loops in Codex sessions.
---

# MatlabLauncher CLI Submit-and-Return

## Purpose

Use this skill when Codex needs to run MATLAB work through this project’s CLI (`mlm`) instead of directly calling `matlab -batch` and waiting in-session.

Primary goal: avoid long blocking waits and avoid continuous polling that wastes tokens/time.

## When to Use

- Runtime is uncertain or likely long (minutes to hours).
- Task is non-interactive and can run in background.
- User wants a job ID and may check progress later.

## Core Policy

1. Prefer `mlm submit` over direct `matlab -batch` for long/uncertain runs.
2. Use **submit-and-return** by default:
   - submit once,
   - return `jobId` immediately,
   - stop active waiting.
3. Do not run infinite/continuous polling loops (`while`, frequent `sleep + status`).
4. Only query status/logs when user explicitly asks for an update, or for one immediate sanity check right after submission.

## Preconditions

1. Ensure MatlabLauncher app/API is up:

```bash
mlm health
```

2. If `mlm` is not in `PATH`, use one of these:

```bash
~/bin/mlm health
```

```bash
/Applications/MatlabLauncher.app/Contents/Resources/mlm health
```

3. If API port is customized, set `MLM_PORT`:

```bash
MLM_PORT=52698 mlm health
```

## Submission Template

```bash
mlm submit \
  --name "<short-task-name>" \
  --command "<matlab statements; include init if needed>" \
  --project "/abs/path/to/matlab/project"
```

Optional flags:

```bash
--matlab "/Applications/MATLAB_R2025b.app/bin/matlab"
--tags "codex,experiment,longrun"
```

## Recommended Codex Flow

1. Run `mlm health`.
2. Submit job with `mlm submit ...`.
3. Parse and report at least:
   - `id` (jobId)
   - `name`
   - initial `status`
4. Tell user the run is detached and can be checked later.
5. End execution for now (no background polling loop in this session).

## On-Demand Follow-Up Commands

Only run these when user requests progress/results:

```bash
mlm status <job-id>
```

```bash
mlm log <job-id> --tail 100
```

```bash
mlm log <job-id> --stderr --tail 100
```

```bash
mlm result <job-id>
```

```bash
mlm cancel <job-id>
mlm kill <job-id>
```

```bash
mlm retry <job-id>
```

## Anti-Patterns

- Do not run `matlab -batch "..."` directly for long/uncertain jobs when `mlm` is available.
- Do not keep Codex session alive solely for waiting completion.
- Do not implement tight polling loops like:

```bash
while true; do mlm status <id>; sleep 5; done
```

## Failure Handling

- If `mlm health` fails: ask user to launch `MatlabLauncher.app` first.
- If submit returns non-201: capture and report error payload once; do not auto-retry in loops.
- If job becomes `stale`: report status and ask user whether to `retry` or `kill`.

## Minimal Prompt Template

Use MatlabLauncher CLI submit-and-return flow: verify `mlm health`, submit MATLAB job with `mlm submit`, report `jobId` immediately, and avoid continuous polling unless I explicitly ask for status/log checks.
