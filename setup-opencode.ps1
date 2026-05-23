#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 一键安装脚本：Ollama + Qwen2.5-Coder + OpenCode
.DESCRIPTION
    1. 安装 Ollama（本地大模型运行框架）
    2. 拉取 Qwen2.5-Coder 14B 模型
    3. 安装 OpenCode（AI 编程助手 CLI 工具）
    4. 配置 OpenCode 使用本地 Ollama + Qwen2.5-Coder 模型
.NOTES
    需要管理员权限 & 网络连接
    Qwen2.5-Coder 14B 模型约 8-9GB
    建议至少 16GB 内存，RTX 4070 12GB 推荐
.EXAMPLE
    .\setup-opencode.ps1
#>

$Config = @{
    OllamaDownloadUrl  = "https://ollama.com/download/OllamaSetup.exe"
    OllamaModel        = "qwen2.5-coder:14b"
    OllamaApiBase      = "http://localhost:11434"
    # 锁定 0.15.31：最新版本需要付费订阅
    OpenCodeVersion    = "0.15.31"
    OpenCodeGitHubRepo = "anomalyco/opencode"
    TempDir            = "$env:TEMP\opencode-setup"
}

# ============================================================
# 辅助函数
# ============================================================

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $colors = @{ INFO = "Cyan"; SUCCESS = "Green"; WARNING = "Yellow"; ERROR = "Red"; RUNNING = "Magenta" }
    Write-Host ("[{0}] [{1,-7}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Status, $Message) -ForegroundColor $colors[$Status]
}

function Write-Banner {
    param([string]$Title)
    Write-Host "`n$('=' * 60)`n  $Title`n$('=' * 60)`n" -ForegroundColor Cyan
}

function Test-AdminPrivilege {
    [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CommandExists {
    param([string]$Command)
    [bool](Get-Command $Command -ErrorAction Ignore)
}

function Wait-ForService {
    param([string]$Url, [int]$TimeoutSeconds = 60, [string]$ServiceName = "Service")
    Write-Step "等待 $ServiceName 启动..." "RUNNING"
    $elapsed = 0
    do {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { Write-Step "$ServiceName 已就绪" "SUCCESS"; return $true }
        } catch {}
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    } while ($elapsed -lt $TimeoutSeconds)
    Write-Host ""; Write-Step "$ServiceName 启动超时" "ERROR"; return $false
}

# ============================================================
# 安装步骤
# ============================================================

function Install-Ollama {
    Write-Banner "步骤 1/4：安装 Ollama"
    if (Test-CommandExists "ollama") {
        Write-Step "Ollama 已安装: $(ollama --version 2>&1)" "SUCCESS"; return $true
    }

    Write-Step "正在下载 Ollama 安装程序..." "RUNNING"
    $null = New-Item -ItemType Directory -Path $Config.TempDir -Force
    $installer = Join-Path $Config.TempDir "OllamaSetup.exe"
    try {
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $Config.OllamaDownloadUrl -OutFile $installer -UseBasicParsing
    } catch {
        Write-Step "下载失败: $_" "ERROR"; return $false
    } finally { $ProgressPreference = "Continue" }

    Write-Step "正在安装 Ollama..." "RUNNING"
    try {
        $p = Start-Process -FilePath $installer -ArgumentList "/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES" -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "exit code $($p.ExitCode)" }
    } catch {
        Write-Step "静默安装失败 ($_), 尝试普通安装..." "WARNING"
        Start-Process -FilePath $installer -Wait
    }

    Start-Sleep -Seconds 3
    if (Test-CommandExists "ollama") {
        Write-Step "Ollama 安装成功: $(ollama --version 2>&1)" "SUCCESS"; return $true
    }

    # 从常见路径手动添加
    $paths = @("$env:LOCALAPPDATA\Programs\Ollama", "$env:ProgramFiles\Ollama",
               "$env:USERPROFILE\AppData\Local\Programs\Ollama")
    foreach ($p in $paths) {
        if (Test-Path "$p\ollama.exe") {
            [Environment]::SetEnvironmentVariable("Path", "$env:Path;$p", "User")
            $env:Path += ";$p"
            Write-Step "已将 Ollama 添加到 PATH" "INFO"; return $true
        }
    }
    Write-Step "Ollama 安装可能成功，但未找到命令。请重启终端。" "WARNING"; return $false
}

