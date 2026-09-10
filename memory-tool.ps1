# ============================================
# 内存优化工具（模拟 PCL 启动器内存优化原理）
# 集合总成版：一个窗口集成全部功能
#
#   界面功能：
#     · 实时内存状态（可用/已用/占用率）
#     · 一键清理内存（显示腾出多少）
#     · 定时清理开关（间隔 1~720 分钟可自定义，静默清理，开机自启）
#     · 运行日志
#
#   命令行参数（供后台/高级使用）：
#     -silent        : 静默清理一次（不弹窗）
#     -watch [-分钟数] : 后台常驻，按间隔清理（默认 30 分钟）
#     -info          : 弹出当前内存状态
#     -schedule [分钟] : 命令行开启定时清理
#     -stop          : 命令行关闭定时清理
# ============================================

param(
    [switch]$Info,
    [switch]$Schedule,
    [switch]$Stop,
    [switch]$Watch,
    [switch]$Silent,
    [int]$Minutes = 30
)

$ErrorActionPreference = 'SilentlyContinue'

# ---------- Win32 API ----------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MemOptimizer {
    [DllImport("kernel32.dll")]
    public static extern bool SetProcessWorkingSetSizeEx(
        IntPtr hProcess,
        UIntPtr dwMinimumWorkingSetSize,
        UIntPtr dwMaximumWorkingSetSize,
        uint dwFlags);
}
'@

# ---------- 基础函数 ----------

# 获取当前物理内存状态（MB）
function Get-MemoryMB {
    $os = Get-CimInstance Win32_OperatingSystem
    return @{
        Free  = [math]::Round($os.FreePhysicalMemory / 1024)
        Total = [math]::Round($os.TotalVisibleMemorySize / 1024)
    }
}

# 清空所有可访问进程的工作集
function Clear-WorkingSet {
    $cleaned = 0
    $skipped = 0
    $me = $PID
    Get-Process | ForEach-Object {
        if ($_.Id -eq $me) { return }
        try {
            $handle = $_.Handle
            $ok = [MemOptimizer]::SetProcessWorkingSetSizeEx(
                $handle,
                [UIntPtr]::new([uint64]::MaxValue),
                [UIntPtr]::new([uint64]::MaxValue),
                0)
            if ($ok) { $cleaned++ } else { $skipped++ }
        } catch {
            $skipped++
        }
    }
    [GC]::Collect()
    return @{ Cleaned = $cleaned; Skipped = $skipped }
}

# 弹出提示框（seconds 秒后自动关闭）
function Show-Popup($text, $seconds) {
    $ws = New-Object -ComObject WScript.Shell
    $null = $ws.Popup($text, $seconds, "内存优化", 64)
}

# 停止正在运行的定时清理后台进程
function Stop-TimerProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -like '*memory-tool.ps1*' -and $_.CommandLine -like '*-watch*'
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 路径 ----------
$scriptPath = $MyInvocation.MyCommand.Path
$startupDir = [Environment]::GetFolderPath('Startup')
$timerLnk   = Join-Path $startupDir '内存定时清理.lnk'

# ---------- 命令行模式 ----------

# 静默清理一次（给后台定时任务用）
if ($Silent) {
    $null = Clear-WorkingSet
    exit
}

# 后台常驻：启动先清一次，之后按设置间隔清理（默认 30 分钟）
if ($Watch) {
    # 间隔校验：1~720 分钟，非法值回退默认 30
    if ($Minutes -lt 1 -or $Minutes -gt 720) { $Minutes = 30 }
    $intervalSec = $Minutes * 60
    $null = Clear-WorkingSet
    while ($true) {
        Start-Sleep -Seconds $intervalSec
        $null = Clear-WorkingSet
    }
}

