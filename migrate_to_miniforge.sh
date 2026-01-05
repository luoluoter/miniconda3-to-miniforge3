#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Miniconda/Anaconda -> Miniforge3 migration (idempotent, safer)
# - Scheme A: export envs from Miniconda, recreate in Miniforge
# - Compliance: enforce conda-forge only; check configs/sources for risky endpoints
# - Shell init: bash/zsh/fish if present
# - Optional safe removal: move Miniconda to backup after verification
# ------------------------------------------------------------
# Miniconda/Anaconda -> Miniforge3 迁移脚本（幂等、更安全）
# - 方案 A：从 Miniconda 导出环境，再在 Miniforge 中重建
# - 合规：强制仅使用 conda-forge；检查配置/来源并给出告警
# - Shell 初始化：如存在则支持 bash / zsh / fish
# - 可选安全移除：验证通过后，将 Miniconda 移动到备份目录（默认不删除）
# ============================================================

# ===== Config (override via env) =====
MINICONDA_DIR="${MINICONDA_DIR:-$HOME/miniconda3}"
MINIFORGE_DIR="${MINIFORGE_DIR:-$HOME/miniforge3}"

DO_MIGRATE_ENVS="${DO_MIGRATE_ENVS:-1}"          # 1 migrate envs, 0 skip
CLEAN_RC="${CLEAN_RC:-1}"                        # 1 clean old conda init blocks, 0 skip
AUTO_ACTIVATE_BASE="${AUTO_ACTIVATE_BASE:-false}"
MIGRATE_MODE="${MIGRATE_MODE:-all}"              # all|selected
MIGRATE_ENVS="${MIGRATE_ENVS:-}"                 # comma/space list when MIGRATE_MODE=selected
CLEANUP_FAILED_ENVS="${CLEANUP_FAILED_ENVS:-0}"  # 1 remove failed envs, 0 keep
DEBUG="${DEBUG:-0}"                              # 1 enable extra debug logs

# Optional safe removal
REMOVE_MINICONDA="${REMOVE_MINICONDA:-1}"        # 1 move miniconda away after verification, 0 keep
MINICONDA_BACKUP_PARENT="${MINICONDA_BACKUP_PARENT:-$HOME}"
# After moving Miniconda to backup, whether to delete that backup directory:
# - unset: prompt in interactive shells; keep in non-interactive shells
# - 1: delete without prompting
# - 0: keep without prompting
MINICONDA_DELETE_BACKUP="${MINICONDA_DELETE_BACKUP:-}"

# Export dir persists across runs (idempotent & debuggable)
# Default is set after BACKUP_DIR is resolved.
EXPORT_DIR="${EXPORT_DIR:-}"

BACKUP_TS="$(date +%Y%m%d_%H%M%S)"

# Centralized backup directory for files this script edits (rc files, exported YAMLs, etc.).
# Default (if BACKUP_DIR is unset): under MINICONDA_BACKUP_PARENT/conda_migrate_backups/<timestamp> (or override via -B/--backup-dir).
BACKUP_DIR="${BACKUP_DIR:-}"

# Enforce channel compliance automatically for Miniforge:
# - 1: auto-fix risky channels in Miniforge config (recommended)
# - 0: only warn
ENFORCE_COMPLIANCE="${ENFORCE_COMPLIANCE:-1}"

# Deep-clean hidden defaults mappings (default_channels/custom_channels/custom_multichannels)
# - 1: remove repo.anaconda.com defaults mappings from Miniforge config (recommended)
# - 0: keep current behavior (only clean channels list)
ENFORCE_DEEP_COMPLIANCE="${ENFORCE_DEEP_COMPLIANCE:-1}"

# If your org forbids ANY anaconda.org domains, set this to your mirror alias.
# Example: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
CHANNEL_ALIAS_OVERRIDE="${CHANNEL_ALIAS_OVERRIDE:-}"
ALLOW_ANACONDA_ORG="${ALLOW_ANACONDA_ORG:-1}"  # 1 allow conda.anaconda.org (default), 0 warn

# Compliance check options (policy-only, optional)
STRICT_EXIT="${STRICT_EXIT:-0}"   # 1 => exit nonzero if post-migration high-risk remains
USER_LIMIT="${USER_LIMIT:-200}"   # org size threshold (policy-dependent)
USER_COUNT="${USER_COUNT:-}"      # set externally if desired (e.g., LDAP/SSO count)
CHECK_PATH_CONDA="${CHECK_PATH_CONDA:-1}"  # 1 => also check conda on PATH
SCAN_YML_DIR="${SCAN_YML_DIR:-}"  # optional: extra directory to scan for exported YAMLs

# Auto-detect conda installs when *_DIR is invalid:
# - 1: try to detect Miniconda base dir automatically (recommended)
# - 0: require MINICONDA_DIR to be correct
AUTO_DETECT_CONDA_DIRS="${AUTO_DETECT_CONDA_DIRS:-1}"

# If Miniconda is present but "conda" is not runnable (moved/broken prefix),
# whether to proceed with removing it anyway:
# - unset: prompt in interactive shells; abort in non-interactive shells
# - 1: proceed without verification
# - 0: abort removal
FORCE_REMOVE_MINICONDA_BROKEN="${FORCE_REMOVE_MINICONDA_BROKEN:-}"

# Disk space checks:
# - MINIFORGE_MIN_FREE_GB: minimum free space required on Miniforge target filesystem for install/env operations
# - MINICONDA_BACKUP_MARGIN_GB: extra headroom when backing up Miniconda across filesystems
MINIFORGE_MIN_FREE_GB="${MINIFORGE_MIN_FREE_GB:-5}"
MINICONDA_BACKUP_MARGIN_GB="${MINICONDA_BACKUP_MARGIN_GB:-1}"

# Whether to sanitize exported YAML backups when risky channels are detected:
# - unset: prompt in interactive shells; skip in non-interactive shells
# - 1: sanitize all exported YAMLs under EXPORT_DIR without prompting
# - 0: never sanitize exported YAMLs
SANITIZE_EXPORTED_YMLS="${SANITIZE_EXPORTED_YMLS:-}"