function Start-OllamaService {
    Write-Banner "步骤 2/4：启动 Ollama 并拉取 Qwen2.5-Coder 模型"

    try {
        $null = Invoke-WebRequest -Uri $Config.OllamaApiBase -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        Write-Step "Ollama 服务已在运行" "SUCCESS"
    } catch {
        Write-Step "正在启动 Ollama 服务..." "RUNNING"
        Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
        if (-not (Wait-ForService -Url $Config.OllamaApiBase -TimeoutSeconds 30 -ServiceName "Ollama")) {
            return $false
        }
    }

    Write-Step "正在拉取模型: $($Config.OllamaModel)（约 7-8GB，请耐心等待）..." "RUNNING"
    try {
        & ollama pull $Config.OllamaModel
        if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        Write-Step "模型拉取成功" "SUCCESS"
    } catch {
        Write-Step "模型拉取出错: $_" "ERROR"; return $false
    }
    return $true
}

function Install-OpenCode {
    Write-Banner "步骤 3/4：安装 OpenCode"

    if (Test-CommandExists "opencode") {
        Write-Step "OpenCode 已安装" "SUCCESS"
        opencode --version 2>&1 | ForEach-Object { Write-Step $_ "INFO" }
        return $true
    }

    # 方式一：npm
    if (Test-CommandExists "npm") {
        Write-Step "使用 npm 全局安装 OpenCode..." "RUNNING"
        try {
            $out = & npm install -g "opencode@$($Config.OpenCodeVersion)" 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Step "npm 安装成功" "SUCCESS"; return $true }
            Write-Step "npm 安装失败，尝试二进制下载..." "WARNING"
        } catch { Write-Step "npm 出错: $_" "WARNING" }
    }

    # 方式二：GitHub Release
    Write-Step "正在获取最新版本信息..." "RUNNING"
    try {
        $ProgressPreference = "SilentlyContinue"
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Config.OpenCodeGitHubRepo)/releases/tags/v$($Config.OpenCodeVersion)" -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -match "windows.*amd64.*\.(exe|zip)$" } |
                 Select-Object -First 1
        $ProgressPreference = "Continue"

        if (-not $asset) { throw "未找到 Windows 二进制文件" }

        Write-Step "找到: $($asset.name) (v$($release.tag_name))" "INFO"
        $null = New-Item -ItemType Directory -Path $Config.TempDir -Force
        $download = Join-Path $Config.TempDir $asset.name

        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $download -UseBasicParsing
        $ProgressPreference = "Continue"

        $installDir = "$env:LOCALAPPDATA\Programs\OpenCode"
        $null = New-Item -ItemType Directory -Path $installDir -Force

        if ($asset.name -match "\.zip$") {
            Expand-Archive -Path $download -DestinationPath $installDir -Force
        } else {
            Copy-Item -Path $download -Destination "$installDir\opencode.exe" -Force
        }

        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$installDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
            $env:Path += ";$installDir"
        }
        Write-Step "OpenCode 安装成功: $installDir" "SUCCESS"; return $true
    } catch {
        Write-Step "下载 OpenCode 失败: $_" "ERROR"
        Write-Step "请手动安装: https://github.com/$($Config.OpenCodeGitHubRepo)/releases" "INFO"
        return $false
    }
}

function Set-OpenCodeConfig {
    Write-Banner "步骤 4/4：配置 OpenCode"

    $configDir = "$env:USERPROFILE\.config\opencode"
    $null = New-Item -ItemType Directory -Path $configDir -Force
    $configFile = Join-Path $configDir "opencode.json"

    $config = @{
        "`$schema" = "https://opencode.ai/config.json"
        autoupdate = $false
        model      = "ollama/$($Config.OllamaModel)"
        provider   = @{
            ollama = @{
                options = @{ apiUrl = $Config.OllamaApiBase }
            }
        }
    } | ConvertTo-Json -Depth 5

    Set-Content -Path $configFile -Value $config -Encoding UTF8
    Write-Step "全局配置: $configFile" "SUCCESS"

    $projectConfigFile = Join-Path $PWD "opencode.json"
    Copy-Item -Path $configFile -Destination $projectConfigFile -Force
    Write-Step "项目配置: $projectConfigFile" "SUCCESS"

    [Environment]::SetEnvironmentVariable("OLLAMA_HOST", $Config.OllamaApiBase, "User")
    Write-Step "OpenCode 配置完成" "SUCCESS"
}

