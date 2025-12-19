# Environment Migration Guide (Miniconda/Anaconda -> Miniforge)

本指引用于将已有的 Miniconda/Anaconda 环境迁移到 Miniforge（conda-forge），实现：
- 继续使用 conda 生态，但默认使用 `conda-forge`
- 避免环境重建时继续访问 `defaults` / `anaconda::`
- 保持环境可复现、可维护

> 关键原则：不要复制 env 目录；采用“导出 -> 清洗 -> 重建 -> 验证”。

---

## 0. 迁移前准备（必做）

### 0.1 识别你真正需要迁移的环境

```bash
conda env list
```

建议只迁移：

* 当前项目使用的 env
* 生产/长期维护的 env

历史/实验/临时 env 可以不迁移（减少技术债）。

### 0.2 安装 Miniforge（推荐独立目录）

例如安装到：

* `~/miniforge3`

确认：

```bash
~/miniforge3/bin/conda --version
```

---

## 1. 禁止“复制 env 目录”（重要说明）

**不建议**：

* `cp -r ~/miniconda3/envs/foo ~/miniforge3/envs/foo`

原因：

* conda env 依赖大量二进制包与元数据，包含绝对路径前缀（prefix）
* `conda-meta` 中记录旧路径，复制后会导致激活/更新/运行崩坏
* defaults 与 conda-forge 的 ABI/依赖体系不同，复制会造成不可维护的混合状态

正确方式：导出声明文件 -> 在 Miniforge 重建。

---

## 2. 标准迁移流程（推荐）

### 2.1 从旧环境导出 `environment.yml`

在 Miniconda/Anaconda 中：

```bash
conda activate <OLD_ENV>
conda env export > <OLD_ENV>.yml
```

> 注意：`conda env export` 可能包含 `defaults`、`anaconda::`、`prefix` 等信息，需要清洗。

---

## 3. 清洗 YAML（确保不会带入 defaults）

### 3.1 必须做的两件事

* 将 `channels:` 统一为 `conda-forge`（或你的企业镜像）
* 删除 `prefix:`（避免在旧 miniconda 路径创建环境）

最终期望 YAML 结构类似：

```yaml
name: myenv
channels:
  - conda-forge
dependencies:
  - python=3.10
  - numpy
  - pip
  - pip:
      - somepkg==1.2.3
```

### 3.2（推荐）自动清洗

如果你使用本仓库脚本的清洗函数（例如 `sanitize_yml_channels_inplace`），确保执行后：

* YAML 中只剩 `conda-forge`
* 不含 `defaults::` / `anaconda::`
* 不含 `prefix:`

---

## 4. 双保险：检查 conda 配置（.condarc）

即使 YAML 已清洗，用户级/系统级 `.condarc` 仍可能包含 `defaults`。

检查当前 Miniforge 使用的 channel：

```bash
conda config --show channels
```

期望输出只有：

```yaml
channels:
  - conda-forge
```

如果你看到 `defaults`，请移除：

```bash
conda config --remove channels defaults
conda config --add channels conda-forge
conda config --set channel_priority strict
```

---

## 5. 在 Miniforge 中重建环境（建议加“双保险”参数）

### 5.1 重建

```bash
~/miniforge3/bin/conda env create -f <OLD_ENV>.yml -c conda-forge
```

说明：

* `-c conda-forge` 是双保险：即使 YAML/condarc 出现偏差，也尽量优先走 conda-forge。

### 5.2 激活新环境

```bash
source ~/miniforge3/bin/activate
conda activate <OLD_ENV>
```

---

## 6. 验证迁移是否成功（必须）

### 6.1 基础验证

```bash
python -V
conda list | head
```

### 6.2 关键依赖验证（按你的项目替换）

```bash
python -c "import numpy, pandas; print('ok')"
```

### 6.3 确认没有 defaults 痕迹

检查 YAML（以及必要时检查环境）中是否出现：

* `defaults`
* `defaults::`
* `anaconda::`
* `repo.anaconda.com`

示例：

```bash
grep -Eiq '(^|[[:space:]])defaults::|^[[:space:]]*-[[:space:]]*defaults[[:space:]]*$|(^|[[:space:]])anaconda::|repo\.anaconda\.com' <OLD_ENV>.yml \
  && echo "FOUND RISKY TOKENS" || echo "OK"
```

---

## 7. 常见问题（Troubleshooting）

### 7.1 依赖解析失败（Solving environment failed）

原因可能包括：

* 原 env 使用 defaults 的某些特定构建，conda-forge 没有完全一致版本
* 包版本 pin 太死（例如强制某个 build string）

解决思路：

1. 放宽 pin（去掉 build string）
2. 先只固定 python 主版本，再逐步添加依赖
3. 对特别难的包，允许使用 `pip:` 安装作为兜底

### 7.2 PyTorch / CUDA / 大型二进制包差异

* conda-forge 的包构建策略可能与 defaults 不同
* GPU/驱动版本敏感

建议：

* 迁移后优先测试模型推理/训练链路
* 明确记录驱动版本、CUDA 版本、torch 版本组合

### 7.3 为什么 Miniforge 体积更小？

常见原因：

* 旧 Miniconda 累积了大量历史 env（`envs/`）与缓存（`pkgs/`）
* defaults 常包含体积更大的 MKL/Intel 栈
* 新 Miniforge 只包含干净 base + 少量 cache

---

## 8. 迁移后的清理建议（可选）

### 8.1 清理 conda cache（在 Miniforge 中）

```bash
conda clean -a
```

### 8.2 归档旧 miniconda（建议先保留一段时间）

* 先保留备份（如你现在的 `miniconda3_backup_...`）
* 确认所有项目在 Miniforge 下稳定运行后，再考虑删除

---

## 9. 最佳实践总结（建议写进团队规范）

* 一个项目一个 env，用 `environment.yml` 管理
* 禁止在企业环境中默认使用 `defaults`
* `.condarc` 统一策略：`conda-forge` + `channel_priority strict`
* CI/Docker 镜像同样遵循上述策略
* 定期 `conda clean -a` 控制 cache 体积
