#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

GIT_WRAPPER_SOURCE="${REPO_ROOT}/ai/utils/git-readonly-wrapper.sh"
REPO_GUARD="${REPO_ROOT}/ai/utils/repo_guard.py"

CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_EFFORT="${CODEX_EFFORT:-high}"
AI_RUN_ASSUME_YES="${AI_RUN_ASSUME_YES:-0}"
KEEP_TMP_ON_FAILURE="${KEEP_TMP_ON_FAILURE:-1}"

RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-run.XXXXXX")"
WORK_REPO="${RUN_TMP}/repo"
WRAPPER_DIR="${RUN_TMP}/bin"
CODEX_OUTPUT_LOG="${RUN_TMP}/codex_output.log"

ANSWER_FOR_PRECHECK_REL="ai/answer_for_precheck_questions.md"

RED=$'\033[31m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RESET=$'\033[0m'

STATE_DIR=""
SESSION_ID_FILE=""

log() {
  echo "[INFO] $*" >&2
}

warn() {
  echo "${YELLOW}[WARN] $*${RESET}" >&2
}

error() {
  echo "${RED}[ERROR] $*${RESET}" >&2
}

die() {
  error "$*"
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

on_exit() {
  local status=$?
  if [[ "${status}" -ne 0 && "${KEEP_TMP_ON_FAILURE}" == "1" ]]; then
    echo "[INFO] failed. temporary directory kept for inspection: ${RUN_TMP}" >&2
  else
    rm -rf "${RUN_TMP}"
  fi
  exit "${status}"
}
trap on_exit EXIT

phase_instruction_rel() {
  case "$1" in
    1) echo "ai/ai1/1_precheck_phase_instruction.md" ;;
    2) echo "ai/ai1/2_specification_phase_instruction.md" ;;
    3) echo "ai/ai1/3_branch_plan_phase_instruction.md" ;;
    *) return 1 ;;
  esac
}

phase_allowed_paths() {
  case "$1" in
    1)
      printf '%s\n' "ai/precheck_questions_advice.md"
      ;;
    2)
      printf '%s\n' "ai/confirmed_specification.md"
      ;;
    3)
      printf '%s\n' \
        "ai/goal_branch_name.txt" \
        "ai/implementation_branch_plan.md"
      ;;
    *)
      return 1
      ;;
  esac
}

phase_confirm_message() {
  case "$1" in
    2) echo "Phase 1 の Codex セッションを resume して Phase 2 を実行します。続行しますか?" ;;
    3) echo "Phase 2 の続きとして同じ Codex セッションを resume して Phase 3 を実行します。続行しますか?" ;;
    *) echo "" ;;
  esac
}

init_state_paths() {
  STATE_DIR="${CODEX_ORCHESTRATOR_STATE_DIR:-$(python3 "${REPO_GUARD}" state-dir "${REPO_ROOT}")}"
  SESSION_ID_FILE="${CODEX_SESSION_ID_FILE:-${STATE_DIR}/codex_session_id}"
}

instruction_file_for_phase() {
  local phase="$1"
  echo "${REPO_ROOT}/$(phase_instruction_rel "${phase}")"
}

work_instruction_file_for_phase() {
  local phase="$1"
  echo "${WORK_REPO}/$(phase_instruction_rel "${phase}")"
}

require_instruction_file_for_phase() {
  local phase="$1"
  local file=""
  file="$(instruction_file_for_phase "${phase}")"
  [[ -f "${file}" ]] || die "phase ${phase} instruction file not found: ${file}"
}

make_manifest() {
  python3 "${REPO_GUARD}" manifest "$1" "$2"
}

verify_only_allowed_changed() {
  local before="$1"
  local after="$2"
  local label="$3"
  shift 3
  python3 "${REPO_GUARD}" verify "${before}" "${after}" "${label}" --allowed "$@"
}

copy_repository_to_workdir() {
  python3 "${REPO_GUARD}" copytree "${REPO_ROOT}" "${WORK_REPO}"
}

validate_symlinks_stay_inside() {
  python3 "${REPO_GUARD}" validate-symlinks "$1"
}

copy_allowed_files_back() {
  python3 "${REPO_GUARD}" copyback "${WORK_REPO}" "${REPO_ROOT}" "$@"
}

