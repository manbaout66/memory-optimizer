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
public class Win32UI {
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);
    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();
    [DllImport("user32.dll")]
    public static extern int SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
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

# 必须在创建任何窗口前启用 DPI 感知，保证逻辑/物理坐标一致
$null = [Win32UI]::SetProcessDPIAware()

# ---------- 设计令牌 ----------
$cBg      = [System.Drawing.Color]::FromArgb(247, 248, 250)   # 页面背景
$cCard    = [System.Drawing.Color]::White                     # 卡片背景
$cPrimary = [System.Drawing.Color]::FromArgb(47, 107, 255)    # 主色（蓝）
$cPrimaryHover = [System.Drawing.Color]::FromArgb(36, 85, 214)
$cPrimaryDown  = [System.Drawing.Color]::FromArgb(30, 71, 184)
$cText    = [System.Drawing.Color]::FromArgb(26, 27, 28)      # 主文本
$cSub     = [System.Drawing.Color]::FromArgb(107, 114, 128)   # 次文本
$cBorder  = [System.Drawing.Color]::FromArgb(228, 231, 236)   # 卡片描边
$cBarBg   = [System.Drawing.Color]::FromArgb(238, 241, 245)   # 进度条底
$cGreen   = [System.Drawing.Color]::FromArgb(34, 197, 94)     # 运行中
$cGray    = [System.Drawing.Color]::FromArgb(156, 163, 175)   # 未开启
$cDanger  = [System.Drawing.Color]::FromArgb(220, 38, 38)     # 关闭按钮悬停
$cDangerBg= [System.Drawing.Color]::FromArgb(254, 226, 226)

# ---------- 绘制辅助 ----------

function New-RoundedPath($x, $y, $w, $h, $r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

# 圆角卡片（白底 + 浅描边）
function New-Card($x, $y, $w, $h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.BackColor = $cBg
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $path = New-RoundedPath 0 0 ($s.Width - 1) ($s.Height - 1) 12
        $g.FillPath((New-Object System.Drawing.SolidBrush($cCard)), $path)
        $g.DrawPath((New-Object System.Drawing.Pen($cBorder)), $path)
        $path.Dispose()
    })
    return $p
}

# 扁平化按钮
function Set-FlatButton($btn, $bg, $hover, $down, $fg, $borderColor) {
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.FlatAppearance.MouseOverBackColor = $hover
    $btn.FlatAppearance.MouseDownBackColor = $down
    $btn.BackColor = $bg
    $btn.ForeColor = $fg
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.UseVisualStyleBackColor = $false
    if ($borderColor) {
        $btn.FlatAppearance.BorderSize = 1
        $btn.FlatAppearance.BorderColor = $borderColor
    }
}

# 窗口可拖动
function Enable-Drag($ctl) {
    $ctl.Add_MouseDown({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $null = [Win32UI]::ReleaseCapture()
            $null = [Win32UI]::SendMessage($form.Handle, 0xA1, 0x2, 0)
        }
    })
}

# ---------- 窗口 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "内存优化工具"
$form.Size = New-Object System.Drawing.Size(420, 700)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.BackColor = $cBg
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.Region = [System.Drawing.Region]::FromHrgn([Win32UI]::CreateRoundRectRgn(0, 0, 420, 700, 16, 16))

# ---------- 自定义标题栏 ----------
$titleBar = New-Object System.Windows.Forms.Panel
$titleBar.Location = New-Object System.Drawing.Point(0, 0)
$titleBar.Size = New-Object System.Drawing.Size(420, 52)
$titleBar.BackColor = $cBg

$lblLogo = New-Object System.Windows.Forms.Label
$lblLogo.Location = New-Object System.Drawing.Point(20, 17)
$lblLogo.Size = New-Object System.Drawing.Size(14, 18)
$lblLogo.Text = "●"
$lblLogo.ForeColor = $cPrimary
$lblLogo.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point(40, 15)
$lblTitle.Size = New-Object System.Drawing.Size(160, 22)
$lblTitle.Text = "内存优化工具"
$lblTitle.ForeColor = $cText
$lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Bold)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Location = New-Object System.Drawing.Point(155, 19)
$lblVersion.Size = New-Object System.Drawing.Size(60, 16)
$lblVersion.Text = "v1.2"
$lblVersion.ForeColor = $cSub
$lblVersion.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Location = New-Object System.Drawing.Point(374, 8)
$btnClose.Size = New-Object System.Drawing.Size(34, 34)
$btnClose.Text = "✕"
$btnClose.Font = New-Object System.Drawing.Font("Segoe UI", 10)
Set-FlatButton $btnClose $cBg $cDangerBg $cDangerBg $cSub $null
$btnClose.Add_Click({ $form.Close() })
$btnClose.Add_MouseEnter({ $btnClose.ForeColor = $cDanger })
$btnClose.Add_MouseLeave({ $btnClose.ForeColor = $cSub })