# ===== Helpers =====
log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }
debug() { [[ "$DEBUG" == "1" ]] && echo -e "\033[1;34m[dbg]\033[0m $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

PYTHON_BIN="${PYTHON_BIN:-}"

resolve_python_bin() {
  if [[ -n "${PYTHON_BIN:-}" ]]; then
    if [[ "$PYTHON_BIN" == /* ]]; then
      [[ -x "$PYTHON_BIN" ]] && return 0
    else
      have "$PYTHON_BIN" && return 0
    fi
  fi

  if [[ -x "$MINIFORGE_DIR/bin/python" ]]; then
    PYTHON_BIN="$MINIFORGE_DIR/bin/python"
    return 0
  fi
  if have python3; then
    PYTHON_BIN="python3"
    return 0
  fi
  if have python; then
    PYTHON_BIN="python"
    return 0
  fi
  return 1
}

require_python() {
  resolve_python_bin || die "python is required for this step (set PYTHON_BIN or install python3)."
}

nearest_existing_parent() {
  local p="$1"
  while [[ -n "$p" && "$p" != "/" && ! -e "$p" ]]; do
    p="$(dirname "$p")"
  done
  echo "$p"
}

fs_dev_id() {
  local p="$1"
  p="$(nearest_existing_parent "$p")"
  [[ -e "$p" ]] || return 1
  stat -c '%d' "$p" 2>/dev/null || true
}

fs_avail_kb() {
  local p="$1"
  p="$(nearest_existing_parent "$p")"
  [[ -e "$p" ]] || return 1
  df -Pk "$p" | awk 'NR==2{print $4}'
}

dir_size_kb() {
  local p="$1"
  [[ -d "$p" ]] || return 1
  du -sk "$p" | awk '{print $1}'
}

kb_to_gb() {
  awk -v kb="${1:-0}" 'BEGIN{printf "%.2f", kb/1024/1024}'
}

preflight_disk_space_checks() {
  # Miniforge: ensure there is a reasonable amount of free space before install/env operations.
  local miniforge_avail_kb miniforge_need_kb
  miniforge_avail_kb="$(fs_avail_kb "$MINIFORGE_DIR")"
  miniforge_need_kb="$(( MINIFORGE_MIN_FREE_GB * 1024 * 1024 ))"
  if [[ -n "${miniforge_avail_kb:-}" && "$miniforge_avail_kb" -lt "$miniforge_need_kb" ]]; then
    die "Not enough free space for Miniforge target ($MINIFORGE_DIR): need >= ${MINIFORGE_MIN_FREE_GB}GB, have $(kb_to_gb "$miniforge_avail_kb")GB"
  fi

  # Miniconda backup: only needs extra space if backup parent is on a different filesystem (mv becomes copy+delete).
  if [[ "$REMOVE_MINICONDA" == "1" && -d "$MINICONDA_DIR" ]]; then
    local src_dev dst_dev
    src_dev="$(fs_dev_id "$MINICONDA_DIR")"
    dst_dev="$(fs_dev_id "$MINICONDA_BACKUP_PARENT")"
    if [[ -n "${src_dev:-}" && -n "${dst_dev:-}" && "$src_dev" != "$dst_dev" ]]; then
      local size_kb avail_kb margin_kb need_kb
      size_kb="$(dir_size_kb "$MINICONDA_DIR")"
      avail_kb="$(fs_avail_kb "$MINICONDA_BACKUP_PARENT")"
      margin_kb="$(( MINICONDA_BACKUP_MARGIN_GB * 1024 * 1024 ))"
      need_kb="$(( size_kb + margin_kb ))"
      if [[ -n "${avail_kb:-}" && "$avail_kb" -lt "$need_kb" ]]; then
        die "Not enough free space to backup Miniconda across filesystems.\n  MINICONDA_DIR=$MINICONDA_DIR (size $(kb_to_gb "$size_kb")GB)\n  MINICONDA_BACKUP_PARENT=$MINICONDA_BACKUP_PARENT (free $(kb_to_gb "$avail_kb")GB)\n  Need >= $(kb_to_gb "$need_kb")GB (includes ${MINICONDA_BACKUP_MARGIN_GB}GB margin)."
      fi
      warn "Miniconda backup parent is on a different filesystem; moving may copy data (needs space)."
    fi
  fi
}

miniforge_can_run_conda() {
  local conda_bin="$MINIFORGE_DIR/bin/conda"
  if [[ -x "$conda_bin" ]] && "$conda_bin" --version >/dev/null 2>&1; then
    return 0
  fi

  local py="$MINIFORGE_DIR/bin/python"
  [[ -x "$py" ]] || return 1
  "$py" -m conda --version >/dev/null 2>&1
}

miniforge_conda() {
  # Compatibility wrapper: if conda shebang is broken (moved prefix),
  # fall back to: $MINIFORGE_DIR/bin/python -m conda ...
  local conda_bin="$MINIFORGE_DIR/bin/conda"
  if [[ -x "$conda_bin" ]]; then
    local out=""
    if out="$("$conda_bin" --version 2>&1)"; then
      "$conda_bin" "$@"
      return $?
    fi
    if echo "$out" | grep -qi "bad interpreter"; then
      warn "Miniforge conda launcher looks moved/broken; falling back to 'python -m conda'."
    fi
  fi

  local py="$MINIFORGE_DIR/bin/python"
  [[ -x "$py" ]] || die "Miniforge appears broken: missing $py (reinstall Miniforge at $MINIFORGE_DIR)"
  "$py" -m conda "$@"
}

miniconda_can_run_conda() {
  local conda_bin="$MINICONDA_DIR/bin/conda"
  if [[ -x "$conda_bin" ]] && "$conda_bin" --version >/dev/null 2>&1; then
    return 0
  fi

  local py="$MINICONDA_DIR/bin/python"
  [[ -x "$py" ]] || return 1
  "$py" -m conda --version >/dev/null 2>&1
}

miniconda_conda() {
  # Compatibility wrapper for moved/broken Miniconda prefix.
  local conda_bin="$MINICONDA_DIR/bin/conda"
  if [[ -x "$conda_bin" ]]; then
    local out=""
    if out="$("$conda_bin" --version 2>&1)"; then
      "$conda_bin" "$@"
      return $?
    fi
    if echo "$out" | grep -qi "bad interpreter"; then
      warn "Miniconda conda launcher looks moved/broken; falling back to 'python -m conda'."
    fi
  fi

  local py="$MINICONDA_DIR/bin/python"
  [[ -x "$py" ]] || die "Miniconda appears broken: missing $py (set MINICONDA_DIR correctly or reinstall)"
  "$py" -m conda "$@"
}

detect_conda_base_dir() {
  # Print conda base directory for a given conda executable, else empty.
  local conda_bin="$1"
  [[ -x "$conda_bin" ]] || return 1
  "$conda_bin" info --base 2>/dev/null || true
}

path_looks_like_miniforge() {
  local p="${1:-}"
  local lp
  lp="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == *miniforge* || "$lp" == *mambaforge* ]]
}

auto_detect_miniforge_dir() {
  # Best-effort detection: prefer known locations, then conda on PATH.
  local candidate base
  for candidate in \
    "$MINIFORGE_DIR" \
    "$HOME/miniforge3" \
    "$HOME/miniforge" \
    "$HOME/mambaforge" \
    "/opt/miniforge3" \
    "/opt/miniforge" \
    "/opt/mambaforge"
  do
    if [[ -x "$candidate/bin/conda" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  if have conda; then
    base="$(detect_conda_base_dir "$(command -v conda)")"
    if [[ -n "$base" && -x "$base/bin/conda" ]] && path_looks_like_miniforge "$base"; then
      echo "$base"
      return 0
    fi
  fi

  return 1
}

auto_detect_miniconda_dir() {
  # Best-effort detection: prefer known locations, then conda on PATH.
  local candidate base
  for candidate in \
    "$MINICONDA_DIR" \
    "$HOME/miniconda3" \
    "$HOME/anaconda3" \
    "/opt/miniconda3" \
    "/opt/anaconda3"
  do
    if [[ -x "$candidate/bin/conda" && "$candidate" != "$MINIFORGE_DIR" ]] && ! path_looks_like_miniforge "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  if have conda; then
    base="$(detect_conda_base_dir "$(command -v conda)")"
    if [[ -n "$base" && -x "$base/bin/conda" && "$base" != "$MINIFORGE_DIR" ]] && ! path_looks_like_miniforge "$base"; then
      echo "$base"
      return 0
    fi
  fi

  return 1
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--help|-h] [-p DIR|--prefix DIR] [-m DIR|--miniconda DIR] [-b DIR|--backup-parent DIR] [-B DIR|--backup-dir DIR] [--env NAME|--envs LIST]

This script is mainly configured via environment variables.
脚本主要通过环境变量配置（可在运行前临时设置）。

Options:
  -h, --help            Show this help
  -p, --prefix DIR      Install/use Miniforge at DIR (overrides MINIFORGE_DIR)
  -m, --miniconda DIR   Use Miniconda at DIR (overrides MINICONDA_DIR)
  -b, --backup-parent DIR  Parent directory to place Miniconda backup (overrides MINICONDA_BACKUP_PARENT)
  -B, --backup-dir DIR  Directory to store script backups (rc/yml/etc) (overrides BACKUP_DIR)
  -e, --env NAME        Migrate only selected env (repeatable; sets MIGRATE_MODE=selected)
      --envs LIST       Comma/space-separated env list (sets MIGRATE_MODE=selected)

Key environment variables (defaults shown):
  MINICONDA_DIR=$MINICONDA_DIR
  MINIFORGE_DIR=$MINIFORGE_DIR
  EXPORT_DIR=${EXPORT_DIR:-"<default: BACKUP_DIR/envs>"}
  BACKUP_DIR=${BACKUP_DIR:-"<default: MINICONDA_BACKUP_PARENT/conda_migrate_backups/<timestamp> >"}

  DO_MIGRATE_ENVS=$DO_MIGRATE_ENVS          # 1 migrate envs, 0 skip
  MIGRATE_MODE=$MIGRATE_MODE                # all or selected
  MIGRATE_ENVS=${MIGRATE_ENVS:-"<unset>"}   # comma/space list when MIGRATE_MODE=selected
  CLEANUP_FAILED_ENVS=$CLEANUP_FAILED_ENVS  # 1 remove failed envs, 0 keep
  DEBUG=$DEBUG                              # 1 enable extra debug logs
  CLEAN_RC=$CLEAN_RC                        # 1 clean conda init blocks, 0 skip
  AUTO_ACTIVATE_BASE=$AUTO_ACTIVATE_BASE    # true/false for Miniforge

  REMOVE_MINICONDA=$REMOVE_MINICONDA        # 1 move miniconda after verification, 0 keep
  MINICONDA_BACKUP_PARENT=$MINICONDA_BACKUP_PARENT
  MINICONDA_DELETE_BACKUP=${MINICONDA_DELETE_BACKUP:-"<prompt if interactive>"}  # 1 delete, 0 keep, unset prompt/keep
  SANITIZE_EXPORTED_YMLS=${SANITIZE_EXPORTED_YMLS:-"<prompt if interactive>"}    # 1 sanitize, 0 skip, unset prompt/skip
  ENFORCE_COMPLIANCE=$ENFORCE_COMPLIANCE                                        # 1 auto-fix Miniforge, 0 warn only
  ENFORCE_DEEP_COMPLIANCE=$ENFORCE_DEEP_COMPLIANCE                              # 1 clean defaults mappings, 0 skip
  ALLOW_ANACONDA_ORG=$ALLOW_ANACONDA_ORG                                        # 1 allow conda.anaconda.org, 0 warn
  CHANNEL_ALIAS_OVERRIDE=${CHANNEL_ALIAS_OVERRIDE:-"<unset>"}                   # set to mirror if org forbids anaconda.org
  STRICT_EXIT=$STRICT_EXIT                                                      # 1 exit nonzero if post-migration still risky
  USER_LIMIT=$USER_LIMIT                                                        # org size threshold (policy-only)
  USER_COUNT=${USER_COUNT:-"<unset>"}                                           # set externally if you want to check
  CHECK_PATH_CONDA=$CHECK_PATH_CONDA                                            # 1 also check conda on PATH
  SCAN_YML_DIR=${SCAN_YML_DIR:-"<unset>"}                                       # extra YAML scan dir
  PYTHON_BIN=${PYTHON_BIN:-"<auto>"}                                            # python3/python fallback
  AUTO_DETECT_CONDA_DIRS=$AUTO_DETECT_CONDA_DIRS                                # 1 auto-detect dirs, 0 strict
  FORCE_REMOVE_MINICONDA_BROKEN=${FORCE_REMOVE_MINICONDA_BROKEN:-"<prompt if interactive>"}  # 1 proceed, 0 abort, unset prompt/abort
  MINIFORGE_MIN_FREE_GB=$MINIFORGE_MIN_FREE_GB                                  # minimum free space for Miniforge target
  MINICONDA_BACKUP_MARGIN_GB=$MINICONDA_BACKUP_MARGIN_GB                        # extra headroom when backup crosses filesystems

Examples:
  # Just run with defaults
  $0

  # Install/use Miniforge at a custom location
  $0 -p /your/target/path

  # Use a custom Miniconda install location
  $0 -m /your/miniconda3

  # Place Miniconda backup under a custom parent directory
  $0 -b /your/backup/parent

  # Store this script's backups in one directory
  $0 -B /your/backup/dir

  # Keep Miniconda (do not move/delete)
  REMOVE_MINICONDA=0 $0

  # Move Miniconda then auto-delete backup without prompting
  MINICONDA_DELETE_BACKUP=1 $0

  # If risky channels found in exported YAML backups, sanitize them too
  SANITIZE_EXPORTED_YMLS=1 $0
EOF
}

# ===== Detect OS / ARCH (for Miniforge installer) =====
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) OS_TAG="MacOSX" ;;
  Linux)  OS_TAG="Linux" ;;
  *) die "Unsupported OS: $OS" ;;
esac

case "$ARCH" in
  x86_64) ARCH_TAG="x86_64" ;;
  arm64)  ARCH_TAG="arm64" ;;     # macOS arm64
  aarch64) ARCH_TAG="aarch64" ;;  # Linux arm
  *) die "Unsupported ARCH: $ARCH" ;;
esac

INSTALLER_NAME="Miniforge3-${OS_TAG}-${ARCH_TAG}.sh"
INSTALLER_URL="https://github.com/conda-forge/miniforge/releases/latest/download/${INSTALLER_NAME}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ===== RC files =====
RC_ZSH="$HOME/.zshrc"
RC_BASHRC="$HOME/.bashrc"
RC_BASHPROFILE="$HOME/.bash_profile"
RC_PROFILE="$HOME/.profile"

FISH_CONF_DIR="$HOME/.config/fish"
FISH_CONF="$FISH_CONF_DIR/config.fish"

# ===== Backup utils =====
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR" >/dev/null 2>&1 || true

  local dest=""
  if [[ "$f" == /* ]]; then
    dest="${BACKUP_DIR}${f}"
  else
    dest="${BACKUP_DIR}/$f"
  fi
  dest="${dest}.bak"

  mkdir -p "$(dirname "$dest")"
  [[ -f "$dest" ]] || cp -a "$f" "$dest"
  log "Backup: $f -> $dest"
}

# ===== RC cleanup =====
clean_bashish_rc_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  backup_file "$f"

  local out="${TMP_DIR}/$(basename "$f").out"

  awk '
    BEGIN {skip=0}
    />>> conda initialize >>>/ {skip=1; next}
    /<<< conda initialize <<</ {skip=0; next}
    skip==0 {print}
  ' "$f" > "$out"

  mv "$out" "$f"

  log "Cleaned: $f"
}

clean_fish_conf() {
  mkdir -p "$FISH_CONF_DIR"
  [[ -f "$FISH_CONF" ]] || touch "$FISH_CONF"
  backup_file "$FISH_CONF"

  if ! resolve_python_bin; then
    warn "python not found; skipping fish config cleanup."
    return 0
  fi
  "$PYTHON_BIN" - <<'PY'
import os, re
p=os.path.expanduser("~/.config/fish/config.fish")
s=open(p,"r",encoding="utf-8",errors="ignore").read()
s=re.sub(r"(?s)# >>> conda initialize >>>.*?# <<< conda initialize <<<\n?","",s)
open(p,"w",encoding="utf-8").write(s.rstrip()+"\n")
PY

  log "Cleaned: $FISH_CONF"
}

# ===== Compliance helpers =====
COMPLIANCE_POST_HIGH_RISK=0
COMPLIANCE_WARN_FOUND=0

extract_conda_block() {
  local text="$1"
  local key="$2"
  echo "$text" | awk -v k="$key" '
    BEGIN{p=0}
    $0 ~ "^"k"$" {p=1; print; next}
    p==1 && $0 ~ "^[^[:space:]].*:$" {exit}
    p==1 {print}
  '
}

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

conda_config_show() {
  local conda_bin="$1"
  if [[ "$conda_bin" == "$MINIFORGE_DIR/bin/conda" ]]; then
    miniforge_conda config --show 2>/dev/null || true
  elif [[ "$conda_bin" == "$MINICONDA_DIR/bin/conda" ]]; then
    if miniconda_can_run_conda; then
      miniconda_conda config --show 2>/dev/null || true
    else
      return 1
    fi
  else
    "$conda_bin" config --show 2>/dev/null || true
  fi
}

conda_config_sources() {
  local conda_bin="$1"
  if [[ "$conda_bin" == "$MINIFORGE_DIR/bin/conda" ]]; then
    miniforge_conda config --show-sources 2>/dev/null || true
  elif [[ "$conda_bin" == "$MINICONDA_DIR/bin/conda" ]]; then
    if miniconda_can_run_conda; then
      miniconda_conda config --show-sources 2>/dev/null || true
    else
      return 1
    fi
  else
    "$conda_bin" config --show-sources 2>/dev/null || true
  fi
}

check_user_count() {
  log "Compliance check: organization size (policy-only)"
  log "USER_LIMIT=$USER_LIMIT (set USER_COUNT if you want to check)"
  if [[ -z "${USER_COUNT}" ]]; then
    warn "USER_COUNT not provided -> skip (policy-only; conda cannot infer org size)."
    return 0
  fi
  if ! [[ "${USER_COUNT}" =~ ^[0-9]+$ ]]; then
    warn "USER_COUNT is not a number: ${USER_COUNT} -> skip"
    return 0
  fi
  if [[ "${USER_COUNT}" -gt "${USER_LIMIT}" ]]; then
    warn "USER_COUNT exceeds ${USER_LIMIT}: ${USER_COUNT} > ${USER_LIMIT} (policy attention)."
    COMPLIANCE_WARN_FOUND=1
  else
    log "USER_COUNT within limit: ${USER_COUNT} <= ${USER_LIMIT}"
  fi
}

check_conda_compliance() {
  local input_bin="$1"
  local label="$2"
  local stage="${3:-pre}"
  local conda_bin cfg src

  conda_bin="$(resolve_conda_bin "$input_bin")"
  if [[ -z "$conda_bin" ]]; then
    warn "($label) conda not found"
    return 0
  fi
  if [[ ! -x "$conda_bin" ]]; then
    warn "($label) conda not executable: $conda_bin"
    return 0
  fi

  log "Compliance check ($label)"
  log "conda path: $conda_bin"

  cfg="$(conda_config_show "$conda_bin" || true)"
  src="$(conda_config_sources "$conda_bin" || true)"
  if [[ -z "$cfg" ]]; then
    warn "($label) conda config unavailable (conda may be broken or moved)."
    return 0
  fi

  local has_defaults_in_channels=0
  local has_repo_anaconda_pkgs=0
  local alias_is_anaconda_org=0
  local alias_line=""
  local has_anaconda_org=0

  echo "$cfg" | awk '
    BEGIN{p=0}
    /^channels:$/ {p=1; next}
    p==1 && /^[^[:space:]].*:$/{exit}
    p==1 {print}
  ' | grep -Eiq '^\s*-\s*defaults\s*$' && has_defaults_in_channels=1

  echo "$cfg" | grep -Eiq 'repo\.anaconda\.com/pkgs/(main|r)|/anaconda/pkgs/(main|r)|pkgs/(main|r)' && has_repo_anaconda_pkgs=1

  alias_line="$(echo "$cfg" | grep -E '^channel_alias:\s*' || true)"
  echo "$alias_line" | grep -Eiq 'channel_alias:\s*https?://conda\.anaconda\.org' && alias_is_anaconda_org=1

  echo "$cfg" | grep -Eiq 'conda\.anaconda\.org' && has_anaconda_org=1

  if [[ "$has_defaults_in_channels" == "1" ]]; then
    warn "($label) HIGH-RISK: 'defaults' is configured in channels."
    echo "Evidence:"
    extract_conda_block "$cfg" "channels:" | sed 's/^/  /'
  fi

  if [[ "$has_repo_anaconda_pkgs" == "1" ]]; then
    warn "($label) HIGH-RISK: pkgs/main or pkgs/r endpoints present in config."
    echo "Evidence:"
    extract_conda_block "$cfg" "default_channels:" | sed 's/^/  /'
    extract_conda_block "$cfg" "custom_channels:" | sed 's/^/  /'
    extract_conda_block "$cfg" "custom_multichannels:" | sed 's/^/  /'
  fi

  if [[ "$alias_is_anaconda_org" == "1" && "$ALLOW_ANACONDA_ORG" == "0" ]]; then
    warn "($label) WARN: channel_alias points to conda.anaconda.org and ALLOW_ANACONDA_ORG=0."
    echo "Evidence:"
    echo "  ${alias_line}"
    COMPLIANCE_WARN_FOUND=1
  fi

  if [[ "$has_defaults_in_channels" == "0" && "$has_repo_anaconda_pkgs" == "0" ]]; then
    if [[ "$alias_is_anaconda_org" == "1" && "$ALLOW_ANACONDA_ORG" == "0" ]]; then
      log "($label) PASS with WARN (policy-dependent alias)."
    else
      log "($label) PASS: no defaults and no pkgs/main|pkgs/r endpoints."
    fi
  else
    if [[ "$stage" == "post" ]]; then
      COMPLIANCE_POST_HIGH_RISK=1
    fi
  fi

  if [[ "$has_defaults_in_channels" == "1" || "$has_repo_anaconda_pkgs" == "1" || ( "$alias_is_anaconda_org" == "1" && "$ALLOW_ANACONDA_ORG" == "0" ) ]]; then
    if [[ -n "$src" ]]; then
      echo
      log "Config sources (where settings come from):"
      echo "$src" | sed 's/^/  /'
    fi
  fi

  if [[ "$ALLOW_ANACONDA_ORG" == "0" && "$has_anaconda_org" == "1" && "$alias_is_anaconda_org" == "0" ]]; then
    warn "($label) WARN: conda.anaconda.org present in config while ALLOW_ANACONDA_ORG=0."
    COMPLIANCE_WARN_FOUND=1
  fi
}

deep_clean_miniforge_defaults_mappings() {
  # Remove hidden defaults mappings that may still point to repo.anaconda.com.
  # Idempotent: safe to run multiple times.
  miniforge_can_run_conda || return 1

  miniforge_conda config --remove-key default_channels >/dev/null 2>&1 || true
  miniforge_conda config --remove-key custom_channels >/dev/null 2>&1 || true
  miniforge_conda config --remove-key custom_multichannels >/dev/null 2>&1 || true

  local alias="${CHANNEL_ALIAS_OVERRIDE:-https://conda.anaconda.org}"
  alias="${alias%/}"
  local safe_default="${alias}/conda-forge"
  local condarc="${CONDARC:-$HOME/.condarc}"

  backup_file "$condarc"

  require_python
  "$PYTHON_BIN" - "$condarc" "$safe_default" <<'PY'
import pathlib, re, sys

condarc = pathlib.Path(sys.argv[1]).expanduser()
safe = sys.argv[2]
text = ""
if condarc.exists():
    text = condarc.read_text(encoding="utf-8", errors="ignore")

def strip_key_block(s, key):
    # Remove both block-style and inline-style definitions.
    block = re.compile(r"(?ms)^%s:\s*\n(?:^[ \t].*\n)*" % re.escape(key))
    inline = re.compile(r"(?m)^%s:.*\n" % re.escape(key))
    s = block.sub("", s)
    s = inline.sub("", s)
    return s

for k in ("default_channels", "custom_channels", "custom_multichannels"):
    text = strip_key_block(text, k)

text = text.rstrip()
if text:
    text += "\n"

safe_block = (
    "default_channels:\n"
    f"  - {safe}\n"
    "custom_channels: {}\n"
    "custom_multichannels:\n"
    "  defaults:\n"
    f"    - {safe}\n"
)

text += safe_block + "\n"
condarc.parent.mkdir(parents=True, exist_ok=True)
condarc.write_text(text, encoding="utf-8")
PY

  if [[ -n "${CHANNEL_ALIAS_OVERRIDE}" ]]; then
    miniforge_conda config --set channel_alias "${CHANNEL_ALIAS_OVERRIDE}" >/dev/null 2>&1 || true
  fi
}

enforce_conda_channels_compliance() {
  # Enforce: conda-forge only, strict channel priority, remove common risky sources.
  local conda_bin="$1"
  [[ -x "$conda_bin" ]] || return 1

  if [[ "$conda_bin" == "$MINIFORGE_DIR/bin/conda" ]]; then
    miniforge_conda config --set channel_priority strict >/dev/null 2>&1 || true
  else
    "$conda_bin" config --set channel_priority strict >/dev/null 2>&1 || true
  fi

  # Remove defaults + common risky endpoints (idempotent)
  if [[ "$conda_bin" == "$MINIFORGE_DIR/bin/conda" ]]; then
    miniforge_conda config --remove channels defaults >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/main >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/r >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/free >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://conda.anaconda.org/pkgs/main >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://conda.anaconda.org/pkgs/r >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://conda.anaconda.org/pkgs/free >/dev/null 2>&1 || true
  else
    "$conda_bin" config --remove channels defaults >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://repo.anaconda.com/pkgs/main >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://repo.anaconda.com/pkgs/r >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://repo.anaconda.com/pkgs/free >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://conda.anaconda.org/pkgs/main >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://conda.anaconda.org/pkgs/r >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://conda.anaconda.org/pkgs/free >/dev/null 2>&1 || true
  fi

  # Ensure conda-forge exists & is on top
  if [[ "$conda_bin" == "$MINIFORGE_DIR/bin/conda" ]]; then
    miniforge_conda config --remove channels conda-forge >/dev/null 2>&1 || true
    miniforge_conda config --add channels conda-forge >/dev/null 2>&1 || true
  else
    "$conda_bin" config --remove channels conda-forge >/dev/null 2>&1 || true
    "$conda_bin" config --add channels conda-forge >/dev/null 2>&1 || true
  fi
}

scan_exported_yml_for_risky_channels() {
  local dir="$1"
  [[ -d "$dir" ]] || { warn "YML scan skipped: not found $dir"; return 0; }

  log "Risk check: scanning env YAMLs under $dir"
  local hits
  hits="$(grep -RIn --include '*.yml' --include '*.yaml' -E \
    '(^|[[:space:]])defaults::|(^|[[:space:]])anaconda::|^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$|pkgs/(main|r)|repo\.anaconda\.com/pkgs/(main|r)|/anaconda/pkgs/(main|r)' \
    "$dir" 2>/dev/null || true)"

  if [[ -n "$hits" ]]; then
    warn "Found risky channel references in YAMLs:"
    echo "$hits"
    COMPLIANCE_WARN_FOUND=1
    warn "Note:"
    warn "  - These YAMLs may reflect past configs and contain non-compliant channels."
    warn "  - During migration, this script sanitizes each YAML before 'conda env create -f'."
    warn "  - If you (or CI) reuse these YAMLs directly, they could override your conda config."

    local do_sanitize=""
    case "${SANITIZE_EXPORTED_YMLS}" in
      1) do_sanitize="y" ;;
      0) do_sanitize="n" ;;
      "")
        if [[ -t 0 ]]; then
          read -r -p "Sanitize exported YAML backups now? (channels -> conda-forge only) [y/N]: " do_sanitize
        else
          warn "Non-interactive shell detected; not sanitizing exported YAMLs by default."
          warn "Set SANITIZE_EXPORTED_YMLS=1 to auto-sanitize, or sanitize manually later."
          do_sanitize="n"
        fi
        ;;
      *)
        warn "Invalid SANITIZE_EXPORTED_YMLS=${SANITIZE_EXPORTED_YMLS} (use 1/0 or unset); skipping sanitize."
        do_sanitize="n"
        ;;
    esac

    if [[ "$do_sanitize" =~ ^[Yy]$ ]]; then
      log "Sanitizing YAMLs under: $dir"
      local files failed=0
      files="$(printf '%s\n' "$hits" | awk -F: '{print $1}' | sort -u)"
      while IFS= read -r yml; do
        [[ -n "$yml" ]] || continue
        if ! sanitize_yml_channels_inplace "$yml"; then
          warn "sanitize failed: $yml (backup should be under: $BACKUP_DIR)"
          failed=1
        fi
      done <<< "$files"
      if [[ "$failed" == "1" ]]; then
        warn "Some exported YAMLs could not be fully sanitized; please inspect the warnings above."
      else
        log "Exported YAML backups sanitized."
      fi
    else
      log "Skipped sanitizing exported YAML backups."
    fi
  else
    log "No risky channel references found in YAML exports."
  fi
}

sanitize_yml_channels_inplace() {
  # Usage: sanitize_yml_channels_inplace /path/to/env.yml
  # - Replace any channels block with conda-forge only
  # - Idempotent (running multiple times yields same result)
  local yml="$1"
  [[ -f "$yml" ]] || { warn "sanitize: yml not found: $yml"; return 1; }

  # Backup (centralized)
  backup_file "$yml"

  require_python
  "$PYTHON_BIN" - "$yml" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8", errors="ignore")

  # Remove existing top-level channels (block or inline forms).
  s2 = re.sub(r"(?ms)^channels:\s*\n(?:\s*-\s*.*\n)+", "", s)
  s2 = re.sub(r"(?m)^channels:\s*\[[^\]]*\]\s*\n", "", s2)
  s2 = re.sub(r"(?m)^channels:\s*[^ \n].*\n", "", s2)
# Remove top-level prefix to avoid recreating env at old Miniconda path
s2 = re.sub(r"(?m)^prefix:\s*.*\n", "", s2)

clean = "channels:\n  - conda-forge\n"

# Keep common ordering: name first (if present), then channels
m = re.search(r"(?m)^name:\s*.*\n", s2)
if m:
  i = m.end()
  out = s2[:i] + clean + "\n" + s2[i:].lstrip()
else:
  out = clean + "\n" + s2.lstrip()

p.write_text(out, encoding="utf-8")
print("sanitized", p)
PY

  # Sanity: ensure no risky channel tokens remain anywhere in the YAML
  if grep -Eiq '(^|[[:space:]])defaults::|^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$|/anaconda/pkgs/(main|r)|pkgs/(main|r)|repo\.anaconda\.com/pkgs/(main|r)|(^|[[:space:]])anaconda::' "$yml"; then
    warn "sanitize: still found risky channel references in $yml"
    return 2
  fi
  return 0
}

# ===== Miniforge install/config =====
install_miniforge_if_needed() {
  if [[ -x "$MINIFORGE_DIR/bin/conda" || -x "$MINIFORGE_DIR/bin/python" ]]; then
    if miniforge_can_run_conda; then
      log "Miniforge already exists: $MINIFORGE_DIR (will still enforce strict conda-forge policy)"
      return
    fi
    warn "Miniforge detected at $MINIFORGE_DIR but it cannot run conda (possibly moved/broken prefix)."
    warn "Recommended: remove/backup this directory and reinstall Miniforge to this exact path."
    die "Miniforge is not usable at: $MINIFORGE_DIR"
    return
  fi
  have curl || die "curl is required to download Miniforge"
  local installer="$TMP_DIR/miniforge.sh"
  log "Downloading: $INSTALLER_URL"
  curl -fsSL "$INSTALLER_URL" -o "$installer"
  bash "$installer" -b -p "$MINIFORGE_DIR"
  log "Miniforge installed: $MINIFORGE_DIR"
}

configure_miniforge_channels() {
  miniforge_can_run_conda || die "conda not runnable under MINIFORGE_DIR=$MINIFORGE_DIR (broken/moved install?)"

  if [[ "$ENFORCE_COMPLIANCE" != "1" ]]; then
    warn "ENFORCE_COMPLIANCE=0: skipping channel enforcement; only setting auto_activate_base."
    miniforge_conda config --set auto_activate_base "$AUTO_ACTIVATE_BASE" >/dev/null 2>&1 || true
    return 0
  fi

  # Enforce legal-safe defaults
  miniforge_conda config --set channel_priority strict >/dev/null
  miniforge_conda config --remove channels defaults >/dev/null 2>&1 || true

  # Remove common risky channels / mirrors (idempotent)
  miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/main >/dev/null 2>&1 || true
  miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/r >/dev/null 2>&1 || true
  miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/free >/dev/null 2>&1 || true
  miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main >/dev/null 2>&1 || true
  miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r >/dev/null 2>&1 || true
  miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free >/dev/null 2>&1 || true

  # Ensure conda-forge exists & is on top
  miniforge_conda config --remove channels conda-forge >/dev/null 2>&1 || true
  miniforge_conda config --add channels conda-forge >/dev/null

  # Optional: avoid auto base activation
  miniforge_conda config --set auto_activate_base "$AUTO_ACTIVATE_BASE" >/dev/null 2>&1 || true

  if [[ "$ENFORCE_DEEP_COMPLIANCE" == "1" ]]; then
    deep_clean_miniforge_defaults_mappings || true
    log "Miniforge deep compliance applied (default/custom channels mappings cleaned)"
  fi

  log "Miniforge channels configured (conda-forge only, strict)"
}

# ===== Shell detection + init (idempotent) =====
user_shell_basename() { basename "${SHELL:-}"; }

should_init_bash() {
  have bash || return 1
  local sh; sh="$(user_shell_basename)"
  [[ "$sh" == "bash" ]] && return 0
  [[ -f "$RC_BASHRC" || -f "$RC_BASHPROFILE" || -f "$RC_PROFILE" ]] && return 0
  return 1
}
should_init_zsh() {
  have zsh || return 1
  local sh; sh="$(user_shell_basename)"
  [[ "$sh" == "zsh" ]] && return 0
  [[ -f "$RC_ZSH" ]] && return 0
  return 1
}
should_init_fish() {
  have fish || return 1
  local sh; sh="$(user_shell_basename)"
  [[ "$sh" == "fish" ]] && return 0
  [[ -f "$FISH_CONF" || -d "$FISH_CONF_DIR" ]] && return 0
  return 1
}

init_shells_idempotent() {
  miniforge_can_run_conda || die "conda not runnable under MINIFORGE_DIR=$MINIFORGE_DIR"

  if should_init_bash; then
    log "conda init bash"
    miniforge_conda init bash >/dev/null 2>&1 || true
  else
    log "Skip conda init bash"
  fi

  if should_init_zsh; then
    log "conda init zsh"
    miniforge_conda init zsh >/dev/null 2>&1 || true
  else
    log "Skip conda init zsh"
  fi

  if should_init_fish; then
    log "conda init fish"
    miniforge_conda init fish >/dev/null 2>&1 || true
  else
    log "Skip conda init fish"
  fi
}

# ===== ENV migration (Scheme A) =====
list_miniconda_env_names() {
  if ! miniconda_can_run_conda; then
    warn "Miniconda conda not runnable under MINICONDA_DIR=$MINICONDA_DIR (broken/moved install?)"
    return 1
  fi
  miniconda_conda env list | awk 'NF>=2 && $1 !~ /^#/ {print $1}' | sed 's/\*//g'
}

miniforge_has_env() {
  local envname="$1"
  miniforge_conda env list | awk 'NF>=1 {print $1}' | grep -qx "$envname"
}

miniconda_has_env() {
  local envname="$1"
  miniconda_conda env list | awk 'NF>=1 {print $1}' | grep -qx "$envname"
}

normalize_env_list() {
  local raw="$1"
  raw="${raw//,/ }"
  echo "$raw" | awk 'NF {for (i=1;i<=NF;i++) print $i}'
}

list_target_env_names() {
  case "$MIGRATE_MODE" in
    all)
      list_miniconda_env_names
      ;;
    selected)
      [[ -n "${MIGRATE_ENVS// }" ]] || die "MIGRATE_MODE=selected but MIGRATE_ENVS is empty."
      normalize_env_list "$MIGRATE_ENVS"
      ;;
    *)
      die "Unknown MIGRATE_MODE=$MIGRATE_MODE (use all|selected)"
      ;;
  esac
}

