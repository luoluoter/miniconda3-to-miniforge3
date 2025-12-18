# Miniconda3 → Miniforge3 Migration Script

A **safe, idempotent, and compliance-friendly** migration script to move from **Miniconda / Anaconda** to **Miniforge3**, with a single command.

This script helps you:

* Migrate existing Conda environments
* Switch to **conda-forge–only** (recommended for legal/commercial safety)
* Clean old shell init blocks
* Install and initialize Miniforge automatically
* Optionally back up or remove Miniconda safely

---

## 🚀 One-Line Usage

```bash
curl -fsSL https://raw.githubusercontent.com/luoluoter/miniconda3-to-miniforge3/main/migrate_to_miniforge.sh | bash
```

That’s it.
The script is designed to be **safe to re-run** and **non-destructive by default**.

---

## ✨ Why Miniforge?

* **Miniconda / Anaconda** may pull packages from `defaults` / `pkgs/main`, which can introduce **commercial licensing risks**
* **Miniforge** is community-driven and ships with **conda-forge only**
* Better alignment with **open-source, CI, enterprise, and redistribution** use cases

This script enforces a **strict conda-forge-only policy** by default.

---

## 🧠 What This Script Does

### 1. Detects Existing Conda Installs

* Automatically finds Miniconda / Anaconda if present
* Works even if `conda` binaries were moved or partially broken

### 2. Installs Miniforge3 (If Needed)

* Downloads the official Miniforge installer
* Supports:

  * Linux (x86_64 / aarch64)
  * macOS (Intel / Apple Silicon)

### 3. Enforces Channel Compliance

* Removes:

  * `defaults`
  * `pkgs/main`, `pkgs/free`
  * `repo.anaconda.com`
* Keeps:

  * `conda-forge`
* Enables:

  * `channel_priority: strict`

### 4. Migrates Conda Environments (Safe Scheme)

* Exports each environment from Miniconda (`conda env export`)
* **Sanitizes YAML files** to remove risky channels
* Recreates environments in Miniforge
* Skips environments that already exist (idempotent)

### 5. Cleans Shell Configuration

Removes old `conda init` blocks from:

* `.bashrc`
* `.bash_profile`
* `.profile`
* `.zshrc`
* `fish/config.fish`

Then re-initializes Conda using **Miniforge**.

### 6. Safe Miniconda Removal (Optional)

* Verifies all environments were migrated
* Moves Miniconda to a timestamped backup directory
* Never deletes without confirmation (unless explicitly configured)

---

## 📂 Backups & Safety

This script **never blindly deletes data**.

It creates backups for:

* Shell RC files
* Exported environment YAMLs
* Miniconda directory (moved, not deleted)

Default backup location:

```
~/conda_migrate_backups/<timestamp>/
```

You can safely review and delete backups later.

---

## ⚙️ Configuration (Optional)

You can customize behavior using environment variables:

```bash
REMOVE_MINICONDA=0 \
AUTO_ACTIVATE_BASE=false \
bash migrate_to_miniforge.sh
```

### Common Options

| Variable                  | Description                       |
| ------------------------- | --------------------------------- |
| `MINICONDA_DIR`           | Path to existing Miniconda        |
| `MINIFORGE_DIR`           | Target Miniforge install path     |
| `DO_MIGRATE_ENVS`         | `1` = migrate envs (default)      |
| `CLEAN_RC`                | `1` = clean old shell init blocks |
| `REMOVE_MINICONDA`        | `1` = move Miniconda to backup    |
| `MINICONDA_DELETE_BACKUP` | `1` = auto delete backup          |
| `ENFORCE_COMPLIANCE`      | `1` = force conda-forge only      |

Run with `--help` for full details:

```bash
bash migrate_to_miniforge.sh --help
```

---

## ✅ Expected Result

After completion:

```bash
which conda
conda info | grep "base environment"
conda config --show channels
conda env list
```

You should see:

* Base environment → **Miniforge**
* Channels → **conda-forge only**
* Environments recreated under:

  ```
  <miniforge>/envs/
  ```

---

## 🔁 Idempotent by Design

You can safely:

* Re-run the script
* Resume after partial failures
* Fix individual environment YAMLs and retry

Already-migrated environments are skipped automatically.

---

## 📜 License

MIT License
Free to use, modify, and distribute.

---

## 🙌 Motivation

This project exists to help developers:

* Avoid accidental license exposure
* Migrate safely without breaking environments
* Adopt a cleaner, community-driven Conda ecosystem

If this helped you, feel free to ⭐ the repo or open an issue.
