# action-ecs-deploy

> **Note:** This is a security-hardened fork of
> [`donaldpiret/ecs-deploy`](https://github.com/donaldpiret/ecs-deploy)
> maintained by `ignitetech-group`. It is the **GitHub Action wrapper** around
> the `ecs` CLI from
> [`ignitetech-group/ecs-deploy`](https://github.com/ignitetech-group/ecs-deploy)
> (which is in turn our fork of
> [`fabfuel/ecs-deploy`](https://github.com/fabfuel/ecs-deploy)).

A GitHub Action for deploying, scaling, updating, and running ECS services and
tasks via the `ecs` CLI.

## Why this fork

The upstream `donaldpiret/ecs-deploy` action has not been updated since 2023
and ships several security and correctness issues we don't want in our supply
chain. This fork addresses them at Phase 0 bootstrap:

| Upstream issue | Severity | Fix in this fork |
|---|---|---|
| `Dockerfile` does `FROM fabfuel/ecs-deploy:1.11.3` — pulls a Docker Hub image at consumer runtime, with no provenance over what's inside | high | Multi-stage `Dockerfile` that does `pip install git+https://github.com/ignitetech-group/ecs-deploy@<pinned-SHA>` against our fork of `fabfuel/ecs-deploy`. No Docker Hub pulls. |
| `entrypoint.sh` builds a single command string from unsanitized `INPUT_*` env vars and runs it through `eval` (textbook shell-injection RCE) | **critical** | `entrypoint.sh` rewritten to construct an argv array; final invocation is `exec "${cmd[@]}"` with no shell reparse. Inputs validated against whitelists (`action`, `launch_type`) and integer regexes (`timeout`, `scale_value`). |
| `set -e o pipefail` typo (`pipefail` was silently never enabled) | low | Now `set -Eeuo pipefail` with an `ERR` trap that reports the failing line. |
| `INPUT_public_ip` checked in lowercase — never matched, since GitHub uppercases input env vars | low | Now reads `INPUT_PUBLIC_IP` (correct) while still honouring the lowercase form for backwards-compatibility. |
| Bundled JS autorelease tooling (`yarn.lock`, `package.json`, `commitlint.config.js`, `.autorc`, `.all-contributorsrc`, `Makefile`) | n/a | Removed. We don't run that pipeline. |
| `release.yml` workflow used a separately-stored `secrets.GH_TOKEN` PAT to push to protected branches via `auto shipit` | medium | Workflow removed — we cut releases by tagging a SHA. |
| `codeql-analysis.yml` scanned the JS tooling (and used moving-ref actions `@v1`/`@v2`) | low | Workflow removed (no JS in this fork to scan). Action source is shell + Dockerfile, covered by `shellcheck`/`hadolint`/`actionlint` in `ci.yml`. |
| Dependabot was off | low | Enabled for `github-actions` + `docker`. |

## Usage

### Pinning

Per invariant 3 of our [`github-actions-fork`](https://github.com/ignitetech-group/action-pull-request)
skill, **production callers should pin to a 40-character commit SHA**, not to
`@main` or `@v1`. Find the latest SHA at
<https://github.com/ignitetech-group/action-ecs-deploy/commits/main>:

```yaml
- uses: ignitetech-group/action-ecs-deploy@<40-char-SHA>  # <tag-or-date>
  with:
    cluster: my-cluster
    target: my-service
```

The examples below use `@main` for readability — replace before shipping.

### Deployment

#### Simple redeploy

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
```

#### Deploy a new tag

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    tag: 1.2.3
```

#### Deploy a new image

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    image: webserver nginx:1.11.8
```

#### Deploy several new images

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    image: webserver nginx:1.11.8, application my-app:1.2.3
```

#### Deploy a custom task definition

With a fully-qualified ARN:

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    task: arn:aws:ecs:eu-central-1:123456789012:task-definition/my-task:20
```

With a task family name + revision:

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    task: my-task:20
```

Or just a task family name (uses the most recent revision):

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    task: my-task
```

#### Set environment variables

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    env_vars: containerName SOME_VARIABLE SOME_VALUE
```

Multiple variables (comma-separated):

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    env_vars: containerName SOME_VARIABLE SOME_VALUE, containerName OTHER_VARIABLE OTHER_VALUE, appContainer APP_VARIABLE APP_VALUE
```

Set environment variables exclusively (remove all other pre-existing env vars
on the task definition):

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    env_vars: containerName SOME_VARIABLE SOME_VALUE
    exclusive_env: true
```

#### Set secrets from AWS Parameter Store / Secrets Manager

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    secrets: containerName SOME_SECRET arn:aws:ssm:<region>:<account>:parameter/KEY
```

Set secrets exclusively:

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    secrets: containerName SOME_SECRET arn:aws:ssm:<region>:<account>:parameter/KEY
    exclusive_secrets: true
```

#### Override a container command

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    command: containerName "nginx -c /etc/nginx/nginx.conf"
```

#### Set a task role

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    cluster: theClusterName
    target: theServiceName
    task_role: arn:aws:iam::123456789012:role/MySpecialEcsTaskRole
```

#### Other deploy options

| Input | Description |
|---|---|
| `ignore_warnings: true` | Continue on `port already in use` / insufficient memory warnings. |
| `no_deregister: true` | Keep the previous task definition instead of deregistering it. |
| `rollback: true` | Roll back to the previous revision if deployment fails. |
| `timeout: 1200` | Wait up to N seconds for the deployment to converge (default `300`; `-1` = fire-and-forget). |

### Cron (scheduled-task) updates

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    action: cron
    cluster: theClusterName
    target: taskName
    rule: ruleName
    image: application my-app:1.2.3
```

The following options work the same with `cron` as with `deploy`: `image`,
`tag`, `env_vars`, `exclusive_env`, `task_role`, `command`, `no_deregister`,
`rollback`.

### Scaling

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    action: scale
    cluster: theClusterName
    target: theServiceName
    scale_value: 4
```

### Running a one-off task

Basic:

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    action: run
    cluster: theClusterName
    target: taskName:taskRevision
```

With env vars:

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    action: run
    cluster: theClusterName
    target: taskName:taskRevision
    env_vars: containerName SOME_VARIABLE SOME_VALUE
```

With a custom command:

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    action: run
    cluster: theClusterName
    target: taskName:taskRevision
    command: my-container "python some-script.py param1 param2"
```

Inside Fargate:

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    action: run
    cluster: theClusterName
    target: taskName:taskRevision
    command: my-container "python some-script.py param1 param2"
    launch_type: FARGATE
    security_group: securityGroupID
    subnet: subnetID
    public_ip: true
```

### Updating a task definition (without running or deploying)

```yaml
- uses: ignitetech-group/action-ecs-deploy@main
  with:
    action: update
    target: taskFamilyName
    tag: 1.2.3
```

## Inputs

Refer to [`action.yml`](./action.yml) for the full input table. Notable
inputs:

| Input | Required | Default | Notes |
|---|---|---|---|
| `action` | yes | `deploy` | One of: `deploy`, `cron`, `scale`, `run`, `update`. Validated. |
| `cluster` | yes (except `update`) | — | ECS cluster name. |
| `target` | yes | — | Service or task name. |
| `tag` | no | — | New image tag (mutually exclusive with `image`). |
| `image` | no | — | `<container> <image>` pairs, comma-separated. |
| `task` | no | — | Task ARN, family + revision, or just family. |
| `rule` | required for `cron` | — | CloudWatch Events rule name. |
| `scale_value` | required for `scale` | — | Integer desired count. |
| `timeout` | no | `300` | Integer; `-1` to disable. |
| `launch_type` | no | `EC2` | One of `EC2`, `FARGATE`. Validated. |
| `public_ip` | no | `false` | Set to `true` for Fargate `run` with public IP. |

The full upstream CLI documentation lives in
[`ignitetech-group/ecs-deploy/README.rst`](https://github.com/ignitetech-group/ecs-deploy/blob/main/README.rst)
(the underlying `ecs` CLI).

## Troubleshooting

### "Unknown task definition arn"

Ensure the IAM role/credentials used by the workflow have at least
`ecs:ListTaskDefinitions`, `ecs:DescribeServices`, `ecs:DescribeTaskDefinition`,
`ecs:RegisterTaskDefinition`, and `ecs:UpdateService` on the relevant
resources.

### "input 'action' must be one of: ..."

This fork validates `action` against a whitelist before invoking `ecs`. If you
pass a typo (e.g. `deplyo`), the action exits with a clear error rather than
attempting an undefined invocation.

## License

MIT — same as upstream. See [`LICENSE`](./LICENSE).