ensure_miniforge_channels_strict() {
  miniforge_conda config --set channel_priority strict >/dev/null 2>&1 || true
  miniforge_conda config --remove channels defaults >/dev/null 2>&1 || true
  miniforge_conda config --add channels conda-forge >/dev/null 2>&1 || true
}

debug_show_yml_summary() {
  local yml="$1"
  [[ -f "$yml" ]] || { debug "YML not found: $yml"; return 0; }
  local size_kb dep_count has_deps has_name has_channels
  size_kb="$(du -k "$yml" 2>/dev/null | awk '{print $1}')"
  has_name="$(grep -Eiq '^name:' "$yml" && echo 1 || echo 0)"
  has_channels="$(grep -Eiq '^channels:' "$yml" && echo 1 || echo 0)"
  has_deps="$(grep -Eiq '^dependencies:' "$yml" && echo 1 || echo 0)"
  dep_count="$(awk '
    BEGIN{p=0;c=0}
    /^dependencies:/ {p=1; next}
    p==1 && /^[^[:space:]].*:/ {p=0}
    p==1 && /^[[:space:]]*-[[:space:]]*/ {c++}
    END{print c}
  ' "$yml")"
  debug "YML summary: $yml (size=${size_kb:-?}KB name=$has_name channels=$has_channels dependencies=$has_deps dep_items=$dep_count)"
  debug "YML head (first 30 lines):"
  debug "-----"
  if [[ "$DEBUG" == "1" ]]; then
    sed -n '1,30p' "$yml"
  fi
  debug "-----"
}

