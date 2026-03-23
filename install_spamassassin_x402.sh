#!/usr/bin/env bash
set -euo pipefail

# Remote-friendly installer for SpamAssassin + x402 email check plugin.
# Supports:
#   curl -fsSL <raw-script-url> | sudo bash -s -- [options]
#
# Environment options:
#   REPO_URL          Git repository URL
#   REPO_REF          Branch/tag/commit (default: main)
#   INSTALL_DIR       Temporary working directory for checkout
#   SA_DIR            SpamAssassin config directory (default: /etc/mail/spamassassin)
#   SA_LOCAL_CF       Active local.cf path (default: /etc/mail/spamassassin/local.cf)
#   PYTHON_BIN        Python binary path (default: /usr/bin/python3; must be >= Python 3.10)
#   ENDPOINT_URL      API endpoint (default: https://app.cusethejuice.com/api/bots/email-check)
#   TIMEOUT_SECONDS   Timeout for endpoint calls (default: 2)
#
# Required runtime secret:
#   EVM_PRIVATE_KEY or BASE_WALLET_PRIVATE_KEY in the spamd runtime environment.

REPO_URL="${REPO_URL:-https://github.com/CuseTheJuice/x402-email-check-via-spamassassin.git}"
REPO_REF="${REPO_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-/tmp/x402-email-check-via-spamassassin}"
SA_DIR="${SA_DIR:-/etc/mail/spamassassin}"
SA_LOCAL_CF="${SA_LOCAL_CF:-${SA_DIR}/local.cf}"
PYTHON_BIN_DEFAULTED=0
if [[ -z "${PYTHON_BIN:-}" ]]; then
  PYTHON_BIN_DEFAULTED=1
  PYTHON_BIN="/usr/bin/python3"
fi
ENDPOINT_URL="${ENDPOINT_URL:-https://app.cusethejuice.com/api/bots/email-check}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-2}"

PLUGIN_PM="CTJEmailCheck.pm"
PLUGIN_CF="ctj-email-check.cf"
CLIENT_PY="x402_email_check_client.py"
REQ_TXT="requirements-x402-client.txt"

abort() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || abort "Missing required command: $1"
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"
    return
  fi
  echo "unknown"
}

install_base_dependencies() {
  local pm
  pm="$(detect_package_manager)"

  case "$pm" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git \
        ca-certificates \
        spamassassin \
        python3 \
        python3-pip
      ;;
    dnf)
      dnf install -y \
        git \
        ca-certificates \
        spamassassin \
        python3 \
        python3-pip
      ;;
    yum)
      yum install -y \
        git \
        ca-certificates \
        spamassassin \
        python3 \
        python3-pip
      ;;
    *)
      echo "WARNING: Unsupported package manager; skipping OS package install." >&2
      ;;
  esac
}

python_is_at_least_310() {
  local py="$1"
  [[ -x "$py" ]] || return 1
  "$py" - <<'PY' >/dev/null 2>&1
import sys
sys.exit(0 if sys.version_info >= (3, 10) else 1)
PY
}

maybe_select_new_python() {
  # If PYTHON_BIN already satisfies the x402 requirement, keep it.
  if python_is_at_least_310 "$PYTHON_BIN"; then
    return 0
  fi

  # Otherwise, look for already-installed Python 3.10+ in PATH.
  local candidates=(python3.12 python3.11 python3.10)
  for c in "${candidates[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
      local py_path
      py_path="$(command -v "$c")"
      if python_is_at_least_310 "$py_path"; then
        echo "Using detected Python: $py_path"
        PYTHON_BIN="$py_path"
        return 0
      fi
    fi
  done

  return 1
}

install_python_310_if_needed() {
  if python_is_at_least_310 "$PYTHON_BIN"; then
    return 0
  fi

  if [[ "$PYTHON_BIN_DEFAULTED" -ne 1 ]]; then
    abort "x402 requires Python >= 3.10. Your PYTHON_BIN='${PYTHON_BIN}' is too old; set PYTHON_BIN=/usr/bin/python3.10 (or newer) and re-run."
  fi

  local pm
  pm="$(detect_package_manager)"
  case "$pm" in
    apt)
      echo "Installing Python 3.10+ (required by x402)..."
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common

      # Try base repos first.
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3.10 || true

      # Optional extras; not required for this installer flow.
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3.10-venv || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3.10-dev || true

      # If still missing, try deadsnakes.
      if ! command -v python3.10 >/dev/null 2>&1; then
        add-apt-repository -y ppa:deadsnakes/ppa
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
          python3.10

        # Optional extras; best effort only.
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3.10-venv || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3.10-dev || true
      fi

      if command -v python3.10 >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python3.10)"
      fi
      ;;
    *)
      abort "x402 requires Python >= 3.10, but this host doesn't look apt-based. Install Python 3.10+ manually and re-run with PYTHON_BIN=/path/to/python3.10."
      ;;
  esac

  python_is_at_least_310 "$PYTHON_BIN" || abort "Python 3.10+ install failed; PYTHON_BIN='${PYTHON_BIN}' is still too old."
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    abort "Run as root (or via sudo) so files can be installed to ${SA_DIR}"
  fi
}

