# Miniconda3 → Miniforge3 迁移脚本

[English](README.md) | 中文

一个 **安全、幂等** 的迁移脚本，用于将 **Miniconda/Anaconda（defaults）** 迁移到 **Miniforge（conda-forge）**。
本项目提供的是技术工具与文档，**不构成法律意见**。

---

## 一行命令

```bash
curl -fsSL https://raw.githubusercontent.com/luoluoter/miniconda3-to-miniforge3/main/migrate_to_miniforge.sh | bash
```

脚本可重复执行，默认不做破坏性操作。

---

## 脚本做了什么

- 检测现有 Miniconda/Anaconda
- 如有需要安装 Miniforge
- 强制 **conda-forge-only**（strict 优先级）
- 深度清理隐藏的 defaults 映射（default/custom channels）
- 导出并重建环境（YAML 自动清洗）
- 清理 shell init 并用 Miniforge 重新初始化
- 可选：验证后备份/迁移 Miniconda 目录

---

## 为什么迁移（简版）

- Miniconda 默认指向 `defaults`。
- 在组织规模 **>200** 的商业/企业场景中，可能触发 Anaconda 商业条款。
- Miniforge 由社区维护，默认仅使用 **conda-forge**。

---

## 合规边界（摘要）

- 不绕过授权、不修改 Anaconda 软件、不分发其专有资产。
- 仅替换发行版/渠道并更新配置。
- 详见：`docs/COMPLIANCE.md`、`docs/REFERENCES.md`。

---

## 安全与幂等

- 可多次运行，已迁移环境会自动跳过。
- 备份目录：`~/conda_migrate_backups/<timestamp>/`。

---

## 常用配置

```bash
REMOVE_MINICONDA=0 \
ENFORCE_COMPLIANCE=1 \
STRICT_EXIT=0 \
bash migrate_to_miniforge.sh
```

## 高级用法（简洁）

指定安装目录 + 备份目录：

```bash
bash migrate_to_miniforge.sh -p /data/miniforge3 -B /data/conda_backups
```

指定 Miniconda 路径 + 备份父目录：

```bash
bash migrate_to_miniforge.sh -m /opt/miniconda3 -b /data
```

## 仅做合规检查

```bash
curl -fsSL https://raw.githubusercontent.com/luoluoter/miniconda3-to-miniforge3/main/conda_compliance_check.sh | bash
```

说明：

- 如果 Miniconda 已移除，路径不存在会显示为 OK。
- 可覆盖路径：`MINIFORGE_CONDA=/path/to/conda MINICONDA_CONDA=/path/to/conda`。
- 可选扫描：`SCAN_YML_DIR=/path/to/exports`。

常用变量：

- `MINICONDA_DIR`, `MINIFORGE_DIR`
- `REMOVE_MINICONDA`（1 迁移到备份，0 保留）
- `ENFORCE_COMPLIANCE`（1 强制 conda-forge-only）
- `ENFORCE_DEEP_COMPLIANCE`（1 清理 default/custom 映射）
- `ALLOW_ANACONDA_ORG`（0 表示禁止 anaconda.org）
- `CHANNEL_ALIAS_OVERRIDE`（组织禁止 anaconda.org 时设置镜像）
- `STRICT_EXIT`（1 表示迁移后仍有风险则退出非 0）
- `SANITIZE_EXPORTED_YMLS`（1 自动清洗导出的 YAML）

完整参数：

```bash
bash migrate_to_miniforge.sh --help
```

---

## 迁移完成后验证

```bash
which conda
conda info | grep "base environment"
conda config --show channels
conda env list
```

期望结果：

- base 指向 Miniforge
- channels 仅包含 **conda-forge**（或你的镜像）

---

## 文档

- `docs/ANALYZE_zh.md`（背景与风险）
- `docs/COMPLIANCE.md`（合规边界）
- `docs/REFERENCES.md`（公开参考）
- `docs/DESIGN.md`（设计与流程）

---

## License

MIT License
