#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Miniconda/Anaconda -> Miniforge3 migration (idempotent, safer)
# - Scheme A: export envs from Miniconda, recreate in Miniforge
# - Compliance: enforce conda-forge only; warn on risky sources
# - Shell init: bash/zsh/fish if present
# - Optional safe removal: move Miniconda to backup after verification
# ------------------------------------------------------------
# Miniconda/Anaconda -> Miniforge3 迁移脚本（幂等、更安全）
# - 方案 A：从 Miniconda 导出环境，再在 Miniforge 中重建
# - 合规：强制仅使用 conda-forge；对风险来源给出告警
# - Shell 初始化：如存在则支持 bash / zsh / fish
# - 可选安全移除：验证通过后，将 Miniconda 移动到备份目录（默认不删除）
# ============================================================

# ===== Config (override via env) =====
MINICONDA_DIR="${MINICONDA_DIR:-$HOME/miniconda3}"
MINIFORGE_DIR="${MINIFORGE_DIR:-$HOME/miniforge3}"

DO_MIGRATE_ENVS="${DO_MIGRATE_ENVS:-1}"          # 1 migrate envs, 0 skip
CLEAN_RC="${CLEAN_RC:-1}"                        # 1 clean old conda init blocks, 0 skip
AUTO_ACTIVATE_BASE="${AUTO_ACTIVATE_BASE:-false}"

# Optional safe removal (disabled by default)
# Optional safe removal
REMOVE_MINICONDA="${REMOVE_MINICONDA:-1}"        # 1 move miniconda away after verification, 0 keep
MINICONDA_BACKUP_PARENT="${MINICONDA_BACKUP_PARENT:-$HOME}"
# After moving Miniconda to backup, whether to delete that backup directory:
# - unset: prompt in interactive shells; keep in non-interactive shells
# - 1: delete without prompting
# - 0: keep without prompting
MINICONDA_DELETE_BACKUP="${MINICONDA_DELETE_BACKUP:-}"

# Export dir persists across runs (idempotent & debuggable)
EXPORT_DIR="${EXPORT_DIR:-$HOME/conda_env_exports}"

BACKUP_TS="$(date +%Y%m%d_%H%M%S)"

# Centralized backup directory for files this script edits (rc files, exported YAMLs, etc.).
# Default (if BACKUP_DIR is unset): under MINICONDA_BACKUP_PARENT/conda_migrate_backups/<timestamp> (or override via -B/--backup-dir).
BACKUP_DIR="${BACKUP_DIR:-}"

# Enforce channel compliance automatically for Miniforge:
# - 1: auto-fix risky channels in Miniforge config (recommended)
# - 0: only warn
ENFORCE_COMPLIANCE="${ENFORCE_COMPLIANCE:-1}"

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
have() { command -v "$1" >/dev/null 2>&1; }

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
    if [[ -x "$candidate/bin/conda" && "$candidate" != "$MINIFORGE_DIR" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  if have conda; then
    base="$(detect_conda_base_dir "$(command -v conda)")"
    if [[ -n "$base" && -x "$base/bin/conda" && "$base" != "$MINIFORGE_DIR" ]]; then
      echo "$base"
      return 0
    fi
  fi

  return 1
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--help|-h] [-p DIR|--prefix DIR] [-m DIR|--miniconda DIR] [-b DIR|--backup-parent DIR] [-B DIR|--backup-dir DIR]

This script is mainly configured via environment variables.
脚本主要通过环境变量配置（可在运行前临时设置）。

Options:
  -h, --help            Show this help
  -p, --prefix DIR      Install/use Miniforge at DIR (overrides MINIFORGE_DIR)
  -m, --miniconda DIR   Use Miniconda at DIR (overrides MINICONDA_DIR)
  -b, --backup-parent DIR  Parent directory to place Miniconda backup (overrides MINICONDA_BACKUP_PARENT)
  -B, --backup-dir DIR  Directory to store script backups (rc/yml/etc) (overrides BACKUP_DIR)

Key environment variables (defaults shown):
  MINICONDA_DIR=$MINICONDA_DIR
  MINIFORGE_DIR=$MINIFORGE_DIR
  EXPORT_DIR=$EXPORT_DIR
  BACKUP_DIR=${BACKUP_DIR:-"<default: MINICONDA_BACKUP_PARENT/conda_migrate_backups/<timestamp> >"}

  DO_MIGRATE_ENVS=$DO_MIGRATE_ENVS          # 1 migrate envs, 0 skip
  CLEAN_RC=$CLEAN_RC                        # 1 clean conda init blocks, 0 skip
  AUTO_ACTIVATE_BASE=$AUTO_ACTIVATE_BASE    # true/false for Miniforge

  REMOVE_MINICONDA=$REMOVE_MINICONDA        # 1 move miniconda after verification, 0 keep
  MINICONDA_BACKUP_PARENT=$MINICONDA_BACKUP_PARENT
  MINICONDA_DELETE_BACKUP=${MINICONDA_DELETE_BACKUP:-"<prompt if interactive>"}  # 1 delete, 0 keep, unset prompt/keep
  SANITIZE_EXPORTED_YMLS=${SANITIZE_EXPORTED_YMLS:-"<prompt if interactive>"}    # 1 sanitize, 0 skip, unset prompt/skip
  ENFORCE_COMPLIANCE=$ENFORCE_COMPLIANCE                                        # 1 auto-fix Miniforge, 0 warn only
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

  python3 - <<'PY'
import os, re
p=os.path.expanduser("~/.config/fish/config.fish")
s=open(p,"r",encoding="utf-8",errors="ignore").read()
s=re.sub(r"(?s)# >>> conda initialize >>>.*?# <<< conda initialize <<<\n?","",s)
open(p,"w",encoding="utf-8").write(s.rstrip()+"\n")
PY

  log "Cleaned: $FISH_CONF"
}

