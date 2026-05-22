#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 一键安装脚本：Ollama + DeepSeek Coder V2 7B + OpenCode
.DESCRIPTION
    此脚本将自动完成以下操作：
    1. 检查是否已安装组件，提供跳过选项
    2. 安装 Ollama（本地大模型运行框架）
    3. 拉取 DeepSeek Coder V2 7B 模型
    4. 安装 OpenCode（AI 编程助手 CLI 工具）
    5. 配置 OpenCode 使用本地 Ollama + DeepSeek 模型
.NOTES
    - 需要以管理员权限运行
    - 需要网络连接
    - DeepSeek Coder V2 7B 模型约 4-5GB，请确保磁盘空间充足
    - 建议至少 16GB 内存以流畅运行 7B 模型
.EXAMPLE
    以管理员身份打开 PowerShell，运行：
    .\setup-opencode.ps1
#>

# ============================================================
# 配置区域（可根据需要修改）
# ============================================================
$Config = @{
    OllamaDownloadUrl   = "https://ollama.com/download/OllamaSetup.exe"
    OllamaModel         = "deepseek-coder-v2:7b"
    OllamaApiBase       = "http://localhost:11434"
    OpenCodeNpmPackage  = "opencode"
    OpenCodeGitHubRepo  = "anomalyco/opencode"
    TempDir             = "$env:TEMP\opencode-setup"
}

# ============================================================
# 辅助函数
# ============================================================

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $colors = @{
        "INFO"    = "Cyan"
        "SUCCESS" = "Green"
        "WARNING" = "Yellow"
        "ERROR"   = "Red"
        "RUNNING" = "Magenta"
    }
    $color = $colors[$Status]
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp]" -ForegroundColor DarkGray -NoNewline
    Write-Host " [$Status] " -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Write-Banner {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host ""
}

function Test-AdminPrivilege {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CommandExists {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Wait-ForService {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 60,
        [string]$ServiceName = "Service"
    )
    Write-Step "等待 $ServiceName 启动..." "RUNNING"
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Step "$ServiceName 已就绪" "SUCCESS"
                return $true
            }
        } catch {
            # 服务尚未就绪，继续等待
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Step "$ServiceName 启动超时（${TimeoutSeconds}秒）" "ERROR"
    return $false
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ============================================================
# 主要安装步骤
# ============================================================

function Install-Ollama {
    Write-Banner "步骤 1/4：安装 Ollama"

    # 检查是否已安装
    if (Test-CommandExists "ollama") {
        $version = & ollama --version 2>&1
        Write-Step "Ollama 已安装: $version" "SUCCESS"
        return $true
    }

    Write-Step "正在下载 Ollama 安装程序..." "RUNNING"
    Ensure-Directory $Config.TempDir
    $installerPath = Join-Path $Config.TempDir "OllamaSetup.exe"

    try {
        # 使用 BITS 传输或 WebClient 下载（更稳定）
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Config.OllamaDownloadUrl -OutFile $installerPath -UseBasicParsing
        $ProgressPreference = 'Continue'
        Write-Step "下载完成: $installerPath" "SUCCESS"
    } catch {
        Write-Step "下载失败: $_" "ERROR"
        Write-Step "请手动下载: $($Config.OllamaDownloadUrl)" "INFO"
        return $false
    }

    # 静默安装
    Write-Step "正在安装 Ollama（静默模式）..." "RUNNING"
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList "/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES" -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Step "安装程序返回错误代码: $($process.ExitCode)" "WARNING"
            Write-Step "尝试使用普通模式安装..." "INFO"
            Start-Process -FilePath $installerPath -Wait
        }
    } catch {
        Write-Step "静默安装失败，尝试普通安装..." "WARNING"
        Start-Process -FilePath $installerPath -Wait
    }

    # 修复：安全的环境变量拼接方法
    Write-Step "刷新环境变量..." "RUNNING"
    try {
        $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        
        # 安全拼接环境变量
        $newPath = @()
        if ($machinePath) { $newPath += $machinePath }
        if ($userPath) { $newPath += $userPath }
        $env:Path = $newPath -join ';'
        Write-Step "环境变量刷新成功" "SUCCESS"
    } catch {
        Write-Step "刷新环境变量时出错: $_" "WARNING"
        # 使用进程级环境变量作为备选方案
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Process")
    }

    # 验证安装
    Start-Sleep -Seconds 3
    if (Test-CommandExists "ollama") {
        $version = & ollama --version 2>&1
        Write-Step "Ollama 安装成功: $version" "SUCCESS"
        return $true
    } else {
        # 尝试常见安装路径
        $commonPaths = @(
            "$env:LOCALAPPDATA\Programs\Ollama",
            "$env:ProgramFiles\Ollama",
            "$env:USERPROFILE\AppData\Local\Programs\Ollama"
        )
        foreach ($p in $commonPaths) {
            if (Test-Path "$p\ollama.exe") {
                $env:Path += ";$p"
                [System.Environment]::SetEnvironmentVariable("Path", $env:Path, "User")
                Write-Step "已将 Ollama 添加到 PATH: $p" "INFO"
                return $true
            }
        }
        Write-Step "Ollama 安装可能成功，但未找到命令。请重启终端后重试。" "WARNING"
        return $false
    }
}

