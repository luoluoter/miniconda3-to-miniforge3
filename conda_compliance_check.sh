#!/usr/bin/env bash
set -euo pipefail

# ===== Config (override via env) =====
MINIFORGE_CONDA="${MINIFORGE_CONDA:-$HOME/miniforge3/bin/conda}"
MINICONDA_CONDA="${MINICONDA_CONDA:-$HOME/miniconda3/bin/conda}"
SCAN_YML_DIR="${SCAN_YML_DIR:-}"          # optional: scan env yaml exports
STRICT_EXIT="${STRICT_EXIT:-0}"           # 1 => exit nonzero if HIGH-RISK detected
USER_LIMIT="${USER_LIMIT:-200}"           # Anaconda free tier limit (org policy dependent)
USER_COUNT="${USER_COUNT:-}"              # set externally if you want, else skipped
ALLOW_ANACONDA_ORG="${ALLOW_ANACONDA_ORG:-1}"  # 1 allow conda.anaconda.org (default), 0 warn

# ===== Colors / logging =====
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; CYAN="\033[1;36m"; RESET="\033[0m"
ok()    { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
risk()  { echo -e "${RED}[RISK]${RESET} $*"; }
info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
have()  { command -v "$1" >/dev/null 2>&1; }

# ===== Global flags =====
HIGH_RISK_FOUND=0
WARN_FOUND=0

# ===== Small helpers =====
hr() { echo "------------------------------------------------------------"; }

# Extract block under a key from `conda config --show`
# Usage: extract_block "$cfg" "default_channels:"
extract_block() {
  local text="$1"
  local key="$2"
  # prints from key line until next "^\S+:" line (or end)
  echo "$text" | awk -v k="$key" '
    BEGIN{p=0}
    $0 ~ "^"k"$" {p=1; print; next}
    p==1 && $0 ~ "^[^[:space:]].*:$" {exit}
    p==1 {print}
  '
}

# Determine conda binary for label
resolve_conda_bin() {
  local conda_bin="$1"
  if [[ "$conda_bin" == "PATH" ]]; then
    if have conda; then
      command -v conda
    else
      echo ""
    fi
  else
    echo "$conda_bin"
  fi
}

# ===== License user-count check (optional, policy-dependent) =====
check_user_count() {
  hr
  info "Check target: license user count (optional)"
  echo "limit : $USER_LIMIT"
  echo "source: USER_COUNT env (set from LDAP/SSO/asset system)"
  hr

  if [[ -z "${USER_COUNT}" ]]; then
    warn "USER_COUNT not provided -> skip. (This check is policy-only; conda itself can't know org user count.)"
    return 0
  fi
  if ! [[ "${USER_COUNT}" =~ ^[0-9]+$ ]]; then
    warn "USER_COUNT is not a number: ${USER_COUNT} -> skip"
    return 0
  fi

  if [[ "${USER_COUNT}" -gt "${USER_LIMIT}" ]]; then
    warn "USER_COUNT exceeds ${USER_LIMIT}: ${USER_COUNT} > ${USER_LIMIT} (policy attention, not a repo endpoint proof)"
    WARN_FOUND=1
  else
    ok "USER_COUNT within limit: ${USER_COUNT} <= ${USER_LIMIT}"
  fi
}

# ===== Core: conda repo compliance check =====
check_conda() {
  local input_bin="$1"
  local label="$2"
  local conda_bin
  conda_bin="$(resolve_conda_bin "$input_bin")"

  if [[ -z "$conda_bin" ]]; then
    warn "($label) conda not found"
    return 0
  fi
  if [[ ! -x "$conda_bin" ]]; then
    warn "($label) conda not executable: $conda_bin"
    return 0
  fi

  hr
  info "Check target: repo compliance ($label)"
  echo "conda path : $conda_bin"
  hr

  local cfg src
  cfg="$("$conda_bin" config --show 2>/dev/null || true)"
  src="$("$conda_bin" config --show-sources 2>/dev/null || true)"

  # ---- HIGH-RISK signals (most relevant to Anaconda defaults/commercial repo) ----
  # 1) explicit `defaults` in channels
  local has_defaults_in_channels=0
  echo "$cfg" | awk '
    BEGIN{p=0}
    /^channels:$/ {p=1; next}
    p==1 && /^[^[:space:]].*:$/{exit}
    p==1 {print}
  ' | grep -Eiq '^\s*-\s*defaults\s*$' && has_defaults_in_channels=1

  # 2) repo.anaconda.com/pkgs/(main|r) present in default_channels/custom_channels/custom_multichannels
  local has_repo_anaconda_pkgs=0
  echo "$cfg" | grep -Eiq 'repo\.anaconda\.com/pkgs/(main|r)|/anaconda/pkgs/(main|r)|pkgs/(main|r)' && has_repo_anaconda_pkgs=1

  # ---- WARN signals (policy-dependent) ----
  # 3) channel_alias points to conda.anaconda.org (policy-dependent)
  local alias_line
  alias_line="$(echo "$cfg" | grep -E '^channel_alias:\s*' || true)"
  local alias_is_anaconda_org=0
  echo "$alias_line" | grep -Eiq 'channel_alias:\s*https?://conda\.anaconda\.org' && alias_is_anaconda_org=1

  # ---- Report: where the risk comes from (pinpoint) ----
  if [[ "$has_defaults_in_channels" == "1" ]]; then
    risk "($label) HIGH-RISK: 'defaults' is configured in channels."
    echo "Evidence:"
    extract_block "$cfg" "channels:" | sed 's/^/  /'
    HIGH_RISK_FOUND=1
  fi

  if [[ "$has_repo_anaconda_pkgs" == "1" ]]; then
    risk "($label) HIGH-RISK: pkgs/main or pkgs/r endpoints present in config (default/custom channels)."
    echo "Evidence (snippets):"
    extract_block "$cfg" "default_channels:" | sed 's/^/  /' || true
    extract_block "$cfg" "custom_channels:" | sed 's/^/  /' || true
    extract_block "$cfg" "custom_multichannels:" | sed 's/^/  /' || true
    HIGH_RISK_FOUND=1
  fi

  if [[ "$alias_is_anaconda_org" == "1" && "$ALLOW_ANACONDA_ORG" == "0" ]]; then
    warn "($label) WARN: channel_alias points to conda.anaconda.org and ALLOW_ANACONDA_ORG=0."
    echo "Evidence:"
    echo "  ${alias_line}"
    WARN_FOUND=1
  fi

  # If nothing triggered
  if [[ "$has_defaults_in_channels" == "0" && "$has_repo_anaconda_pkgs" == "0" && "$alias_is_anaconda_org" == "0" ]]; then
    ok "($label) PASS: no defaults + no pkgs/main|pkgs/r endpoints + no anaconda channel_alias detected."
  elif [[ "$has_defaults_in_channels" == "0" && "$has_repo_anaconda_pkgs" == "0" && "$alias_is_anaconda_org" == "1" && "$ALLOW_ANACONDA_ORG" == "0" ]]; then
    ok "($label) PASS (with WARN): repo looks clean; only policy-dependent alias warning."
  elif [[ "$has_defaults_in_channels" == "0" && "$has_repo_anaconda_pkgs" == "0" && "$alias_is_anaconda_org" == "1" && "$ALLOW_ANACONDA_ORG" != "0" ]]; then
    ok "($label) PASS: repo looks clean; channel_alias allowed."
  fi

  # ---- Always show sources (so you can fix the real file) ----
  echo
  info "Config sources (where these settings come from):"
  echo "$src" | sed 's/^/  /'

  # ---- Remediation guidance (only if needed) ----
  if [[ "$has_defaults_in_channels" == "1" || "$has_repo_anaconda_pkgs" == "1" || ( "$alias_is_anaconda_org" == "1" && "$ALLOW_ANACONDA_ORG" == "0" ) ]]; then
    echo
    info "Suggested remediation:"
    echo "  # 1) Locate the exact .condarc from 'show-sources' above and remove these keys if present:"
    echo "  #    - default_channels"
    echo "  #    - custom_channels"
    echo "  #    - custom_multichannels"
    echo "  #    - channels: [defaults]"
    echo "  # 2) Keep only conda-forge / your mirror, and strict priority:"
    echo "  $conda_bin config --set channel_priority strict"
    echo "  $conda_bin config --remove channels defaults 2>/dev/null || true"
    echo "  $conda_bin config --add channels conda-forge"
    echo "  # Optional (org policy): avoid conda.anaconda.org entirely by setting channel_alias to a mirror:"
    echo "  # ALLOW_ANACONDA_ORG=0 $conda_bin config --set channel_alias https://<your-mirror-domain>/anaconda/cloud"
    echo
    info "Re-check commands:"
    echo "  $conda_bin config --show | egrep -n 'channels:|defaults|pkgs/(main|r)|channel_alias|default_channels:|custom_channels:|custom_multichannels:'"
    echo "  $conda_bin config --show-sources"
  fi
}

# ===== Optional: scan exported env YAMLs for defaults =====
scan_yml() {
  local dir="$1"
  [[ -n "$dir" ]] || return 0
  [[ -d "$dir" ]] || { warn "YML scan dir not found: $dir"; return 0; }

  hr
  info "Scan exported YAMLs for 'defaults': $dir"
  hr

  local hits
  hits="$(grep -RIn --include '*.yml' --include '*.yaml' -E '^\s*-\s*defaults\s*$' "$dir" 2>/dev/null || true)"
  if [[ -z "$hits" ]]; then
    ok "No YAML references to 'defaults' found."
  else
    risk "HIGH-RISK: exported YAML(s) reference 'defaults' (can recreate risky repos on env create)."
    echo "$hits" | sed 's/^/  /'
    HIGH_RISK_FOUND=1
  fi
}

# ===== Optional: just print migration suggestion (no execution) =====
print_migration_hint() {
  if [[ -x "$MINICONDA_CONDA" ]]; then
    hr
    info "Miniconda detected: $MINICONDA_CONDA"
    echo "Migration script (open-source):"
    echo "  curl -fsSL https://raw.githubusercontent.com/luoluoter/miniconda3-to-miniforge3/main/migrate_to_miniforge.sh | bash"
    hr
  fi
}

# ===== Main =====
check_user_count
check_conda "PATH" "current(PATH)"
check_conda "$MINIFORGE_CONDA" "miniforge(default path)"
check_conda "$MINICONDA_CONDA" "miniconda(default path)"
scan_yml "$SCAN_YML_DIR"
print_migration_hint

hr
if [[ "$HIGH_RISK_FOUND" == "0" ]]; then
  if [[ "$WARN_FOUND" == "0" ]]; then
    ok "Overall status: PASS (no high-risk signals)"
    exit 0
  else
    warn "Overall status: PASS with WARN (policy-dependent items present)"
    exit 0
  fi
else
  risk "Overall status: HIGH-RISK detected (defaults/pkgs/main|pkgs/r present)"
  if [[ "$STRICT_EXIT" == "1" ]]; then
    exit 2
  else
    exit 0
  fi
fi