export_env_yml_from_old_root() {
  local envname="$1"
  local yml="$2"
  mkdir -p "$(dirname "$yml")"
  if ! miniconda_conda env export -n "$envname" --no-builds > "$yml"; then
    warn "[$envname] env export failed (old root: $MINICONDA_DIR)."
    return 1
  fi
  debug_show_yml_summary "$yml"
  echo "$yml"
}

export_env_yml() {
  local envname="$1"
  local yml="$EXPORT_DIR/${envname}.environment.yml"
  export_env_yml_from_old_root "$envname" "$yml"
  log "Exported YAML: $yml" >&2
}

yml_has_dependency() {
  local yml="$1"
  local dep="$2"
  grep -Eiq "^[[:space:]]*-[[:space:]]*${dep}([[:space:]]|=|$)" "$yml"
}

verify_env_runnable() {
  local envname="$1"
  local yml="${2:-}"
  local out=""
  local rc=0

  out="$(miniforge_conda run -n "$envname" python -V 2>&1)" || rc=$?
  if [[ "$rc" != "0" ]]; then
    warn "[$envname] python -V failed: $out"
    if [[ "$rc" == "127" ]] || echo "$out" | grep -Eiq 'python: command not found|No such file|not found|execute\\(127\\)'; then
      return 2
    fi
    return 1
  fi

  if ! out="$(miniforge_conda run -n "$envname" python -c 'import sys; print(sys.executable)' 2>&1)"; then
    warn "[$envname] python sys.executable failed: $out"
    return 1
  fi

  if ! out="$(miniforge_conda run -n "$envname" python -c 'import pip' 2>&1)"; then
    warn "[$envname] import pip failed: $out"
    return 1
  fi

  if [[ -n "$yml" ]] && yml_has_dependency "$yml" "aiohttp"; then
    if ! out="$(miniforge_conda run -n "$envname" python -c 'import aiohttp; print(aiohttp.__version__)' 2>&1)"; then
      warn "[$envname] import aiohttp failed: $out"
      return 1
    fi
  fi

  return 0
}