function Start-OllamaService {
    Write-Banner "步骤 2/4：启动 Ollama 并拉取 DeepSeek 模型"

    # 检查 Ollama 服务是否已运行
    try {
        $response = Invoke-WebRequest -Uri $Config.OllamaApiBase -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        Write-Step "Ollama 服务已在运行" "SUCCESS"
    } catch {
        # 启动 Ollama 服务
        Write-Step "正在启动 Ollama 服务..." "RUNNING"
        Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
        if (-not (Wait-ForService -Url $Config.OllamaApiBase -TimeoutSeconds 30 -ServiceName "Ollama")) {
            Write-Step "无法启动 Ollama 服务" "ERROR"
            return $false
        }
    }

    # 拉取模型
    Write-Step "正在拉取模型: $($Config.OllamaModel)（约 4-5GB，请耐心等待）..." "RUNNING"
    Write-Step "这可能需要几分钟到几十分钟，取决于网络速度" "INFO"

    try {
        & ollama pull $Config.OllamaModel
        if ($LASTEXITCODE -eq 0) {
            Write-Step "模型拉取成功: $($Config.OllamaModel)" "SUCCESS"
        } else {
            Write-Step "模型拉取失败，退出码: $LASTEXITCODE" "ERROR"
            return $false
        }
    } catch {
        Write-Step "模型拉取出错: $_" "ERROR"
        return $false
    }

    # 验证模型
    Write-Step "验证模型列表..." "RUNNING"
    & ollama list
    Write-Host ""
    return $true
}

