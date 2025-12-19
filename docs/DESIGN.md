# Design Doc: Miniconda3 -> Miniforge3 Migration

This document describes the **script design**, focusing on safety, idempotence,
compliance risk reduction, and operational clarity. It is not legal advice.

---

## 1. Goals

- Safely migrate environments from Miniconda/Anaconda to Miniforge
- Enforce conda-forge-only channels and remove risky defaults mappings
- Be idempotent and safe to re-run
- Provide clear compliance checks and remediation hints
- Avoid destructive actions by default

---

## 2. Non-Goals

- Legal interpretation or compliance guarantees
- Bypassing or modifying Anaconda software
- Redistributing proprietary assets
- In-place repair of broken Miniconda installs

---

## 3. Core Risks Addressed

- `defaults` and `pkgs/main|pkgs/r` endpoints in conda config
- Hidden mappings (`default_channels`, `custom_channels`, `custom_multichannels`)
- Exported YAMLs that re-introduce risky channels
- Unintentional use of `conda.anaconda.org` in restricted orgs

---

## 4. Workflow (High-Level)

1) Preflight
   - Detect OS/ARCH
   - Resolve install paths
   - Disk space checks

2) Compliance Pre-Check (informational)
   - Optional org size warning (`USER_COUNT`)
   - Check PATH conda and Miniconda config

3) Shell Cleanup (optional)
   - Remove old `conda init` blocks
   - Backup rc files

4) Miniforge Install
   - Download official Miniforge installer
   - Install if missing

5) Miniforge Configuration
   - Strict channel priority
   - conda-forge only
   - Deep-clean defaults mappings
   - Optional channel alias override for mirrors

6) Compliance Post-Check
   - Verify Miniforge config is clean
   - Exit non-zero if `STRICT_EXIT=1` and risk remains

7) Environment Migration
   - Export each Miniconda env
   - Sanitize YAML channels
   - Recreate envs in Miniforge

8) YAML Scan (optional)
   - Scan exports (and extra dir) for risky channels
   - Optional sanitize in place

9) Safe Miniconda Handling
   - Verify migration
   - Move Miniconda to backup (no deletion by default)

10) Final Summary
   - Compliance status
   - Next-step checks

---

## 5. Idempotence Strategy

- Re-runnable by design
- Skips env creation if already present
- Channel enforcement is idempotent
- Backups are created once per file and timestamped
- YAML sanitization is deterministic

---

## 6. Safety Controls

- Never deletes without explicit confirmation or env flags
- Validates disk space for backup moves across filesystems
- Refuses dangerous paths (`/`, `$HOME`) as deletion targets
- Non-interactive safety defaults (skip destructive steps)

---

## 7. Configuration Surface

- CLI flags: `--prefix`, `--miniconda`, `--backup-parent`, `--backup-dir`
- Environment variables: see `migrate_to_miniforge.sh --help`

Key groups:

- Install paths: `MINICONDA_DIR`, `MINIFORGE_DIR`
- Compliance: `ENFORCE_COMPLIANCE`, `ENFORCE_DEEP_COMPLIANCE`, `ALLOW_ANACONDA_ORG`,
  `CHANNEL_ALIAS_OVERRIDE`, `STRICT_EXIT`
- Migration: `DO_MIGRATE_ENVS`, `EXPORT_DIR`, `SANITIZE_EXPORTED_YMLS`
- Safety: `REMOVE_MINICONDA`, `MINICONDA_DELETE_BACKUP`, disk space thresholds

---

## 8. Observability

- Console logs show each phase and compliance evidence
- Env creation logs are stored under `EXPORT_DIR/logs`
- Backup root recorded at the end of the run

---

## 9. Limitations

- Package availability may differ between defaults and conda-forge
- YAML sanitization removes custom channels (by design for compliance)
- Broken conda installs may require manual repair or reinstall

---

## 10. References

- `docs/COMPLIANCE.md`
- `docs/REFERENCES.md`
- `docs/ANALYZE_zh.md`