backup_file_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    local stamp
    stamp="$(date +%Y%m%d%H%M%S)"
    cp -a "$path" "${path}.bak.${stamp}"
  fi
}

append_local_cf_if_missing() {
  local marker_begin="# BEGIN CTJ x402 email check"
  local marker_end="# END CTJ x402 email check"

  mkdir -p "$(dirname "$SA_LOCAL_CF")"
  touch "$SA_LOCAL_CF"

  if grep -q "${marker_begin}" "$SA_LOCAL_CF"; then
    echo "CTJ config block already present in ${SA_LOCAL_CF}; skipping append."
    return
  fi

  cat >>"$SA_LOCAL_CF" <<EOF

${marker_begin}
loadplugin Mail::SpamAssassin::Plugin::CTJEmailCheck ${SA_DIR}/${PLUGIN_PM}
ctj_email_check_script_python_bin ${PYTHON_BIN}
ctj_email_check_script_path ${SA_DIR}/${CLIENT_PY}
ctj_email_check_script_endpoint ${ENDPOINT_URL}
ctj_email_check_timeout_seconds ${TIMEOUT_SECONDS}

header CTJ_EMAIL_CHECK_FROM eval:ctj_email_check_header('From')
score CTJ_EMAIL_CHECK_FROM 2.5
describe CTJ_EMAIL_CHECK_FROM Invalid email syntax detected in From header

header CTJ_EMAIL_CHECK_REPLYTO eval:ctj_email_check_header('Reply-To')
score CTJ_EMAIL_CHECK_REPLYTO 1.5
describe CTJ_EMAIL_CHECK_REPLYTO Invalid email syntax detected in Reply-To header
${marker_end}
EOF
}

restart_spamd_if_possible() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^spamd\.service'; then
      systemctl restart spamd
      systemctl --no-pager --full status spamd | sed -n '1,10p'
      return
    fi
    if systemctl list-unit-files | grep -q '^spamassassin\.service'; then
      systemctl restart spamassassin
      systemctl --no-pager --full status spamassassin | sed -n '1,10p'
      return
    fi
  fi

  echo "No managed spamd service found. Restart manually if required."
}

main() {
  ensure_root
  need_cmd git

  install_base_dependencies
  need_cmd git
  maybe_select_new_python || true
  install_python_310_if_needed
  need_cmd "$PYTHON_BIN"
  need_cmd spamassassin

  rm -rf "$INSTALL_DIR"
  git clone --depth=1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"

  [[ -f "${INSTALL_DIR}/${PLUGIN_PM}" ]] || abort "Missing ${PLUGIN_PM} in repo"
  [[ -f "${INSTALL_DIR}/${PLUGIN_CF}" ]] || abort "Missing ${PLUGIN_CF} in repo"
  [[ -f "${INSTALL_DIR}/${CLIENT_PY}" ]] || abort "Missing ${CLIENT_PY} in repo"
  [[ -f "${INSTALL_DIR}/${REQ_TXT}" ]] || abort "Missing ${REQ_TXT} in repo"

  mkdir -p "$SA_DIR"
  backup_file_if_exists "${SA_DIR}/${PLUGIN_PM}"
  backup_file_if_exists "${SA_DIR}/${PLUGIN_CF}"
  backup_file_if_exists "${SA_DIR}/${CLIENT_PY}"
  backup_file_if_exists "$SA_LOCAL_CF"

  install -m 0644 "${INSTALL_DIR}/${PLUGIN_PM}" "${SA_DIR}/${PLUGIN_PM}"
  install -m 0644 "${INSTALL_DIR}/${PLUGIN_CF}" "${SA_DIR}/${PLUGIN_CF}"
  install -m 0755 "${INSTALL_DIR}/${CLIENT_PY}" "${SA_DIR}/${CLIENT_PY}"

  # Ensure pip exists for the selected Python.
  "$PYTHON_BIN" -m ensurepip --upgrade || true
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install -r "${INSTALL_DIR}/${REQ_TXT}"

  append_local_cf_if_missing

  echo "Running SpamAssassin lint..."
  spamassassin --lint

  echo "Restarting spam daemon (if detected)..."
  restart_spamd_if_possible

  cat <<'EOF'

Install completed.

Next required step:
1) Ensure spamd runtime has wallet key exported:
   - EVM_PRIVATE_KEY=0x...   (preferred)
   - or BASE_WALLET_PRIVATE_KEY=0x...
2) Send a test email and confirm CTJ_EMAIL_CHECK_* rules in SpamAssassin logs.

EOF
}

main "$@"