remove_miniforge_env() {
  local envname="$1"
  miniforge_conda env remove -n "$envname" >/dev/null 2>&1 || true
}

recreate_env_in_miniforge() {
  local yml="$1"
  local envname="$2"
  local log_dir="$EXPORT_DIR/logs"
  mkdir -p "$log_dir"

  ensure_miniforge_channels_strict

  if miniforge_has_env "$envname"; then
    log "Verifying existing env: $envname"
    if verify_env_runnable "$envname" "$yml"; then
      log "Skip (already valid): $envname"
      return 0
    fi
    local existing_rc="$?"
    if [[ "$existing_rc" == "2" ]]; then
      warn "[$envname] python missing in existing env; attempting repair."
      if miniforge_conda install -n "$envname" -c conda-forge python -y >/dev/null 2>&1; then
        if verify_env_runnable "$envname" "$yml"; then
          log "Repaired: $envname"
          return 0
        fi
      fi
    fi
    warn "Existing env is not runnable; removing and recreating: $envname"
    remove_miniforge_env "$envname"
  fi

  log "Sanitizing YAML: $yml"
  if ! sanitize_yml_channels_inplace "$yml"; then
    warn "[$envname] YAML sanitize failed or left risky refs. Check: $yml"
    return 10
  fi
  debug_show_yml_summary "$yml"

  local create_log="$log_dir/create_${envname}.log"
  log "Creating in Miniforge: $envname"
  log "conda env create log: $create_log"
  if ! miniforge_conda env create -f "$yml" -n "$envname" -c conda-forge --override-channels 2>&1 | tee "$create_log"; then
    local rc="${PIPESTATUS[0]}"
    warn "[$envname] conda env create failed (exit $rc)."
    warn "  yml: $yml"
    warn "  log: $create_log"
    warn "  Tip: pinned versions/builds may not exist on conda-forge; relax pins or resolve conflicts."
    warn "  Last 80 log lines:"
    tail -n 80 "$create_log" || true
    if [[ "$CLEANUP_FAILED_ENVS" == "1" ]]; then
      warn "Removing failed env: $envname"
      remove_miniforge_env "$envname"
    fi
    return 20
  fi

  log "Verifying: $envname"
  if verify_env_runnable "$envname" "$yml"; then
    return 0
  fi

  local vrc="$?"
  if [[ "$vrc" == "2" ]]; then
    warn "[$envname] python missing; attempting repair by installing python."
    if miniforge_conda install -n "$envname" -c conda-forge python -y >/dev/null 2>&1; then
      if verify_env_runnable "$envname" "$yml"; then
        return 0
      fi
    fi
  fi

  warn "[$envname] verification failed; removing and recreating once."
  remove_miniforge_env "$envname"
  if ! miniforge_conda env create -f "$yml" -n "$envname" -c conda-forge --override-channels 2>&1 | tee "$create_log"; then
    warn "[$envname] recreate failed; see log: $create_log"
    if [[ "$CLEANUP_FAILED_ENVS" == "1" ]]; then
      warn "Removing failed env: $envname"
      remove_miniforge_env "$envname"
    fi
    return 30
  fi

  if verify_env_runnable "$envname" "$yml"; then
    return 0
  fi

  warn "[$envname] recreate completed but env is still not runnable."
  if [[ "$CLEANUP_FAILED_ENVS" == "1" ]]; then
    warn "Removing failed env: $envname"
    remove_miniforge_env "$envname"
  fi
  return 40
}

