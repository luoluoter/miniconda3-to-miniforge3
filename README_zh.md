# Miniconda3 → Miniforge3 迁移脚本

一个 **安全、可重复执行（幂等）、合规友好** 的迁移脚本，用于将 **Miniconda / Anaconda** 平滑迁移到 **Miniforge3**。

支持 **一行命令完成迁移**，适合个人开发者、团队环境、CI / 服务器场景。

---

## 🚀 一行命令使用

```bash
curl -fsSL https://raw.githubusercontent.com/luoluoter/miniconda3-to-miniforge3/main/migrate_to_miniforge.sh | bash
```

无需交互即可运行，**默认不做破坏性操作**，可放心执行。

---

## 🤔 为什么要从 Miniconda 迁移到 Miniforge？

* Miniconda / Anaconda 默认使用 `defaults` / `pkgs/main`
* 这些源在 **商业 / 企业 / CI / 分发场景** 中可能存在 **授权与合规风险**
* Miniforge 由 conda-forge 社区维护，**默认只使用 conda-forge**
* 更适合：

  * 开源项目
  * 企业内部环境
  * Docker / CI / 云服务器
  * 长期维护的开发环境

👉 本脚本默认 **强制使用 conda-forge（strict 模式）**。

---

## 🧠 脚本做了哪些事情？

### 1️⃣ 自动检测已有 Conda 安装

* 支持 Miniconda / Anaconda
* 即使 `conda` 路径被移动或部分损坏，也会尽量自动修复或提示

---

### 2️⃣ 自动安装 Miniforge3（如未安装）

* 使用官方 Miniforge 安装包
* 支持平台：

  * Linux (x86_64 / aarch64)
  * macOS (Intel / Apple Silicon)

---

### 3️⃣ 强制 Conda 源合规（默认开启）

自动处理以下内容：

❌ 移除：

* `defaults`
* `pkgs/main`
* `pkgs/free`
* `repo.anaconda.com`
* 常见 Anaconda 镜像地址

✅ 保留：

* `conda-forge`

✅ 启用：

* `channel_priority: strict`

---

### 4️⃣ Conda 环境迁移（安全方案）

* 从 Miniconda 导出环境（`conda env export`）
* **自动清洗 YAML 中的风险源**
* 使用 Miniforge 重建环境
* 已存在的环境会自动跳过（可重复执行）

> `base` 环境不会迁移（符合最佳实践）

---

### 5️⃣ 清理 Shell 配置（可选，默认开启）

自动清理旧的 `conda init` 残留：

* `.bashrc`
* `.bash_profile`
* `.profile`
* `.zshrc`
* `fish/config.fish`

然后使用 **Miniforge** 重新初始化 Conda。

---

### 6️⃣ 安全移除 Miniconda（可选）

* 会先校验 **所有环境是否已成功迁移**
* 默认只是 **移动到备份目录**
* 是否删除备份目录会 **再次确认**
* 非交互环境下 **绝不会直接删除**

---

## 📦 备份与安全策略

脚本**不会无提示删除任何重要文件**。

会自动备份：

* 被修改的 Shell 配置文件
* 导出的 Conda 环境 YAML
* 原 Miniconda 目录（仅移动）

默认备份路径：

```
~/conda_migrate_backups/<时间戳>/
```

确认一切正常后，可自行清理。

---

## ⚙️ 高级配置（可选）

可通过环境变量控制行为，例如：

```bash
REMOVE_MINICONDA=0 \
AUTO_ACTIVATE_BASE=false \
bash migrate_to_miniforge.sh
```

### 常用环境变量说明

| 变量                        | 说明               |
| ------------------------- | ---------------- |
| `MINICONDA_DIR`           | 原 Miniconda 路径   |
| `MINIFORGE_DIR`           | Miniforge 安装路径   |
| `DO_MIGRATE_ENVS`         | 是否迁移环境（默认 1）     |
| `CLEAN_RC`                | 是否清理 shell 配置    |
| `REMOVE_MINICONDA`        | 是否移动 Miniconda   |
| `MINICONDA_DELETE_BACKUP` | 是否自动删除备份         |
| `ENFORCE_COMPLIANCE`      | 是否强制 conda-forge |

查看完整参数：

```bash
bash migrate_to_miniforge.sh --help
```

---

## ✅ 迁移完成后的验证

```bash
which conda
conda info | grep "base environment"
conda config --show channels
conda env list
```

期望结果：

* `base environment` 指向 **Miniforge**
* Conda 源仅包含 `conda-forge`
* 所有环境位于：

```
<miniforge>/envs/
```

---

## 🔁 可重复执行（幂等设计）

* 可多次运行脚本
* 失败的环境可修复后重跑
* 已迁移环境不会被重复创建
* 非破坏性设计，适合 CI / 自动化

---

## 📜 License

MIT License
可自由使用、修改、分发。

---

## 🙌 项目初衷

这个脚本的目标是：

* 帮助开发者 **避免无意的商业授权风险**
* 提供一个 **工程化、可审计、可复用** 的迁移方案
* 推动更健康的 conda-forge 生态使用方式

如果你觉得这个项目有帮助，欢迎 ⭐ Star 或提交 Issue / PR。
