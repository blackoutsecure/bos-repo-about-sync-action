# shellcheck shell=bash
# Shared bash helpers for the Repo About Box Sync composite action.
#
# Sourced via:
#     . "${GITHUB_ACTION_PATH}/lib.sh"
#
# Conventions:
#   * Every helper logs to stderr and exits 1 on hard failure.
#   * `die` accepts an optional `ERR_TITLE` env var for the GH error
#     annotation title; defaults to "Repo About Box Sync".

# die "<message>"  — emit GH-annotated error and exit 1.
die() {
  printf '::error title=%s::%s\n' "${ERR_TITLE:-Repo About Box Sync}" "$*" >&2
  exit 1
}

# validate_bool <var-name> — assert that the value is exactly "true" or
# "false". Reads via indirection so callers can pass the variable name.
validate_bool() {
  local name="$1"
  local val="${!name-}"
  case "${val}" in
    true|false) : ;;
    *) die "input ${name}=${val:-<empty>} must be 'true' or 'false'" ;;
  esac
}

# require_var <var-name> — assert that the named variable is non-empty.
require_var() {
  local name="$1"
  local val="${!name-}"
  [ -n "${val}" ] || die "required input ${name} is empty"
}