migrate_envs_scheme_a() {
  [[ "$DO_MIGRATE_ENVS" == "1" ]] || { warn "DO_MIGRATE_ENVS=0, skipping env migration"; return; }

  if [[ ! -d "$MINICONDA_DIR" ]]; then
    warn "Miniconda not found at $MINICONDA_DIR; skipping env migration."
    warn "If you still need to migrate envs, pass the correct path via -m/--miniconda or set MINICONDA_DIR."
    return 0
  fi

  miniconda_can_run_conda || die "Miniconda conda not runnable under $MINICONDA_DIR (broken/moved install?)"
  miniforge_can_run_conda || die "Miniforge conda not runnable under $MINIFORGE_DIR (broken/moved install?)"

  log "Migrating envs (Scheme A) from Miniconda -> Miniforge (idempotent)"
  log "Export dir: $EXPORT_DIR"
  log "MIGRATE_MODE=$MIGRATE_MODE"

  local yml envname envs
  envs="$(list_target_env_names)" || die "Failed to list Miniconda envs from $MINICONDA_DIR"
  while IFS= read -r envname; do
    [[ -n "$envname" ]] || continue
    [[ "$envname" == "base" ]] && continue

    if [[ "$MIGRATE_MODE" == "selected" ]] && ! miniconda_has_env "$envname"; then
      warn "Selected env not found in Miniconda; skipping: $envname"
      continue
    fi

    log "Exporting: $envname"
    if ! yml="$(export_env_yml "$envname")"; then
      warn "Failed to export: $envname"
      continue
    fi

    if recreate_env_in_miniforge "$yml" "$envname"; then
      log "OK: $envname"
    else
      warn "Failed: $envname (yml kept: $yml). Fix pins/packages then re-run script."
    fi
  done <<< "$envs"

  log "Env migration pass complete"
}

