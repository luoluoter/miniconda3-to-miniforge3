# Miniconda3 → Miniforge3 Migration Script

A safe, idempotent migration from **Miniconda/Anaconda (defaults)** to **Miniforge (conda-forge)**.
This project provides technical tooling and documentation, **not legal advice**.

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/luoluoter/miniconda3-to-miniforge3/main/migrate_to_miniforge.sh | bash
```

The script is **safe to re-run** and **non-destructive by default**.

---

## What the Script Does

- Detects existing Miniconda/Anaconda
- Installs Miniforge if missing
- Enforces **conda-forge-only** channels (strict priority)
- Deep-cleans hidden defaults mappings (default/custom channels)
- Exports & recreates environments (YAMLs are sanitized)
- Cleans shell init blocks and re-initializes with Miniforge
- Optionally backs up / moves Miniconda after verification

---

## Why Migrate (Short Version)

- Miniconda defaults to Anaconda’s `defaults` channel.
- Using `defaults` in orgs **>200 people** may trigger commercial terms (per Anaconda policies).
- Miniforge is community-maintained and defaults to **conda-forge**.

---

## Compliance Boundaries (Summary)

- Does **not** bypass licensing, modify Anaconda software, or redistribute proprietary assets.
- Only replaces distributions/channels and updates configs.
- See `docs/COMPLIANCE.md` and `docs/REFERENCES.md` for details.

---

## Safety & Idempotence

- Safe to re-run; already-migrated envs are skipped.
- Backups are kept under: `~/conda_migrate_backups/<timestamp>/`.

---

## Configuration (Common Options)

```bash
REMOVE_MINICONDA=0 \
ENFORCE_COMPLIANCE=1 \
STRICT_EXIT=0 \
bash migrate_to_miniforge.sh
```

## Advanced Usage (Concise)

Specify install + backup dirs:

```bash
bash migrate_to_miniforge.sh -p /data/miniforge3 -B /data/conda_backups
```

Specify Miniconda + backup parent:

```bash
bash migrate_to_miniforge.sh -m /opt/miniconda3 -b /data
```

Key variables:

- `MINICONDA_DIR`, `MINIFORGE_DIR`
- `REMOVE_MINICONDA` (1 moves to backup, 0 keeps)
- `ENFORCE_COMPLIANCE` (1 enforce conda-forge-only)
- `ENFORCE_DEEP_COMPLIANCE` (1 clean default/custom channel mappings)
- `ALLOW_ANACONDA_ORG` (0 warn on conda.anaconda.org)
- `CHANNEL_ALIAS_OVERRIDE` (set mirror if anaconda.org is forbidden)
- `STRICT_EXIT` (1 exit non-zero if post-migration still risky)
- `SANITIZE_EXPORTED_YMLS` (1 auto-sanitize YAML exports)

Full list:

```bash
bash migrate_to_miniforge.sh --help
```

---

## Verify After Migration

```bash
which conda
conda info | grep "base environment"
conda config --show channels
conda env list
```

Expected:

- Base environment points to Miniforge
- Channels are **conda-forge only** (or your approved mirror)

---

## Docs

- `docs/ANALYZE_zh.md` (background & risk analysis)
- `docs/COMPLIANCE.md` (compliance boundaries)
- `docs/REFERENCES.md` (public references)
- `docs/DESIGN.md` (design & workflow)

---

## License

MIT License