function Install-OpenCode {
    Write-Banner "步骤 3/4：安装 OpenCode"

    # 检查是否已安装
    if (Test-CommandExists "opencode") {
        Write-Step "OpenCode 已安装" "SUCCESS"
        & opencode --version 2>&1 | ForEach-Object { Write-Step $_ "INFO" }
        return $true
    }

    # 方式一：尝试通过 npm 安装
    if (Test-CommandExists "npm") {
        Write-Step "检测到 npm，使用 npm 全局安装 OpenCode..." "RUNNING"
        try {
            & npm install -g $Config.OpenCodeNpmPackage 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Step "OpenCode 通过 npm 安装成功" "SUCCESS"
                return $true
            } else {
                Write-Step "npm 安装失败，尝试二进制安装方式..." "WARNING"
            }
        } catch {
            Write-Step "npm 安装出错: $_" "WARNING"
        }
    } else {
        Write-Step "未检测到 npm，将使用二进制下载方式安装" "INFO"
    }

    # 方式二：从 GitHub Releases 下载二进制文件
    Write-Step "正在从 GitHub 获取最新版本信息..." "RUNNING"
    try {
        $releaseUrl = "https://api.github.com/repos/$($Config.OpenCodeGitHubRepo)/releases/latest"
        $ProgressPreference = 'SilentlyContinue'
        $release = Invoke-RestMethod -Uri $releaseUrl -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = 'Continue'

        # 查找 Windows amd64 二进制
        $asset = $release.assets | Where-Object {
            $_.name -match "windows" -and $_.name -match "(amd64|x86_64)" -and $_.name -match "\.(exe|zip)$"
        } | Select-Object -First 1

        if (-not $asset) {
            # 尝试更宽泛的匹配
            $asset = $release.assets | Where-Object {
                $_.name -match "win" -and ($_.name -match "64" -or $_.name -match "amd64")
            } | Select-Object -First 1
        }

        if (-not $asset) {
            Write-Step "未找到适用于 Windows 的二进制文件" "ERROR"
            Write-Step "可用的资源文件:" "INFO"
            $release.assets | ForEach-Object { Write-Step "  - $($_.name)" "INFO" }
            Write-Step "请手动安装: https://github.com/$($Config.OpenCodeGitHubRepo)/releases" "INFO"
            return $false
        }

        Write-Step "找到: $($asset.name) (v$($release.tag_name))" "INFO"
        $downloadPath = Join-Path $Config.TempDir $asset.name
        Ensure-Directory $Config.TempDir

        Write-Step "正在下载 OpenCode..." "RUNNING"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath -UseBasicParsing
        $ProgressPreference = 'Continue'

        # 安装到用户目录
        $installDir = "$env:LOCALAPPDATA\Programs\OpenCode"
        Ensure-Directory $installDir

        if ($asset.name -match "\.zip$") {
            Write-Step "正在解压..." "RUNNING"
            Expand-Archive -Path $downloadPath -DestinationPath $installDir -Force
        } else {
            Copy-Item -Path $downloadPath -Destination "$installDir\opencode.exe" -Force
        }

        # 添加到 PATH
        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$installDir*") {
            [System.Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
            $env:Path += ";$installDir"
            Write-Step "已将 OpenCode 添加到用户 PATH" "INFO"
        }

        Write-Step "OpenCode 安装成功: $installDir" "SUCCESS"
        return $true

    } catch {
        Write-Step "下载 OpenCode 失败: $_" "ERROR"
        Write-Step "请手动安装: https://github.com/$($Config.OpenCodeGitHubRepo)/releases" "INFO"
        return $false
    }
}

function Set-OpenCodeConfig {
    Write-Banner "步骤 4/4：配置 OpenCode"

    # OpenCode 配置文件路径
    $configDir = "$env:USERPROFILE\.config\opencode"
    $configFile = Join-Path $configDir "config.json"

    Ensure-Directory $configDir

    # 创建配置文件
    $config = @{
        provider = @{
            ollama = @{
                apiUrl = $Config.OllamaApiBase
            }
        }
        model = @{
            default = "ollama/$($Config.OllamaModel)"
        }
    } | ConvertTo-Json -Depth 5

    Write-Step "正在写入配置文件: $configFile" "RUNNING"
    Set-Content -Path $configFile -Value $config -Encoding UTF8

    Write-Step "配置文件内容:" "INFO"
    Write-Host $config -ForegroundColor DarkGray
    Write-Host ""

    # 同时在当前项目目录创建 opencode.json（项目级配置）
    $projectConfig = @{
        "`$schema" = "https://opencode.ai/config.schema.json"
        provider = @{
            ollama = @{
                apiUrl = $Config.OllamaApiBase
            }
        }
        model = @{
            default = "ollama/$($Config.OllamaModel)"
        }
    } | ConvertTo-Json -Depth 5

    $projectConfigFile = Join-Path $PWD "opencode.json"
    Write-Step "正在写入项目配置: $projectConfigFile" "RUNNING"
    Set-Content -Path $projectConfigFile -Value $projectConfig -Encoding UTF8

    # 设置环境变量（备用方案）
    [System.Environment]::SetEnvironmentVariable("OLLAMA_HOST", $Config.OllamaApiBase, "User")
    Write-Step "已设置环境变量 OLLAMA_HOST=$($Config.OllamaApiBase)" "INFO"

    Write-Step "OpenCode 配置完成" "SUCCESS"
    return $true
}