setup_command_wrappers() {
  mkdir -p "${WRAPPER_DIR}"

  local real_git=""
  real_git="$(command -v git || true)"

  if [[ -n "${real_git}" ]]; then
    cp "${GIT_WRAPPER_SOURCE}" "${WRAPPER_DIR}/git"
    chmod +x "${WRAPPER_DIR}/git"
  fi

  for cmd in sudo chmod chown chgrp mv rm cp touch install mkdir rmdir ln; do
    cat > "${WRAPPER_DIR}/${cmd}" <<EOF_BLOCK
#!/usr/bin/env bash
echo "[BLOCKED] ${cmd} is not allowed in this Codex run" >&2
exit 126
EOF_BLOCK
    chmod +x "${WRAPPER_DIR}/${cmd}"
  done
}

confirm_continue() {
  local message="$1"

  if [[ "${AI_RUN_ASSUME_YES}" == "1" ]]; then
    return 0
  fi

  local answer=""
  printf '%s [y/N]: ' "${message}" >&2
  read -r answer || true

  case "${answer}" in
    y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      echo "[INFO] canceled." >&2
      return 1
      ;;
  esac
}

sync_answer_for_precheck_questions_to_work_repo() {
  local original_file="${REPO_ROOT}/${ANSWER_FOR_PRECHECK_REL}"
  local work_file="${WORK_REPO}/${ANSWER_FOR_PRECHECK_REL}"

  if [[ -f "${original_file}" ]]; then
    if [[ ! -e "${work_file}" ]]; then
      mkdir -p "$(dirname -- "${work_file}")"
      cp -p "${original_file}" "${work_file}"
      log "copied ${ANSWER_FOR_PRECHECK_REL} from original repository to temporary workspace because it was missing in the workspace"
      return 0
    fi

    if [[ -f "${work_file}" && "${original_file}" -nt "${work_file}" ]]; then
      mkdir -p "$(dirname -- "${work_file}")"
      cp -p "${original_file}" "${work_file}"
      log "copied ${ANSWER_FOR_PRECHECK_REL} from original repository to temporary workspace because the original file was newer"
      return 0
    fi

    log "kept temporary workspace ${ANSWER_FOR_PRECHECK_REL}; original was not newer"
    return 0
  fi

  if [[ -e "${work_file}" ]]; then
    log "kept temporary workspace ${ANSWER_FOR_PRECHECK_REL}; original file does not exist"
    return 0
  fi

  error "${ANSWER_FOR_PRECHECK_REL} does not exist in either the original repository or the temporary workspace."

  if confirm_continue 'このまま Phase 2 を続行しますか?'; then
    return 0
  fi

  return 1
}

resolve_session_id() {
  local id="${CODEX_SESSION_ID:-}"

  if [[ -z "${id}" && -f "${SESSION_ID_FILE}" ]]; then
    id="$(tr -d '[:space:]' < "${SESSION_ID_FILE}")"
  fi

  python3 "${REPO_GUARD}" validate-session-id "${id}"
}

extract_and_save_session_id_from_log() {
  python3 "${REPO_GUARD}" extract-session "${CODEX_OUTPUT_LOG}" "${SESSION_ID_FILE}"
}

run_codex_exec_phase1() {
  local codex_status=0
  local real_git_for_wrapper=""
  local instruction_file=""

  real_git_for_wrapper="$(command -v git || true)"
  instruction_file="$(work_instruction_file_for_phase 1)"

  log "start phase 1 as a fresh Codex session"

  set +e
  (
    unset CODEX_SESSION_ID
    cd "${WORK_REPO}"
    PATH="${WRAPPER_DIR}:${PATH}" \
    REAL_GIT="${real_git_for_wrapper}" \
    GIT_OPTIONAL_LOCKS=0 \
    "${CODEX_BIN}" exec \
      --model "${CODEX_MODEL}" \
      --sandbox workspace-write \
      --json \
      -c "model_reasoning_effort=\"${CODEX_EFFORT}\"" \
      -c 'approval_policy="never"' \
      - < "${instruction_file}"
  ) 2>&1 | tee "${CODEX_OUTPUT_LOG}"
  codex_status=${PIPESTATUS[0]}
  set -e

  return "${codex_status}"
}

run_codex_resume() {
  local phase="$1"
  local session_id="$2"
  local codex_status=0
  local real_git_for_wrapper=""
  local instruction_file=""

  real_git_for_wrapper="$(command -v git || true)"
  instruction_file="$(work_instruction_file_for_phase "${phase}")"

  (
    cd "${WORK_REPO}"
    PATH="${WRAPPER_DIR}:${PATH}" \
    REAL_GIT="${real_git_for_wrapper}" \
    GIT_OPTIONAL_LOCKS=0 \
    "${CODEX_BIN}" exec resume \
      "${session_id}" \
      - < "${instruction_file}"
  ) || codex_status=$?

  return "${codex_status}"
}

