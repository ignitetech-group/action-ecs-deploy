#!/usr/bin/env bash
#
# Entrypoint for ignitetech-group/action-ecs-deploy.
#
# Translates the action's INPUT_* environment variables (set by the GitHub
# Actions runner from inputs in action.yml) into a properly-quoted argv
# invocation of the ecs CLI from ignitetech-group/ecs-deploy (a
# security-hardened fork of fabfuel/ecs-deploy, installed via pip from a
# pinned commit SHA in the Dockerfile).
#
# Security note: the upstream donaldpiret/ecs-deploy entrypoint built a single
# command string from unsanitized INPUT_* values and ran it through `eval`,
# which is a textbook shell-injection vector (an attacker controlling any
# input could execute arbitrary code in the runner). This rewrite eliminates
# eval entirely: every input either becomes a discrete element of an argv
# array, is validated against a whitelist, or is checked to be a numeric
# value. The final invocation is `exec "${cmd[@]}"`, which never reparses
# argv as shell.

set -Eeuo pipefail

on_error() {
  local rc=$?
  echo "[ERROR] entrypoint.sh failed at line ${BASH_LINENO[0]} (rc=${rc})" >&2
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Input validation helpers
# ---------------------------------------------------------------------------

# Validate that ${value} is one of the space-separated tokens in ${allowed}.
# Usage: validate_choice "input_name" "$value" "deploy cron scale run update"
validate_choice() {
  local name="$1"
  local value="$2"
  local allowed="$3"
  local a
  for a in ${allowed}; do
    if [[ "${value}" == "${a}" ]]; then
      return 0
    fi
  done
  echo "[ERROR] input '${name}' must be one of: ${allowed} (got: '${value}')" >&2
  exit 1
}

# Validate that ${value} is a (possibly negative) base-10 integer.
# Usage: validate_int "input_name" "$value"
validate_int() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^-?[0-9]+$ ]]; then
    echo "[ERROR] input '${name}' must be an integer (got: '${value}')" >&2
    exit 1
  fi
}

# Tokenize a shell-quoted whitespace-separated string into one token per
# line, respecting single/double quotes WITHOUT executing anything. We pipe
# through xargs(1) which performs the same word-splitting your shell does
# but only invokes printf to echo each token back out.
#
# Usage:
#   readarray -t parts < <(tokenize_field "$value")
tokenize_field() {
  local trimmed="${1#"${1%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [[ -z "${trimmed}" ]]; then
    return 0
  fi
  printf '%s\n' "${trimmed}" | xargs -n1 printf '%s\n'
}

# Append repeated --flag arguments to ${cmd} for each comma-separated chunk
# of ${raw}. Each chunk must tokenize to exactly ${expected_n} whitespace-
# separated tokens. Empty ${raw} is a no-op.
#
# Example: append_multi -i "webserver nginx:1.11.8, application my-app:1.2.3" 2
#   adds: -i webserver nginx:1.11.8 -i application my-app:1.2.3
append_multi() {
  local flag="$1"
  local raw="$2"
  local expected_n="$3"
  if [[ -z "${raw}" ]]; then
    return 0
  fi
  local IFS=','
  local -a chunks
  read -ra chunks <<< "${raw}"
  unset IFS

  local chunk
  local -a parts
  for chunk in "${chunks[@]}"; do
    readarray -t parts < <(tokenize_field "${chunk}")
    if [[ "${#parts[@]}" -ne "${expected_n}" ]]; then
      echo "[ERROR] each '${flag}' value must contain exactly ${expected_n} whitespace-separated tokens (got ${#parts[@]} from chunk: '${chunk}')" >&2
      exit 1
    fi
    cmd+=("${flag}" "${parts[@]}")
  done
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

ACTION="${INPUT_ACTION:-}"
if [[ -z "${ACTION}" ]]; then
  echo "[ERROR] input 'action' is required" >&2
  exit 1
fi
validate_choice "action" "${ACTION}" "deploy cron scale run update"

CLUSTER="${INPUT_CLUSTER:-}"
TARGET="${INPUT_TARGET:-}"

# Build the base argv. ecs update only takes a task; everything else takes
# cluster + service|task as positional arguments.
declare -a cmd
case "${ACTION}" in
  update)
    if [[ -z "${TARGET}" ]]; then
      echo "[ERROR] input 'target' is required for action 'update'" >&2
      exit 1
    fi
    cmd=(ecs update "${TARGET}")
    ;;
  *)
    if [[ -z "${CLUSTER}" ]]; then
      echo "[ERROR] input 'cluster' is required for action '${ACTION}'" >&2
      exit 1
    fi
    if [[ -z "${TARGET}" ]]; then
      echo "[ERROR] input 'target' is required for action '${ACTION}'" >&2
      exit 1
    fi
    cmd=(ecs "${ACTION}" "${CLUSTER}" "${TARGET}")
    ;;
esac