# 命令行开启定时清理
if ($Schedule) {
    if ($Minutes -lt 1 -or $Minutes -gt 720) { $Minutes = 30 }
    Stop-TimerProcess
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($timerLnk)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -watch -Minutes $Minutes"
    $sc.WorkingDirectory = Split-Path $scriptPath
    $sc.Save()
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$scriptPath`"",'-watch','-Minutes',"$Minutes" -WindowStyle Hidden
    Show-Popup "定时清理已开启（每 $Minutes 分钟，开机自启）", 5
    exit
}

# 命令行关闭定时清理
if ($Stop) {
    Stop-TimerProcess
    if (Test-Path $timerLnk) { Remove-Item $timerLnk -Force }
    Show-Popup "定时清理已关闭", 4
    exit
}

# 命令行查看内存状态
if ($Info) {
    $m = Get-MemoryMB
    $used = $m.Total - $m.Free
    $pct  = [math]::Round($used / $m.Total * 100)
    Show-Popup "当前内存状态`n`n总内存 : $($m.Total) MB`n已用   : $used MB ($pct%)`n可用   : $($m.Free) MB", 6
    exit
}

# ============================================
# 图形界面模式（默认入口）
# ============================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 控件 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "内存优化工具"
$form.Size = New-Object System.Drawing.Size(400, 640)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$lblFreeBig = New-Object System.Windows.Forms.Label
$lblFreeBig.Location = New-Object System.Drawing.Point(20, 14)
$lblFreeBig.Size = New-Object System.Drawing.Size(340, 34)
$lblFreeBig.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 17, [System.Drawing.FontStyle]::Bold)
$lblFreeBig.Text = "正在读取内存..."

$prgUsed = New-Object System.Windows.Forms.ProgressBar
$prgUsed.Location = New-Object System.Drawing.Point(20, 54)
$prgUsed.Size = New-Object System.Drawing.Size(340, 18)
$prgUsed.Minimum = 0
$prgUsed.Maximum = 100

$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Location = New-Object System.Drawing.Point(20, 78)
$lblDetail.Size = New-Object System.Drawing.Size(340, 20)
$lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$lblDetail.Text = ""

$btnClean = New-Object System.Windows.Forms.Button
$btnClean.Location = New-Object System.Drawing.Point(20, 106)
$btnClean.Size = New-Object System.Drawing.Size(340, 42)
$btnClean.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$btnClean.Text = "一键清理内存"

$grpTimer = New-Object System.Windows.Forms.GroupBox
$grpTimer.Location = New-Object System.Drawing.Point(20, 160)
$grpTimer.Size = New-Object System.Drawing.Size(340, 160)
$grpTimer.Text = "定时清理（开机自启）"

$lblTimerStatus = New-Object System.Windows.Forms.Label
$lblTimerStatus.Location = New-Object System.Drawing.Point(12, 24)
$lblTimerStatus.Size = New-Object System.Drawing.Size(316, 20)
$lblTimerStatus.Text = "检查中..."

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Location = New-Object System.Drawing.Point(12, 52)
$lblInterval.Size = New-Object System.Drawing.Size(40, 22)
$lblInterval.Text = "间隔"

$nudMinutes = New-Object System.Windows.Forms.NumericUpDown
$nudMinutes.Location = New-Object System.Drawing.Point(56, 48)
$nudMinutes.Size = New-Object System.Drawing.Size(66, 26)
$nudMinutes.Minimum = 1
$nudMinutes.Maximum = 720
$nudMinutes.Value = 30

$lblUnit = New-Object System.Windows.Forms.Label
$lblUnit.Location = New-Object System.Drawing.Point(128, 52)
$lblUnit.Size = New-Object System.Drawing.Size(44, 22)
$lblUnit.Text = "分钟"

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Location = New-Object System.Drawing.Point(180, 46)
$btnApply.Size = New-Object System.Drawing.Size(148, 30)
$btnApply.Text = "应用间隔"

$btnTimerOn = New-Object System.Windows.Forms.Button
$btnTimerOn.Location = New-Object System.Drawing.Point(12, 88)
$btnTimerOn.Size = New-Object System.Drawing.Size(150, 36)
$btnTimerOn.Text = "开启定时清理"

$btnTimerOff = New-Object System.Windows.Forms.Button
$btnTimerOff.Location = New-Object System.Drawing.Point(178, 88)
$btnTimerOff.Size = New-Object System.Drawing.Size(150, 36)
$btnTimerOff.Text = "关闭定时清理"

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(20, 284)
$lblLog.Size = New-Object System.Drawing.Size(340, 20)
$lblLog.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$lblLog.Text = "运行日志"

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 308)
$txtLog.Size = New-Object System.Drawing.Size(340, 220)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical

$form.Controls.Add($lblFreeBig)
$form.Controls.Add($prgUsed)
$form.Controls.Add($lblDetail)
$form.Controls.Add($btnClean)
$form.Controls.Add($grpTimer)
$grpTimer.Controls.Add($lblTimerStatus)
$grpTimer.Controls.Add($lblInterval)
$grpTimer.Controls.Add($nudMinutes)
$grpTimer.Controls.Add($lblUnit)
$grpTimer.Controls.Add($btnApply)
$grpTimer.Controls.Add($btnTimerOn)
$grpTimer.Controls.Add($btnTimerOff)
$form.Controls.Add($lblLog)
$form.Controls.Add($txtLog)

# ---------- 逻辑 ----------

function Add-Log($msg) {
    $txtLog.AppendText("[" + (Get-Date -Format "HH:mm:ss") + "] " + $msg + "`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Refresh-Memory {
    $m = Get-MemoryMB
    $used = $m.Total - $m.Free
    $pct  = [math]::Round($used / $m.Total * 100)
    $lblFreeBig.Text = "可用 " + $m.Free + " MB"
    $lblDetail.Text  = "总计 " + $m.Total + " MB ｜ 已用 " + $used + " MB (" + $pct + "%)"
    $prgUsed.Value = [math]::Min(100, [math]::Max(0, $pct))
}

function Refresh-TimerStatus {
    $running = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -like '*memory-tool.ps1*' -and $_.CommandLine -like '*-watch*'
    }).Count -gt 0
    $autostart = Test-Path $timerLnk
    if ($running) {
        $lblTimerStatus.Text = "状态：已开启（后台运行中）"
        $btnTimerOn.Enabled  = $false
        $btnTimerOff.Enabled = $true
        if (-not $autostart) { $lblTimerStatus.Text = "状态：后台运行中（开机自启项缺失）" }
    } else {
        $lblTimerStatus.Text = "状态：未开启"
        $btnTimerOn.Enabled  = $true
        $btnTimerOff.Enabled = $false
    }
}

