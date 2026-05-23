# w11

Windows 本地 AI 编程环境一键配置脚本集。

## 目录

| 文件 | 说明 |
|------|------|
| `install-fcc.ps1` | 安装 Ollama + Claude Code CLI + Free Claude Code 代理，使用本地 Ollama 模型运行 Claude Code |
| `setup-opencode.ps1` | 安装 Ollama + 拉取 Qwen3 模型 + 安装 OpenCode CLI，配置使用本地模型 |
| `Modelfile` | Ollama 模型配置文件（qwen3:8b, num_ctx 16384） |

## 前置要求

- Windows 10+
- Node.js >= 18（for Claude Code）
- NVIDIA GPU（推荐 12GB+ VRAM，用于本地大模型推理）
- 至少 16GB 内存

## 快速开始

### Free Claude Code（Ollama 代理版）

```powershell
.\install-fcc.ps1
```

### OpenCode

```powershell
.\setup-opencode.ps1
```

## 说明

所有 AI 模型均在本地通过 Ollama 运行，无需云服务 API Key，完全免费。