# Per-action positional / required arguments
case "${ACTION}" in
  cron)
    if [[ -z "${INPUT_RULE:-}" ]]; then
      echo "[ERROR] input 'rule' is required for action 'cron'" >&2
      exit 1
    fi
    cmd+=("${INPUT_RULE}")
    ;;
  scale)
    if [[ -z "${INPUT_SCALE_VALUE:-}" ]]; then
      echo "[ERROR] input 'scale_value' is required for action 'scale'" >&2
      exit 1
    fi
    validate_int "scale_value" "${INPUT_SCALE_VALUE}"
    cmd+=("${INPUT_SCALE_VALUE}")
    ;;
esac

# Optional shared flags. tag and image are mutually exclusive in the deploy
# action per upstream behaviour, but we let the underlying ecs CLI enforce
# that — passing both will surface a clear error from click.
if [[ -n "${INPUT_TAG:-}" ]]; then
  cmd+=(--tag "${INPUT_TAG}")
fi

append_multi -i "${INPUT_IMAGE:-}" 2
append_multi -e "${INPUT_ENV_VARS:-}" 3
append_multi -s "${INPUT_SECRETS:-}" 3

# --task overrides the running task definition; only meaningful for actions
# other than update (which already takes the task as a positional argument).
if [[ -n "${INPUT_TASK:-}" && "${ACTION}" != "update" ]]; then
  cmd+=(--task "${INPUT_TASK}")
fi

if [[ "${INPUT_EXCLUSIVE_ENV:-}" == "true" ]]; then
  cmd+=(--exclusive-env)
fi

if [[ "${INPUT_EXCLUSIVE_SECRETS:-}" == "true" ]]; then
  cmd+=(--exclusive-secrets)
fi

# --command takes 2 tokens per occurrence (container, command-string), and
# the command-string itself may contain spaces (typically wrapped in double
# quotes by the caller, e.g. `webserver "nginx -c /etc/nginx/nginx.conf"`).
append_multi --command "${INPUT_COMMAND:-}" 2

case "${ACTION}" in
  deploy|cron)
    if [[ -n "${INPUT_TASK_ROLE:-}" ]]; then
      cmd+=(--role "${INPUT_TASK_ROLE}")
    fi
    if [[ "${INPUT_IGNORE_WARNINGS:-}" == "true" ]]; then
      cmd+=(--ignore-warnings)
    fi
    if [[ "${INPUT_NO_DEREGISTER:-}" == "true" ]]; then
      cmd+=(--no-deregister)
    fi
    if [[ "${INPUT_ROLLBACK:-}" == "true" ]]; then
      cmd+=(--rollback)
    fi
    if [[ "${ACTION}" != "cron" ]]; then
      timeout="${INPUT_TIMEOUT:-300}"
      validate_int "timeout" "${timeout}"
      cmd+=(--timeout "${timeout}")
    fi
    ;;
  run)
    if [[ -n "${INPUT_LAUNCH_TYPE:-}" ]]; then
      validate_choice "launch_type" "${INPUT_LAUNCH_TYPE}" "EC2 FARGATE"
      cmd+=(--launchtype "${INPUT_LAUNCH_TYPE}")
    fi
    if [[ -n "${INPUT_SECURITY_GROUP:-}" ]]; then
      cmd+=(--securitygroup "${INPUT_SECURITY_GROUP}")
    fi
    if [[ -n "${INPUT_SUBNET:-}" ]]; then
      cmd+=(--subnet "${INPUT_SUBNET}")
    fi
    # The original donaldpiret entrypoint checked $INPUT_public_ip (lowercase)
    # which never matched: GitHub Actions converts input names to uppercase
    # when building env vars, so the canonical name is INPUT_PUBLIC_IP. Honour
    # both for backwards-compatibility, but document that this was a bug.
    if [[ "${INPUT_PUBLIC_IP:-${INPUT_public_ip:-}}" == "true" ]]; then
      cmd+=(--public-ip)
    fi
    ;;
esac

# Log a safe, structured summary of what's about to run. We deliberately
# do NOT print the full argv: INPUT_ENV_VARS, INPUT_COMMAND, and (in
# malformed-but-possible callers) other inputs can carry sensitive values,
# and dumping them risks leaking secrets into workflow logs even with
# GitHub's built-in mask-matching (which only catches values registered
# via the `secrets` context, and only as exact byte sequences). Operators
# who need full input visibility should consult the runner's input-echo
# section at the top of the job, where GitHub's secret redaction applies.
#
# action / cluster / target are safe to log: action is whitelist-validated
# (deploy|cron|scale|run|update), and cluster/target are AWS-infrastructure
# identifiers that show up in CloudWatch / tagged-resource listings anyway.
case "${ACTION}" in
  update)
    echo "Executing: ecs update '${TARGET}' (${#cmd[@]} argv tokens; option values redacted)"
    ;;
  *)
    echo "Executing: ecs ${ACTION} cluster='${CLUSTER}' target='${TARGET}' (${#cmd[@]} argv tokens; option values redacted)"
    ;;
esac
exec "${cmd[@]}"
