#!/usr/bin/env bash
set -euo pipefail

RED=$'\033[31m'
RESET=$'\033[0m'

if [[ -z "${REAL_GIT:-}" ]]; then
  echo "${RED}[ERROR]${RESET} REAL_GIT is not set" >&2
  exit 127
fi

args=("$@")
subcmd=""
i=0

while [[ $i -lt ${#args[@]} ]]; do
  arg="${args[$i]}"

  case "${arg}" in
    -C|-c|--git-dir|--work-tree|--namespace)
      i=$((i + 2))
      ;;
    --git-dir=*|--work-tree=*|--namespace=*)
      i=$((i + 1))
      ;;
    --*)
      i=$((i + 1))
      ;;
    -*)
      i=$((i + 1))
      ;;
    *)
      subcmd="${arg}"
      break
      ;;
  esac
done

case "${subcmd}" in
  status|diff|log|show|ls-files|grep|rev-parse|describe|blame|branch)
    GIT_OPTIONAL_LOCKS=0 exec "${REAL_GIT}" "$@"
    ;;

  config)
    for arg in "$@"; do
      case "${arg}" in
        --global|--system|--local|--worktree|--add|--replace-all|--unset|--unset-all|--remove-section|--rename-section)
          echo "[BLOCKED] git config write operation is not allowed" >&2
          exit 126
          ;;
      esac
    done
    GIT_OPTIONAL_LOCKS=0 exec "${REAL_GIT}" "$@"
    ;;

  "")
    GIT_OPTIONAL_LOCKS=0 exec "${REAL_GIT}" "$@"
    ;;

  *)
    echo "[BLOCKED] git write or unsafe operation is not allowed: git ${subcmd}" >&2
    exit 126
    ;;
esac