# ===== Safe Miniconda removal (move-to-backup after verification) =====
verify_all_envs_migrated() {
  local missing=0 envname envs
  envs="$(list_miniconda_env_names)" || return 1
  while IFS= read -r envname; do
    [[ -n "$envname" ]] || continue
    [[ "$envname" == "base" ]] && continue
    if ! miniforge_has_env "$envname"; then
      warn "Not migrated yet (missing in Miniforge): $envname"
      missing=1
      continue
    fi
    if ! verify_env_runnable "$envname"; then
      warn "Not migrated yet (not runnable in Miniforge): $envname"
      missing=1
    fi
  done <<< "$envs"
  return $missing
}

remove_miniconda_safely() {
  [[ "$REMOVE_MINICONDA" == "1" ]] || { log "REMOVE_MINICONDA=0, keep Miniconda"; return; }

  [[ -n "$MINICONDA_DIR" && -d "$MINICONDA_DIR" ]] || { warn "Miniconda dir not found, skip removal"; return; }
  [[ "$MINICONDA_DIR" != "$MINIFORGE_DIR" ]] || die "Safety stop: MINICONDA_DIR equals MINIFORGE_DIR"
  [[ "$MINICONDA_DIR" != "/" && "$MINICONDA_DIR" != "$HOME" ]] || die "Safety stop: dangerous MINICONDA_DIR=$MINICONDA_DIR"

  if ! miniconda_can_run_conda; then
    warn "Miniconda is present but 'conda' is not runnable (likely moved/broken prefix): $MINICONDA_DIR"
    warn "Cannot verify env migration from Miniconda env list."

    local proceed=""
    case "${FORCE_REMOVE_MINICONDA_BROKEN}" in
      1) proceed="y" ;;
      0) proceed="n" ;;
      "")
        if [[ -t 0 ]]; then
          read -r -p "Proceed to move/remove Miniconda anyway (without verification)? [y/N]: " proceed
        else
          die "Non-interactive shell: refusing to remove broken Miniconda without verification. Set FORCE_REMOVE_MINICONDA_BROKEN=1 to override."
        fi
        ;;
      *)
        warn "Invalid FORCE_REMOVE_MINICONDA_BROKEN=${FORCE_REMOVE_MINICONDA_BROKEN} (use 1/0 or unset); aborting removal."
        proceed="n"
        ;;
    esac

    [[ "$proceed" =~ ^[Yy]$ ]] || die "Abort removal due to non-runnable Miniconda. Fix MINICONDA_DIR or set FORCE_REMOVE_MINICONDA_BROKEN=1."
  else
    log "Verifying all envs migrated before removing Miniconda..."
    if ! verify_all_envs_migrated; then
      die "Abort removal: some envs are not present in Miniforge yet. Re-run migration / fix failed envs first."
    fi
  fi

  local backup_dir="${MINICONDA_BACKUP_PARENT}/miniconda3_backup_${BACKUP_TS}"
  mkdir -p "$MINICONDA_BACKUP_PARENT"
  log "All envs verified. Moving Miniconda to backup: $backup_dir"
  mv "$MINICONDA_DIR" "$backup_dir"

  log "Miniconda moved (not deleted yet): $backup_dir"

  local do_delete=""
  case "${MINICONDA_DELETE_BACKUP}" in
    1) do_delete="y" ;;
    0) do_delete="n" ;;
    "")
      if [[ -t 0 ]]; then
        read -r -p "Delete Miniconda backup now? (rm -rf) [$backup_dir] [y/N]: " do_delete
      else
        warn "Non-interactive shell detected; keeping backup dir: $backup_dir"
        warn "Set MINICONDA_DELETE_BACKUP=1 to auto-delete, or delete manually later."
        do_delete="n"
      fi
      ;;
    *)
      warn "Invalid MINICONDA_DELETE_BACKUP=${MINICONDA_DELETE_BACKUP} (use 1/0 or unset); keeping backup: $backup_dir"
      do_delete="n"
      ;;
  esac

  if [[ "$do_delete" =~ ^[Yy]$ ]]; then
    [[ -n "$backup_dir" && "$backup_dir" != "/" && "$backup_dir" != "$HOME" ]] || die "Safety stop: dangerous backup_dir=$backup_dir"
    log "Deleting backup dir: $backup_dir"
    rm -rf "$backup_dir"
    log "Backup deleted."
  else
    log "Backup kept: $backup_dir"
    log "Delete later if desired: rm -rf \"$backup_dir\""
  fi
}