$titleBar.Controls.Add($lblLogo)
$titleBar.Controls.Add($lblTitle)
$titleBar.Controls.Add($lblVersion)
$titleBar.Controls.Add($btnClose)
Enable-Drag $titleBar
Enable-Drag $lblLogo
Enable-Drag $lblTitle
Enable-Drag $lblVersion

# ---------- 内存状态卡片 ----------
$cardMem = New-Card 20 64 380 150

$lblMemLabel = New-Object System.Windows.Forms.Label
$lblMemLabel.Location = New-Object System.Drawing.Point(28, 20)
$lblMemLabel.Size = New-Object System.Drawing.Size(200, 16)
$lblMemLabel.Text = "可用物理内存"
$lblMemLabel.ForeColor = $cSub
$lblMemLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$lblFreeBig = New-Object System.Windows.Forms.Label
$lblFreeBig.Location = New-Object System.Drawing.Point(26, 40)
$lblFreeBig.Size = New-Object System.Drawing.Size(280, 40)
$lblFreeBig.Text = "-- MB"
$lblFreeBig.ForeColor = $cText
$lblFreeBig.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 22, [System.Drawing.FontStyle]::Bold)

$prgPanel = New-Object System.Windows.Forms.Panel
$prgPanel.Location = New-Object System.Drawing.Point(28, 92)
$prgPanel.Size = New-Object System.Drawing.Size(324, 16)
$prgPanel.BackColor = $cCard
$prgPanel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $bg = New-RoundedPath 1 1 ($s.Width - 2) ($s.Height - 2) 7
    $g.FillPath((New-Object System.Drawing.SolidBrush($cBarBg)), $bg)
    $bg.Dispose()
    $pct = [math]::Min(100, [math]::Max(0, $script:uiPct))
    if ($pct -gt 0) {
        $fw = [math]::Max(8, [int](($s.Width - 4) * $pct / 100))
        $fg = New-RoundedPath 2 2 $fw ($s.Height - 4) 6
        $g.FillPath((New-Object System.Drawing.SolidBrush($cPrimary)), $fg)
        $fg.Dispose()
    }
})

$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Location = New-Object System.Drawing.Point(28, 116)
$lblDetail.Size = New-Object System.Drawing.Size(324, 18)
$lblDetail.ForeColor = $cSub
$lblDetail.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8.5)

$cardMem.Controls.Add($lblMemLabel)
$cardMem.Controls.Add($lblFreeBig)
$cardMem.Controls.Add($prgPanel)
$cardMem.Controls.Add($lblDetail)

# ---------- 一键清理按钮 ----------
$btnClean = New-Object System.Windows.Forms.Button
$btnClean.Location = New-Object System.Drawing.Point(20, 226)
$btnClean.Size = New-Object System.Drawing.Size(380, 48)
$btnClean.Text = "一键清理内存"
$btnClean.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10.5, [System.Drawing.FontStyle]::Bold)
Set-FlatButton $btnClean $cPrimary $cPrimaryHover $cPrimaryDown ([System.Drawing.Color]::White) $null

# ---------- 定时清理卡片 ----------
$cardTimer = New-Card 20 286 380 190

$lblTimerTitle = New-Object System.Windows.Forms.Label
$lblTimerTitle.Location = New-Object System.Drawing.Point(24, 18)
$lblTimerTitle.Size = New-Object System.Drawing.Size(80, 18)
$lblTimerTitle.Text = "定时清理"
$lblTimerTitle.ForeColor = $cText
$lblTimerTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)

$lblBadge = New-Object System.Windows.Forms.Label
$lblBadge.Location = New-Object System.Drawing.Point(110, 19)
$lblBadge.Size = New-Object System.Drawing.Size(200, 16)
$lblBadge.Text = "● 检查中..."
$lblBadge.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Location = New-Object System.Drawing.Point(24, 56)
$lblInterval.Size = New-Object System.Drawing.Size(36, 24)
$lblInterval.Text = "间隔"
$lblInterval.ForeColor = $cSub