function Show-Summary {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Green
    Write-Host "  安装完成 - 摘要" -ForegroundColor Green
    Write-Host ("=" * 60) -ForegroundColor Green
    Write-Host ""

    # Ollama 状态
    if (Test-CommandExists "ollama") {
        $version = & ollama --version 2>&1
        Write-Host "  [OK] Ollama:          $version" -ForegroundColor Green
    } else {
        Write-Host "  [!!] Ollama:          未检测到（请重启终端）" -ForegroundColor Yellow
    }

    # 模型状态
    Write-Host "  [OK] 模型:            $($Config.OllamaModel)" -ForegroundColor Green

    # OpenCode 状态
    if (Test-CommandExists "opencode") {
        Write-Host "  [OK] OpenCode:        已安装" -ForegroundColor Green
    } else {
        Write-Host "  [!!] OpenCode:        未检测到（请重启终端）" -ForegroundColor Yellow
    }

    # API 地址
    Write-Host "  [OK] Ollama API:      $($Config.OllamaApiBase)" -ForegroundColor Green

    # 配置文件
    Write-Host "  [OK] 全局配置:        $env:USERPROFILE\.config\opencode\config.json" -ForegroundColor Green
    Write-Host "  [OK] 项目配置:        $PWD\opencode.json" -ForegroundColor Green

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host "  使用方法" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  1. 确保 Ollama 服务正在运行:" -ForegroundColor White
    Write-Host "     ollama serve" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  2. 测试模型是否正常工作:" -ForegroundColor White
    Write-Host "     ollama run $($Config.OllamaModel) `"你好，请介绍一下自己`"" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  3. 启动 OpenCode:" -ForegroundColor White
    Write-Host "     opencode" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  4. 在 OpenCode 中使用 DeepSeek 模型进行编程辅助" -ForegroundColor White
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host ""

    # 注意事项
    Write-Host "  注意事项:" -ForegroundColor Yellow
    Write-Host "  - 如果命令未找到，请重启 PowerShell 终端" -ForegroundColor DarkGray
    Write-Host "  - 7B 模型建议至少 16GB 内存" -ForegroundColor DarkGray
    Write-Host "  - Ollama 默认监听 localhost:11434" -ForegroundColor DarkGray
    Write-Host "  - 模型文件存储在 $env:USERPROFILE\.ollama\models" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================
# 主流程
# ============================================================

function Main {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                                                      ║" -ForegroundColor Cyan
    Write-Host "  ║   OpenCode + Ollama + DeepSeek 一键安装脚本          ║" -ForegroundColor Cyan
    Write-Host "  ║                                                      ║" -ForegroundColor Cyan
    Write-Host "  ║   组件: Ollama, DeepSeek Coder V2 7B, OpenCode      ║" -ForegroundColor Cyan
    Write-Host "  ║                                                      ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # 检查管理员权限
    if (-not (Test-AdminPrivilege)) {
        Write-Step "建议以管理员身份运行此脚本以确保安装顺利" "WARNING"
        Write-Step "部分功能可能需要管理员权限" "WARNING"
        $continue = Read-Host "是否继续？(Y/N)"
        if ($continue -ne "Y" -and $continue -ne "y") {
            Write-Step "已取消安装" "INFO"
            return
        }
    } else {
        Write-Step "已检测到管理员权限" "SUCCESS"
    }

    # 检查系统信息
    Write-Step "操作系统: $([System.Environment]::OSVersion.VersionString)" "INFO"
    Write-Step "PowerShell: $($PSVersionTable.PSVersion)" "INFO"
    Write-Step "用户目录: $env:USERPROFILE" "INFO"
    Write-Host ""

    # 检查安装状态并询问是否跳过
    Write-Step "检查系统安装状态..." "INFO"

    $ollamaInstalled = Test-CommandExists "ollama"
    $opencodeInstalled = Test-CommandExists "opencode"

    if ($ollamaInstalled -and $opencodeInstalled) {
        Write-Host ""
        Write-Host ("=" * 60) -ForegroundColor Yellow
        Write-Host "  检测到已安装的组件" -ForegroundColor Yellow
        Write-Host ("=" * 60) -ForegroundColor Yellow
        
        # 显示当前版本信息
        if ($ollamaInstalled) {
            $ollamaVersion = & ollama --version 2>&1
            Write-Host "  • Ollama: $ollamaVersion" -ForegroundColor Cyan
        }
        
        if ($opencodeInstalled) {
            $opencodeVersion = & opencode --version 2>&1 | Select-Object -First 1
            Write-Host "  • OpenCode: $opencodeVersion" -ForegroundColor Cyan
        }
        
        Write-Host ""
        Write-Host "  选项:" -ForegroundColor White
        Write-Host "  1. 跳过安装，直接配置和显示摘要" -ForegroundColor Green
        Write-Host "  2. 继续执行完整安装（可修复或更新）" -ForegroundColor Yellow
        Write-Host "  3. 退出脚本" -ForegroundColor Red
        Write-Host ""
        
        $choice = Read-Host "请选择 (1/2/3)"
        
        switch ($choice) {
            "1" {
                Write-Step "跳过安装步骤..." "INFO"
                
                # 检查模型
                Write-Step "检查模型状态..." "RUNNING"
                try {
                    $models = & ollama list 2>&1
                    if ($models -match $Config.OllamaModel) {
                        Write-Step "模型已存在: $($Config.OllamaModel)" "SUCCESS"
                    } else {
                        Write-Step "模型未找到，开始拉取..." "WARNING"
                        Start-OllamaService
                    }
                } catch {
                    Write-Step "检查模型失败，尝试启动服务..." "WARNING"
                    Start-OllamaService
                }
                
                Set-OpenCodeConfig
                Show-Summary
                return
            }
            "2" {
                Write-Step "继续执行完整安装..." "INFO"
                # 继续执行后续安装步骤
            }
            "3" {
                Write-Step "已退出脚本" "INFO"
                return
            }
            default {
                Write-Step "无效选择，继续执行完整安装" "WARNING"
            }
        }
    }

    # 创建临时目录
    Ensure-Directory $Config.TempDir

    # 步骤 1: 安装 Ollama
    $ollamaOk = Install-Ollama
    if (-not $ollamaOk) {
        Write-Step "Ollama 安装失败，终止后续步骤" "ERROR"
        return
    }

    # 步骤 2: 启动 Ollama 并拉取模型
    $modelOk = Start-OllamaService
    if (-not $modelOk) {
        Write-Step "模型拉取失败，但将继续安装 OpenCode" "WARNING"
    }

    # 步骤 3: 安装 OpenCode
    $opencodeOk = Install-OpenCode

    # 步骤 4: 配置 OpenCode
    if ($opencodeOk) {
        Set-OpenCodeConfig
    } else {
        Write-Step "OpenCode 未安装成功，跳过配置步骤" "WARNING"
        Write-Step "安装完成后可手动创建配置文件" "INFO"
    }

    # 显示摘要
    Show-Summary

    # 清理临时文件
    if (Test-Path $Config.TempDir) {
        Remove-Item -Path $Config.TempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Step "已清理临时文件" "INFO"
    }
}

# 运行主流程
Main