run_codex_for_phase() {
  local phase="$1"
  local session_id="$2"

  case "${phase}" in
    1)
      run_codex_exec_phase1
      ;;
    2|3)
      run_codex_resume "${phase}" "${session_id}"
      ;;
    *)
      die "unsupported phase: ${phase}"
      ;;
  esac
}

run_phase() {
  local phase="$1"
  local session_id="$2"
  local allowed_paths=()

  mapfile -t allowed_paths < <(phase_allowed_paths "${phase}")

  local original_before="${RUN_TMP}/original_before_phase${phase}.json"
  local original_after="${RUN_TMP}/original_after_phase${phase}.json"
  local work_before="${RUN_TMP}/work_before_phase${phase}.json"
  local work_after="${RUN_TMP}/work_after_phase${phase}.json"

  log "snapshot original repository before phase ${phase}"
  make_manifest "${REPO_ROOT}" "${original_before}"

  log "snapshot temporary workspace before phase ${phase}"
  make_manifest "${WORK_REPO}" "${work_before}"

  log "run Codex phase ${phase} in temporary workspace"
  local codex_status=0
  run_codex_for_phase "${phase}" "${session_id}" || codex_status=$?

  if [[ "${phase}" == "1" ]]; then
    extract_and_save_session_id_from_log
  fi

  log "snapshot temporary workspace after phase ${phase}"
  make_manifest "${WORK_REPO}" "${work_after}"

  log "verify temporary workspace changes after phase ${phase}"
  verify_only_allowed_changed "${work_before}" "${work_after}" "temporary workspace phase ${phase}" "${allowed_paths[@]}"

  if [[ "${codex_status}" -ne 0 ]]; then
    die "codex phase ${phase} failed with exit code ${codex_status}. Nothing was copied back."
  fi

  log "copy allowed files back after phase ${phase}"
  copy_allowed_files_back "${allowed_paths[@]}"

  log "verify original repository changes after phase ${phase}"
  make_manifest "${REPO_ROOT}" "${original_after}"
  verify_only_allowed_changed "${original_before}" "${original_after}" "original repository phase ${phase}" "${allowed_paths[@]}"

  echo "${GREEN}[OK] Phase ${phase} completed.${RESET}"
}

prepare_workspace() {
  log "copy repository to temporary workspace: ${WORK_REPO}"
  copy_repository_to_workdir
  validate_symlinks_stay_inside "${WORK_REPO}"
  setup_command_wrappers
}

check_common_requirements() {
  need_command python3
  need_command "${CODEX_BIN}"

  [[ -f "${GIT_WRAPPER_SOURCE}" ]] || die "git wrapper not found: ${GIT_WRAPPER_SOURCE}"
  [[ -x "${GIT_WRAPPER_SOURCE}" ]] || die "git wrapper is not executable: ${GIT_WRAPPER_SOURCE}"
  [[ -f "${REPO_GUARD}" ]] || die "repo guard not found: ${REPO_GUARD}"
  [[ -d "${REPO_ROOT}/ai" ]] || die "directory not found: ${REPO_ROOT}/ai"

  require_instruction_file_for_phase 1
  require_instruction_file_for_phase 2
  require_instruction_file_for_phase 3
}

print_missing_session_help() {
  cat >&2 <<EOF_HELP
${RED}[ERROR] Codex session id is required.${RESET}

Set it with CODEX_SESSION_ID, or put it in:
  ${SESSION_ID_FILE}
EOF_HELP
}

main() {
  local session_id=""

  check_common_requirements
  init_state_paths
  prepare_workspace

  run_phase 1 ""

  if ! confirm_continue "$(phase_confirm_message 2)"; then
    exit 0
  fi

  # This must run before the phase 2 snapshots. If the user edited the original
  # answer file after phase 1, phase 2 must see that newer file in the workspace.
  if ! sync_answer_for_precheck_questions_to_work_repo; then
    exit 0
  fi

  if ! session_id="$(resolve_session_id)"; then
    print_missing_session_help
    exit 1
  fi

  run_phase 2 "${session_id}"

  if ! confirm_continue "$(phase_confirm_message 3)"; then
    exit 0
  fi

  run_phase 3 "${session_id}"
}

main "$@"
