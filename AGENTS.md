# Agent guide for `ignitetech-group/action-ecs-deploy`

Onboarding notes for AI coding agents (Cursor, Claude Code, Codex) and humans
working on this fork. Read this before opening a PR.

This is a **security-hardened fork** of
[`donaldpiret/ecs-deploy`](https://github.com/donaldpiret/ecs-deploy). The
fork's purpose, deviations from upstream, and pin-to-SHA install instructions
live at the top of [`README.md`](./README.md). This file covers the
engineering contract for changes.

---

## What this repo is

A GitHub Action that wraps the `ecs` CLI from
[`ignitetech-group/ecs-deploy`](https://github.com/ignitetech-group/ecs-deploy)
(our fork of `fabfuel/ecs-deploy`) for deploying, scaling, and updating ECS
services and tasks.

- **Wrapper**: `entrypoint.sh` — bash, no `eval`, builds an argv array.
- **Surface**: `action.yml` — input/output schema; identical semantics to
  upstream, with input validation moved into `entrypoint.sh`.
- **Image**: `Dockerfile` — multi-stage; stage 1 installs the Python CLI
  from the SHA-hashed lockfile, stage 2 is a slim runtime that drops to a
  non-root user.

We do **not** publish to GHCR or any registry. Consumers reference the
action by `uses: ignitetech-group/action-ecs-deploy@<40-char-SHA>`; the
GitHub Actions runner clones the action repo and `docker build`s it on
each invocation. The `Dockerfile` is the artifact contract.

---

## Fork invariants (don't regress these)

| # | Invariant |
|---|---|
| 1 | Build from source. `action.yml` says `image: 'Dockerfile'` (NOT `image: docker://...`). The fabfuel CLI is `pip install`-ed from a pinned commit SHA, not pulled from Docker Hub. |
| 2 | No `secrets: inherit` to third-party reusable workflows. |
| 3 | All `uses:` in `.github/workflows/*.yml` pinned to 40-character commit SHAs with a tag-comment on the line above. |
| 4 | Every workflow declares `permissions: contents: read` at the workflow level; widen only per-job, with rationale. |
| 5 | No deprecated CLIs and no shell-eval of user input anywhere. The most important thing in this repo: `entrypoint.sh` MUST NOT reintroduce `eval` against `INPUT_*` env vars. The upstream entrypoint had a textbook RCE there; we replaced it with an argv array + `exec "${cmd[@]}"`. |
| 6 | `CODEOWNERS` and `dependabot.yml` point at the fork's maintainers. |
| 7 | `README.md` documents the fork's deviation from upstream at the top. |

These invariants come from the
[`github-actions-fork`](https://github.com/ignitetech-group/action-pull-request)
skill (Phase 0 bootstrap). Every PR (including dependabot bumps) must
preserve them.

---

## Quality gates (always run before a PR)

| Layer | Tool | Command |
|---|---|---|
| Shell | `shellcheck` | `shellcheck -x -S style entrypoint.sh` |
| Dockerfile | `hadolint` | `hadolint Dockerfile` |
| Workflows | `actionlint` | `actionlint` |
| YAML | `yamllint` | `yamllint -c .yamllint.yml .github action.yml` |
| Image build | `docker build` | `docker build -t action-ecs-deploy:dev .` |
| Smoke | `docker run` | (see "Smoke tests" below) |

### Smoke tests (run after `docker build`)

```bash
# 1. Required-input rejection (must FAIL with non-zero exit)
docker run --rm action-ecs-deploy:dev && echo FAIL || echo OK

# 2. Unknown-action rejection (must FAIL)
docker run --rm \
  -e INPUT_ACTION=destroy \
  -e INPUT_CLUSTER=c -e INPUT_TARGET=t \
  action-ecs-deploy:dev && echo FAIL || echo OK

# 3. Shell-injection (regression test for invariant 5):
#    Should NOT create /tmp/PWNED inside the container.
docker run --rm \
  -e INPUT_ACTION=deploy \
  -e 'INPUT_CLUSTER=$(touch /tmp/PWNED)' \
  -e INPUT_TARGET=service \
  --entrypoint sh \
  action-ecs-deploy:dev \
  -c '/entrypoint.sh 2>/dev/null || true; [ -e /tmp/PWNED ] && echo FAIL || echo OK'

# 4. Non-root user verification
docker run --rm --entrypoint id action-ecs-deploy:dev | grep -q "uid=1001(app)" \
  && echo OK || echo FAIL

# 5. ecs CLI is reachable inside the image
docker run --rm --entrypoint ecs action-ecs-deploy:dev --version
```

All five should print `OK` (or for #5, `ecs-deploy, version 1.15.x`).

---

## Dependency management

### Lockfile

`requirements.in` (1 line: `ecs-deploy @ git+...@<SHA>`) drives
`requirements.txt` (the fully-pinned, hashed lockfile of all transitive
deps: `boto3`, `botocore`, `click`, etc.).

### Bumping the fabfuel pin

1. Audit upstream changes in `ignitetech-group/ecs-deploy` between the old
   pin SHA and the new one. Specifically check `ecs_deploy/cli.py` for
   any new flag or removed flag — `entrypoint.sh` constructs argv around
   these flags.
2. Update the SHA in `requirements.in`.
3. Re-compile the lockfile (with cooldown):

   ```bash
   # macOS
   CUTOFF="$(date -v-7d +%Y-%m-%d)"
   # Linux
   # CUTOFF="$(date -d '7 days ago' +%Y-%m-%d)"

   uv pip compile requirements.in \
     --python-version 3.13 \
     --generate-hashes \
     --exclude-newer "$CUTOFF" \
     --output-file requirements.txt
   ```

4. `docker build .` to verify the new lockfile resolves.
5. Run all 5 smoke tests above.
6. Open a PR with the SHA bump + lockfile diff in the same commit.

### CVE-driven cooldown bypass

If a critical CVE forces a `<7-day` upgrade of a transitive dep:

```bash
uv pip compile requirements.in \
  --python-version 3.13 \
  --generate-hashes \
  --exclude-newer "$CUTOFF" \
  --exclude-newer-package "<vulnerable-pkg>=$(date +%Y-%m-%d)" \
  --output-file requirements.txt
```

Document the bypass with a comment in `requirements.in` naming the CVE,
mirroring the
[gfi-mcp pattern](https://github.com/ignitetech-group/gfi-mcp/blob/main/requirements.in).

---

## Common pitfalls (what agents repeatedly get wrong)

- **DO NOT reintroduce `eval` in `entrypoint.sh`.** This is invariant 5,
  the most-important-thing-in-this-repo. The upstream entrypoint had a
  textbook shell-injection RCE because it built a command string from
  `$INPUT_*` env vars and ran `eval "$CMD"`. We replaced it with an argv
  array (`cmd=(ecs "$ACTION" ...)`) and `exec "${cmd[@]}"`. Refactor
  freely, but never go back to string-concatenation + `eval` / `sh -c`.
- **Don't bump `requirements.txt` manually.** Always re-run `uv pip
  compile`. A manually-edited lockfile diverges from `requirements.in`
  and silently breaks reproducibility.
- **Don't drop the `--generate-hashes` flag** when re-compiling the
  lockfile. Hashes are how `uv pip sync` rejects a tampered wheel.
- **Don't introduce `actions/checkout@v4` (or any unpinned action).** All
  `uses:` lines are SHA-pinned. Bumping is fine; unpinning is not.
- **Don't switch the Docker base image without re-running smoke tests.**
  In particular, `bash` and `xargs` are required by `entrypoint.sh` and
  must exist in the runtime image. `python:3.13-slim-trixie` ships both.
- **Don't reorder or delete `INPUT_*` reads in `entrypoint.sh` without
  checking `action.yml`.** The action's input contract is the action.yml;
  any name change cascades to the entrypoint.

---

## Reading order for new contributors

1. [`README.md`](./README.md) — fork notice + user-facing usage examples.
2. This file (you are here) — engineering contract.
3. [`action.yml`](./action.yml) — input/output schema (the public API).
4. [`entrypoint.sh`](./entrypoint.sh) — input validation + argv
   construction. Read it end-to-end at least once.
5. [`Dockerfile`](./Dockerfile) — multi-stage build, non-root runtime.
6. [`.github/workflows/ci.yml`](./.github/workflows/ci.yml) — lint +
   build + smoke gates.