$btnClean.Add_Click({
    $btnClean.Enabled = $false
    $btnClean.Text    = "清理中..."
    $before = Get-MemoryMB
    $r = Clear-WorkingSet
    $after  = Get-MemoryMB
    $freed  = $after.Free - $before.Free
    Add-Log ("清理完成：成功 " + $r.Cleaned + " 个进程，跳过 " + $r.Skipped + " 个，腾出 " + $freed + " MB")
    Refresh-Memory
    $btnClean.Text    = "一键清理内存"
    $btnClean.Enabled = $true
})

$btnTimerOn.Add_Click({
    $m = [int]$nudMinutes.Value
    Stop-TimerProcess
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($timerLnk)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -watch -Minutes $m"
    $sc.WorkingDirectory = Split-Path $scriptPath
    $sc.Save()
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$scriptPath`"",'-watch','-Minutes',"$m" -WindowStyle Hidden
    Refresh-TimerStatus
    Add-Log "定时清理已开启（每 $m 分钟静默清理，开机自启）"
})

$btnTimerOff.Add_Click({
    Stop-TimerProcess
    if (Test-Path $timerLnk) { Remove-Item $timerLnk -Force }
    Refresh-TimerStatus
    Add-Log "定时清理已关闭"
})

$btnApply.Add_Click({
    $m = [int]$nudMinutes.Value
    $running = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -like '*memory-tool.ps1*' -and $_.CommandLine -like '*-watch*'
    }).Count -gt 0
    if ($running) {
        # 正在运行：用新间隔重启后台进程并更新开机自启项
        Stop-TimerProcess
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($timerLnk)
        $sc.TargetPath = 'powershell.exe'
        $sc.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -watch -Minutes $m"
        $sc.WorkingDirectory = Split-Path $scriptPath
        $sc.Save()
        Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$scriptPath`"",'-watch','-Minutes',"$m" -WindowStyle Hidden
        Refresh-TimerStatus
        Add-Log "定时间隔已改为 $m 分钟（后台已按新间隔重启）"
    } else {
        # 未开启：仅保存设置，开启时生效
        Add-Log "定时间隔已设为 $m 分钟（开启定时时生效）"
    }
})

$form.Add_Shown({
    # 读取当前生效间隔（来自开机自启项），未开启则保持默认 30
    if (Test-Path $timerLnk) {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($timerLnk)
        if ($sc.Arguments -match '-Minutes (\d+)') {
            $nudMinutes.Value = [math]::Min(720, [math]::Max(1, [int]$matches[1]))
        }
    }
    Refresh-Memory
    Refresh-TimerStatus
    Add-Log "工具已启动"
})

# 每 10 秒自动刷新内存显示
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 10000
$uiTimer.Add_Tick({ Refresh-Memory })
$uiTimer.Start()

[System.Windows.Forms.Application]::Run($form)