final_compliance_summary() {
  if [[ "$COMPLIANCE_POST_HIGH_RISK" == "1" ]]; then
    warn "Final compliance: HIGH-RISK (defaults or pkgs/main|pkgs/r endpoints still present)."
    warn "Inspect: ${MINIFORGE_DIR}/bin/conda config --show | egrep -n 'defaults|pkgs/(main|r)|default_channels:|custom_channels:|custom_multichannels:'"
    return 1
  fi

  if [[ "$COMPLIANCE_WARN_FOUND" == "1" ]]; then
    warn "Final compliance: PASS with WARN (policy-dependent items present)."
    return 0
  fi

  log "Final compliance: PASS (no defaults / no pkgs/main|pkgs/r endpoints)"
  return 0
}

# ===== Main =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -p|--prefix)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --prefix/-p"
      MINIFORGE_DIR="$1"
      shift
      ;;
    -m|--miniconda)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --miniconda/-m"
      MINICONDA_DIR="$1"
      shift
      ;;
    -b|--backup-parent)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --backup-parent/-b"
      MINICONDA_BACKUP_PARENT="$1"
      shift
      ;;
    -B|--backup-dir)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --backup-dir/-B"
      BACKUP_DIR="$1"
      shift
      ;;
    -e|--env)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --env/-e"
      MIGRATE_MODE="selected"
      MIGRATE_ENVS="${MIGRATE_ENVS} $1"
      shift
      ;;
    --envs)
      shift
      [[ $# -gt 0 ]] || die "Missing value for --envs"
      MIGRATE_MODE="selected"
      MIGRATE_ENVS="$1"
      shift
      ;;
    --miniforge-dir=*)
      MINIFORGE_DIR="${1#*=}"
      shift
      ;;
    --miniconda-dir=*)
      MINICONDA_DIR="${1#*=}"
      shift
      ;;
    --backup-parent=*)
      MINICONDA_BACKUP_PARENT="${1#*=}"
      shift
      ;;
    --backup-dir=*)
      BACKUP_DIR="${1#*=}"
      shift
      ;;
    --env=*)
      MIGRATE_MODE="selected"
      MIGRATE_ENVS="${MIGRATE_ENVS} ${1#*=}"
      shift
      ;;
    --envs=*)
      MIGRATE_MODE="selected"
      MIGRATE_ENVS="${1#*=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      die "Unknown argument: $1 (use --help)"
      ;;
  esac
done

if [[ -z "${BACKUP_DIR:-}" ]]; then
  BACKUP_DIR="${MINICONDA_BACKUP_PARENT%/}/conda_migrate_backups/${BACKUP_TS}"
fi

if [[ -z "${EXPORT_DIR:-}" ]]; then
  EXPORT_DIR="${BACKUP_DIR}/envs"
fi

if [[ "$MIGRATE_MODE" == "all" && -n "${MIGRATE_ENVS// }" ]]; then
  MIGRATE_MODE="selected"
fi

if [[ "$AUTO_DETECT_CONDA_DIRS" == "1" ]] && ! miniforge_can_run_conda; then
  detected_miniforge_dir="$(auto_detect_miniforge_dir || true)"
  if [[ -n "${detected_miniforge_dir:-}" ]]; then
    warn "MINIFORGE_DIR not found; auto-detected: $detected_miniforge_dir"
    MINIFORGE_DIR="$detected_miniforge_dir"
  fi
fi

if [[ "$AUTO_DETECT_CONDA_DIRS" == "1" ]] && ! miniconda_can_run_conda; then
  detected_miniconda_dir="$(auto_detect_miniconda_dir || true)"
  if [[ -n "${detected_miniconda_dir:-}" ]]; then
    warn "MINICONDA_DIR not found; auto-detected: $detected_miniconda_dir"
    MINICONDA_DIR="$detected_miniconda_dir"
  fi
fi

log "OS=$OS ARCH=$ARCH"
log "MINICONDA_DIR=$MINICONDA_DIR"
log "MINIFORGE_DIR=$MINIFORGE_DIR"
log "MINICONDA_BACKUP_PARENT=$MINICONDA_BACKUP_PARENT"
log "BACKUP_DIR=$BACKUP_DIR"
log "EXPORT_DIR=$EXPORT_DIR"

preflight_disk_space_checks

check_user_count

if [[ "$CHECK_PATH_CONDA" == "1" ]]; then
  check_conda_compliance "PATH" "current(PATH)" "pre"
fi

# Compliance check existing installs (informational)
if [[ -d "$MINICONDA_DIR" ]]; then
  if miniconda_can_run_conda; then
    check_conda_compliance "$MINICONDA_DIR/bin/conda" "miniconda(pre)" "pre"
  else
    warn "Miniconda detected at $MINICONDA_DIR but conda is not runnable; skipping compliance check."
  fi
else
  warn "Miniconda not found at $MINICONDA_DIR (ok if already removed)"
fi

if [[ "$CLEAN_RC" == "1" ]]; then
  log "Cleaning old conda init blocks + miniconda/anaconda references..."
  clean_bashish_rc_file "$RC_ZSH"
  clean_bashish_rc_file "$RC_BASHRC"
  clean_bashish_rc_file "$RC_BASHPROFILE"
  clean_bashish_rc_file "$RC_PROFILE"
  clean_fish_conf
else
  warn "CLEAN_RC=0, skipping rc cleanup"
fi

install_miniforge_if_needed
log "Configuring Miniforge (channel policy + auto_activate_base)..."
configure_miniforge_channels

# Compliance check miniforge after enforcing channels
check_conda_compliance "$MINIFORGE_DIR/bin/conda" "miniforge(post)" "post"
if [[ "$COMPLIANCE_POST_HIGH_RISK" == "1" && "$ENFORCE_COMPLIANCE" == "1" ]]; then
  die "Compliance enforcement failed; defaults or pkgs/main|pkgs/r still present in Miniforge config."
fi

init_shells_idempotent
migrate_envs_scheme_a

# Scan exported yml for risky channels
scan_exported_yml_for_risky_channels "$EXPORT_DIR"
if [[ -n "${SCAN_YML_DIR:-}" && "$SCAN_YML_DIR" != "$EXPORT_DIR" ]]; then
  scan_exported_yml_for_risky_channels "$SCAN_YML_DIR"
fi

remove_miniconda_safely

if ! final_compliance_summary; then
  if [[ "$STRICT_EXIT" == "1" ]]; then
    warn "STRICT_EXIT=1: exiting with non-zero due to post-migration compliance risk."
    exit 2
  fi
fi

cat <<EOF

✅ Done.

Next steps:
  - Restart your terminal (recommended)
  - If 'conda' still points to old paths, run: hash -r
    (or open a new login shell: exec "$SHELL" -l)
  - Verify:
      which conda
      conda info | grep "base environment"
      conda config --show channels
      conda env list

Expected:
  - base: $MINIFORGE_DIR
  - channels: conda-forge only (optionally conda-forge mirror)
  - envs recreated under: $MINIFORGE_DIR/envs/

Backups created by this script (rc/yml/etc) are centralized here:
  - $BACKUP_DIR
After confirming conda works and envs are OK, you can review and delete that directory if desired.

If using fish: open a new fish session (or run: exec fish).

EOF