# ===== Compliance helpers =====
is_risky_channel_line() {
  # risky if:
  # - defaults
  # - pkgs/main or pkgs/free (including mirrors like tuna)
  # - repo.anaconda.com / conda.anaconda.org
  # - any URL containing /anaconda/pkgs/(main|free)
  echo "$1" | grep -Eiq \
    '(^|[[:space:]])defaults([[:space:]]|$)|pkgs/(main|free)|repo\.anaconda\.com|conda\.anaconda\.org|/anaconda/pkgs/(main|free)'
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
    miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/free >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://conda.anaconda.org/pkgs/main >/dev/null 2>&1 || true
    miniforge_conda config --remove channels https://conda.anaconda.org/pkgs/free >/dev/null 2>&1 || true
  else
    "$conda_bin" config --remove channels defaults >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://repo.anaconda.com/pkgs/main >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://repo.anaconda.com/pkgs/free >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free >/dev/null 2>&1 || true
    "$conda_bin" config --remove channels https://conda.anaconda.org/pkgs/main >/dev/null 2>&1 || true
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

check_conda_channels_risk() {
  local conda_bin="$1"
  local label="$2"
  [[ -x "$conda_bin" ]] || { warn "Risk check skipped: $label conda not found: $conda_bin"; return 0; }

  log "Risk check ($label): channels + endpoints"
  local cfg
  if [[ "$conda_bin" == "$MINIFORGE_DIR/bin/conda" ]]; then
    cfg="$(miniforge_conda config --show channels 2>/dev/null || true)"
  elif [[ "$conda_bin" == "$MINICONDA_DIR/bin/conda" ]]; then
    if miniconda_can_run_conda; then
      cfg="$(miniconda_conda config --show channels 2>/dev/null || true)"
    else
      warn "Risk check skipped: $label conda not runnable under MINICONDA_DIR=$MINICONDA_DIR"
      return 0
    fi
  else
    cfg="$("$conda_bin" config --show channels 2>/dev/null || true)"
  fi

  local risky_found=0

  # Print channel list with flags
  echo "$cfg" | while IFS= read -r line; do
    if is_risky_channel_line "$line"; then
      echo "[RISK][$label] $line"
      risky_found=1
    else
      echo "[ OK ][$label] $line"
    fi
  done

  if echo "$cfg" | grep -Eiq '^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$|pkgs/(main|free)|/anaconda/pkgs/(main|free)'; then
    risky_found=1
  fi

  if [[ "$risky_found" == "1" ]]; then
    warn "[$label] Potential commercial-risk sources detected in channel config."

    # For Miniforge, enforce automatically (to guarantee compliance).
    if [[ "$ENFORCE_COMPLIANCE" == "1" && "$conda_bin" == "$MINIFORGE_DIR/bin/conda" ]]; then
      warn "[$label] Enforcing compliance now (conda-forge only, strict)..."
      enforce_conda_channels_compliance "$conda_bin" || true

      cfg="$(miniforge_conda config --show channels 2>/dev/null || true)"
      if echo "$cfg" | grep -Eiq '^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$|pkgs/(main|free)|/anaconda/pkgs/(main|free)|repo\.anaconda\.com|conda\.anaconda\.org'; then
        die "[$label] Compliance enforcement failed; risky channels still present. Please inspect: $conda_bin config --show channels"
      fi
      log "[$label] ✅ Compliance enforced (channels cleaned)."
      return 0
    fi

    warn "Remediation commands (keep only conda-forge + approved conda-forge mirror):"
    warn "  $conda_bin config --set channel_priority strict"
    warn "  $conda_bin config --remove channels defaults"
    warn "  $conda_bin config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main"
    warn "  $conda_bin config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free"
    warn "  $conda_bin config --remove channels conda-forge || true"
    warn "  $conda_bin config --add channels conda-forge"
    return 0
  fi

  log "[$label] ✅ Looks clean (no defaults/pkgs/main/free/anaconda endpoints detected in channel config)"
}

scan_exported_yml_for_risky_channels() {
  local dir="$1"
  [[ -d "$dir" ]] || { warn "YML scan skipped: not found $dir"; return 0; }

  log "Risk check: scanning exported env YAMLs under $dir"
  local hits
  hits="$(grep -RIn --include '*.yml' --include '*.yaml' -E \
    '(^|[[:space:]])defaults::|(^|[[:space:]])anaconda::|^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$|pkgs/(main|free)|repo\.anaconda\.com|conda\.anaconda\.org|/anaconda/pkgs/(main|free)' \
    "$dir" 2>/dev/null || true)"

  if [[ -n "$hits" ]]; then
    warn "Found risky channel references in exported YAMLs:"
    echo "$hits"
    warn "Note:"
    warn "  - These are YAML backup exports; they reflect past config and may contain non-compliant channels."
    warn "  - During migration, this script sanitizes each YAML before 'conda env create -f', so this does NOT affect env creation in this run."
    warn "  - If you (or CI) later reuse these YAMLs directly, they could override your conda config. You can sanitize the exports now."

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
	      log "Sanitizing exported YAML backups under: $dir"
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

  python3 - "$yml" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8", errors="ignore")

# Remove existing top-level channels block (channels: + list items)
s2 = re.sub(r"(?ms)^channels:\s*\n(?:\s*-\s*.*\n)+", "", s)

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
  if grep -Eiq '(^|[[:space:]])defaults::|^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$|/anaconda/pkgs/(main|free)|pkgs/(main|free)|repo\.anaconda\.com|conda\.anaconda\.org|(^|[[:space:]])anaconda::' "$yml"; then
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

  # Enforce legal-safe defaults
  miniforge_conda config --set channel_priority strict >/dev/null
  miniforge_conda config --remove channels defaults >/dev/null 2>&1 || true

  # Remove common risky channels / mirrors (idempotent)
  miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/main >/dev/null 2>&1 || true
  miniforge_conda config --remove channels https://repo.anaconda.com/pkgs/free >/dev/null 2>&1 || true
  miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main >/dev/null 2>&1 || true
  miniforge_conda config --remove channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free >/dev/null 2>&1 || true

  # Ensure conda-forge exists & is on top
  miniforge_conda config --remove channels conda-forge >/dev/null 2>&1 || true
  miniforge_conda config --add channels conda-forge >/dev/null

  # Optional: avoid auto base activation
  miniforge_conda config --set auto_activate_base "$AUTO_ACTIVATE_BASE" >/dev/null 2>&1 || true

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
  return 0
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

export_env_yml() {
  local envname="$1"
  local yml="$EXPORT_DIR/${envname}.yml"
  mkdir -p "$EXPORT_DIR"
  miniconda_conda env export -n "$envname" --no-builds > "$yml"
  echo "$yml"
}

create_env_from_yml_safe() {
  local yml="$1"
  local envname="$2"
  local log_dir="$EXPORT_DIR/logs"
  mkdir -p "$log_dir"

  # 1) sanitize yml channels (avoid defaults/pkgs)
  if ! sanitize_yml_channels_inplace "$yml"; then
    warn "[$envname] YAML sanitize failed or left risky refs. Check: $yml"
    return 10
  fi

  # 2) create env (keep full output in a persistent log)
  local create_log="$log_dir/create_${envname}.log"
  log "conda env create log: $create_log"
  if miniforge_conda env create -f "$yml" 2>&1 | tee "$create_log"; then
    return 0
  fi

  local rc="${PIPESTATUS[0]}"

  # 3) If failed, emit a clear warning
  warn "[$envname] conda env create failed even after sanitizing channels (exit $rc)."
  warn "  yml: $yml"
  warn "  log: $create_log"
  warn "  Tip: this usually means some pinned packages/versions are not available on conda-forge, or there are conflicts under strict channel priority."
  warn "  Last 80 log lines:"
  tail -n 80 "$create_log" || true
  return 20
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

  local yml envname envs
  envs="$(list_miniconda_env_names)" || die "Failed to list Miniconda envs from $MINICONDA_DIR"
  while IFS= read -r envname; do
    [[ -n "$envname" ]] || continue
    [[ "$envname" == "base" ]] && continue

    if miniforge_has_env "$envname"; then
      log "Skip (already exists in Miniforge): $envname"
      continue
    fi

    log "Exporting: $envname"
    yml="$(export_env_yml "$envname")"

    log "Creating in Miniforge: $envname"
    if create_env_from_yml_safe "$yml" "$envname"; then
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

preflight_disk_space_checks

# Risk check existing installs (informational)
if [[ -d "$MINICONDA_DIR" ]]; then
  if miniconda_can_run_conda; then
    check_conda_channels_risk "$MINICONDA_DIR/bin/conda" "miniconda(pre)"
  else
    warn "Miniconda detected at $MINICONDA_DIR but conda is not runnable; skipping channel risk check."
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
log "Enforcing Miniforge strict channel policy (conda-forge only, strict)..."
configure_miniforge_channels

# Risk check miniforge after enforcing channels
check_conda_channels_risk "$MINIFORGE_DIR/bin/conda" "miniforge(post-config)"

init_shells_idempotent
migrate_envs_scheme_a

# Scan exported yml for risky channels
scan_exported_yml_for_risky_channels "$EXPORT_DIR"

remove_miniconda_safely

cat <<EOF

✅ Done.

Next steps:
  - Restart your terminal (recommended)
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
After confirming everything works, you can review and delete that directory if desired.

If using fish: open a new fish session (or run: exec fish).

EOF