function Show-Summary {
    Write-Host "`n$('=' * 60)" -ForegroundColor Green
    Write-Host "  安装完成 - 摘要" -ForegroundColor Green
    Write-Host "$('=' * 60)`n" -ForegroundColor Green

    $ollamaVer = if (Test-CommandExists "ollama") { & ollama --version 2>&1 } else { "未检测到" }
    $opencodeVer = if (Test-CommandExists "opencode") { & opencode --version 2>&1 | Select-Object -First 1 } else { "未检测到" }
    $modelOk = if (Test-CommandExists "ollama") { & ollama list 2>&1 | Select-String $Config.OllamaModel -Quiet } else { $false }

    $rows = @(
        @("Ollama", $ollamaVer, (Test-CommandExists "ollama")),
        @("模型 ($($Config.OllamaModel))", "已拉取", $modelOk),
        @("OpenCode", $opencodeVer, (Test-CommandExists "opencode")),
        @("Ollama API", $Config.OllamaApiBase, $true)
    )
    foreach ($r in $rows) {
        $c = if ($r[2]) { "Green" } else { "Yellow" }
        $t = if ($r[2]) { "OK" } else { "!!" }
        Write-Host "  [$t] $($r[0]):`t$($r[1])" -ForegroundColor $c
    }

    Write-Host "`n$('=' * 60)" -ForegroundColor DarkCyan
    Write-Host "  使用方法`n$('=' * 60)" -ForegroundColor DarkCyan
    Write-Host @"
  1. ollama serve
  2. ollama run $($Config.OllamaModel) "你好"
  3. opencode
"@ -ForegroundColor Yellow
}

# ============================================================
# 主流程
# ============================================================

function Main {
    Clear-Host
    Write-Host @"

  ╔══════════════════════════════════════════════════════╗
  ║  OpenCode + Ollama + DeepSeek 一键安装脚本          ║
  ╚══════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

    if (-not (Test-AdminPrivilege)) {
        Write-Step "建议以管理员身份运行" "WARNING"
        if ((Read-Host "是否继续？(Y/N)") -notmatch "^[Yy]") { Write-Step "已取消" "INFO"; return }
    }

    Write-Step "OS: $([Environment]::OSVersion.VersionString)" "INFO"
    Write-Step "PowerShell: $($PSVersionTable.PSVersion)" "INFO"

    # 检查已安装组件
    $ollamaOk = Test-CommandExists "ollama"
    $opencodeOk = Test-CommandExists "opencode"

    if ($ollamaOk -and $opencodeOk) {
        Write-Banner "检测到已安装的组件"
        if ($ollamaOk)  { Write-Step "Ollama:  $(ollama --version 2>&1)" "INFO" }
        if ($opencodeOk) { Write-Step "OpenCode: $(opencode --version 2>&1 | Select-Object -First 1)" "INFO" }
        switch (Read-Host "`n1. 跳过安装并配置`n2. 重新完整安装`n3. 退出`n请选择 (1/2/3)") {
            "1" {
                Write-Step "跳过安装..." "INFO"
                try { & ollama list 2>&1 | Select-String $Config.OllamaModel -Quiet } catch {}
                Set-OpenCodeConfig; Show-Summary; return
            }
            "3" { Write-Step "已退出" "INFO"; return }
        }
    }

    $null = New-Item -ItemType Directory -Path $Config.TempDir -Force

    if (-not (Install-Ollama)) { Write-Step "Ollama 安装失败" "ERROR"; return }
    $modelOk = Start-OllamaService
    if (-not $modelOk) { Write-Step "模型拉取失败" "WARNING" }

    $ocOk = Install-OpenCode
    if ($ocOk) { Set-OpenCodeConfig }

    Show-Summary

    Remove-Item -Path $Config.TempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Step "已清理临时文件" "INFO"
}

Main