$nudMinutes = New-Object System.Windows.Forms.NumericUpDown
$nudMinutes.Location = New-Object System.Drawing.Point(64, 52)
$nudMinutes.Size = New-Object System.Drawing.Size(64, 28)
$nudMinutes.Minimum = 1
$nudMinutes.Maximum = 720
$nudMinutes.Value = 30
$nudMinutes.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$lblUnit = New-Object System.Windows.Forms.Label
$lblUnit.Location = New-Object System.Drawing.Point(134, 56)
$lblUnit.Size = New-Object System.Drawing.Size(36, 24)
$lblUnit.Text = "分钟"
$lblUnit.ForeColor = $cSub

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Location = New-Object System.Drawing.Point(180, 50)
$btnApply.Size = New-Object System.Drawing.Size(172, 30)
$btnApply.Text = "应用间隔"
$btnApply.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
Set-FlatButton $btnApply $cCard ([System.Drawing.Color]::FromArgb(239, 244, 255)) ([System.Drawing.Color]::FromArgb(219, 232, 255)) $cPrimary $cPrimary

$btnTimerOn = New-Object System.Windows.Forms.Button
$btnTimerOn.Location = New-Object System.Drawing.Point(24, 96)
$btnTimerOn.Size = New-Object System.Drawing.Size(160, 40)
$btnTimerOn.Text = "开启定时清理"
$btnTimerOn.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)
Set-FlatButton $btnTimerOn $cPrimary $cPrimaryHover $cPrimaryDown ([System.Drawing.Color]::White) $null

$btnTimerOff = New-Object System.Windows.Forms.Button
$btnTimerOff.Location = New-Object System.Drawing.Point(196, 96)
$btnTimerOff.Size = New-Object System.Drawing.Size(160, 40)
$btnTimerOff.Text = "关闭定时清理"
$btnTimerOff.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)
Set-FlatButton $btnTimerOff $cCard ([System.Drawing.Color]::FromArgb(254, 226, 226)) ([System.Drawing.Color]::FromArgb(252, 200, 200)) $cDanger $null

$lblTimerTip = New-Object System.Windows.Forms.Label
$lblTimerTip.Location = New-Object System.Drawing.Point(24, 148)
$lblTimerTip.Size = New-Object System.Drawing.Size(332, 28)
$lblTimerTip.Text = "开启后后台静默运行，关机前一直生效，并随开机自动启动"
$lblTimerTip.ForeColor = $cSub
$lblTimerTip.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)

$cardTimer.Controls.Add($lblTimerTitle)
$cardTimer.Controls.Add($lblBadge)
$cardTimer.Controls.Add($lblInterval)
$cardTimer.Controls.Add($nudMinutes)
$cardTimer.Controls.Add($lblUnit)
$cardTimer.Controls.Add($btnApply)
$cardTimer.Controls.Add($btnTimerOn)
$cardTimer.Controls.Add($btnTimerOff)
$cardTimer.Controls.Add($lblTimerTip)

# ---------- 日志区 ----------
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(20, 488)
$lblLog.Size = New-Object System.Drawing.Size(380, 18)
$lblLog.Text = "运行日志"
$lblLog.ForeColor = $cSub
$lblLog.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$cardLog = New-Card 20 510 380 156
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(14, 10)
$txtLog.Size = New-Object System.Drawing.Size(352, 136)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtLog.BackColor = $cCard
$txtLog.ForeColor = $cText
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$cardLog.Controls.Add($txtLog)

# ---------- 组装 ----------
$form.Controls.Add($titleBar)
$form.Controls.Add($cardMem)
$form.Controls.Add($btnClean)
$form.Controls.Add($cardTimer)
$form.Controls.Add($lblLog)
$form.Controls.Add($cardLog)

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
    $script:uiPct = $pct
    $lblFreeBig.Text = $m.Free.ToString("N0") + " MB"
    $lblDetail.Text  = "总计 " + $m.Total.ToString("N0") + " MB  ｜  已用 " + $used.ToString("N0") + " MB (" + $pct + "%)"
    $prgPanel.Invalidate()
}

function Refresh-TimerStatus {
    $running = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -like '*memory-tool.ps1*' -and $_.CommandLine -like '*-watch*'
    }).Count -gt 0
    $autostart = Test-Path $timerLnk
    if ($running) {
        $lblBadge.Text = "● 运行中"
        $lblBadge.ForeColor = $cGreen
        $btnTimerOn.Enabled  = $false
        $btnTimerOff.Enabled = $true
        if (-not $autostart) { $lblBadge.Text = "● 运行中（自启缺失）" }
    } else {
        $lblBadge.Text = "● 未开启"
        $lblBadge.ForeColor = $cGray
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
        Add-Log "定时间隔已设为 $m 分钟（开启定时时生效）"
    }
})

$form.Add_Shown({
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

$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 10000
$uiTimer.Add_Tick({ Refresh-Memory })
$uiTimer.Start()

[System.Windows.Forms.Application]::Run($form)
