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
#     -deepclean     : PCL 模式深度优化一次（需管理员，7 项系统级操作）
# ============================================
# v1.3.2 修复：修复 Timer 事件回调变量解析导致"不能对Null表达式调用方法"异常弹窗
#            （GetNewClosure 显式闭包 + 全局异常捕获写日志 + 全链路 null 防御 + Clear-WorkingSet return bug）

param(
    [switch]$Info,
    [switch]$Schedule,
    [switch]$Stop,
    [switch]$Watch,
    [switch]$Silent,
    [switch]$DeepClean,
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

    // PCL 深度优化核心：NT 内核系统信息调用
    [DllImport("ntdll.dll")]
    public static extern uint NtSetSystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);

    // 标准特权启用（advapi32）：行为稳定，比 RtlAdjustPrivilege 可靠
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    // SystemInformationClass（来自 PCL NtInterop）
    public const int SystemMemoryListInformation = 80;               // 内存列表操作（清工作集/修改页/待机页）
    public const int SystemFileCacheInformationEx = 81;              // 文件缓存
    public const int SystemCombinePhysicalMemoryInformation = 130;   // 合并物理内存
    public const int SystemRegistryReconciliationInformation = 155;  // 注册表对账

    public const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
    public const uint TOKEN_QUERY = 0x8;
    public const uint SE_PRIVILEGE_ENABLED = 0x2;

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }

    public static uint EnablePrivilege(string privilegeName) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) {
            return (uint)Marshal.GetLastWin32Error();
        }
        LUID luid;
        if (!LookupPrivilegeValue(null, privilegeName, out luid)) {
            return (uint)Marshal.GetLastWin32Error();
        }
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Luid = luid;
        tp.Attributes = SE_PRIVILEGE_ENABLED;
        bool ok = AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        uint err = (uint)Marshal.GetLastWin32Error();
        if (!ok) return err;
        return err == 0 ? 0 : err;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_FILECACHE_INFORMATION {
        public UIntPtr CurrentSize;
        public UIntPtr PeakSize;
        public UIntPtr PageFaultCount;
        public UIntPtr MinimumWorkingSet;
        public UIntPtr MaximumWorkingSet;
        public UIntPtr CurrentSizeIncludingTransitionInPages;
        public UIntPtr PeakSizeIncludingTransitionInPages;
        public UIntPtr TransitionRePurposeCount;
        public UIntPtr Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_COMBINE_INFORMATION_EX {
        public IntPtr Handle;
        public UIntPtr PagesCombined;
        public uint Flags;
    }
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

# 获取当前物理内存状态（MB）；CIM 查询失败时返回 0 兜底，绝不让调用方拿到 null
function Get-MemoryMB {
    $os = Get-CimInstance Win32_OperatingSystem
    if (-not $os) { return @{ Free = 0; Total = 0 } }
    $free  = $os.FreePhysicalMemory
    $total = $os.TotalVisibleMemorySize
    if ($null -eq $free)  { $free = 0 }
    if ($null -eq $total) { $total = 0 }
    return @{
        Free  = [math]::Round([double]$free / 1024)
        Total = [math]::Round([double]$total / 1024)
    }
}

# 清空所有可访问进程的工作集
function Clear-WorkingSet {
    $cleaned = 0
    $skipped = 0
    $me = $PID
    Get-Process | ForEach-Object {
        # 注意：不能在此 scriptblock 中使用 return/continue（PS 5.1 会提前退出函数或报错），用 if 包裹
        if ($_.Id -ne $me) {
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
    }
    [GC]::Collect()
    return @{ Cleaned = $cleaned; Skipped = $skipped }
}

# 当前进程是否管理员（深度优化需要）
function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 启用深度优化所需的内核权限（需管理员令牌）
function Enable-MemPrivileges {
    $null = [MemOptimizer]::EnablePrivilege("SeProfileSingleProcessPrivilege")
    $null = [MemOptimizer]::EnablePrivilege("SeIncreaseQuotaPrivilege")
}

# 内存列表操作：2=清空工作集 3=刷新修改页 4=清除备用页 5=清除低优先级备用页
function Invoke-MemoryListOp([int]$op) {
    $bytes = [BitConverter]::GetBytes($op)
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    try {
        [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, 4)
        $null = [MemOptimizer]::NtSetSystemInformation([MemOptimizer]::SystemMemoryListInformation, $ptr, 4)
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
    }
}

# PCL 深度优化：7 个系统级操作（需管理员）
# 返回腾出的可用内存 MB
function Invoke-PclDeepClean {
    Enable-MemPrivileges
    $before = (Get-MemoryMB).Free

    # 1. 清空所有进程工作集（系统级）
    Invoke-MemoryListOp 2

    # 2. 刷新文件缓存（把文件缓存页强制换出）
    $scfi = New-Object MemOptimizer+SYSTEM_FILECACHE_INFORMATION
    $scfi.MaximumWorkingSet = [UIntPtr]::new([uint64]::MaxValue)
    $scfi.MinimumWorkingSet = [UIntPtr]::new([uint64]::MaxValue)
    $sz1 = [Runtime.InteropServices.Marshal]::SizeOf($scfi)
    $ptr1 = [Runtime.InteropServices.Marshal]::AllocHGlobal($sz1)
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($scfi, $ptr1, $false)
        $null = [MemOptimizer]::NtSetSystemInformation([MemOptimizer]::SystemFileCacheInformationEx, $ptr1, $sz1)
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr1)
    }

    # 3. 刷新修改页列表（脏页写回磁盘）
    Invoke-MemoryListOp 3

    # 4. 清除备用页列表（standby 缓存 —— 可用内存大幅提升的关键）
    Invoke-MemoryListOp 4

    # 5. 清除低优先级备用页
    Invoke-MemoryListOp 5

    # 6. 注册表对账
    $null = [MemOptimizer]::NtSetSystemInformation([MemOptimizer]::SystemRegistryReconciliationInformation, [IntPtr]::Zero, 0)

    # 7. 合并物理内存页（内存压缩）
    $comb = New-Object MemOptimizer+MEMORY_COMBINE_INFORMATION_EX
    $sz2 = [Runtime.InteropServices.Marshal]::SizeOf($comb)
    $ptr2 = [Runtime.InteropServices.Marshal]::AllocHGlobal($sz2)
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($comb, $ptr2, $false)
        $null = [MemOptimizer]::NtSetSystemInformation([MemOptimizer]::SystemCombinePhysicalMemoryInformation, $ptr2, $sz2)
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr2)
    }

    [GC]::Collect()
    Start-Sleep -Milliseconds 600
    $after = (Get-MemoryMB).Free
    return [math]::Max(0, $after - $before)
}

# 弹出提示框（seconds 秒后自动关闭）
function Show-Popup($text, $seconds) {
    $ws = New-Object -ComObject WScript.Shell
    $null = $ws.Popup($text, $seconds, "内存优化", 64)
}

# 停止正在运行的定时清理后台进程
function Stop-TimerProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine -like '*memory-tool.ps1*' -and $_.CommandLine -like '*-watch*'
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 路径 ----------
$scriptPath = $MyInvocation.MyCommand.Path
$startupDir = [Environment]::GetFolderPath('Startup')
$timerLnk   = Join-Path $startupDir '内存定时清理.lnk'

# ---------- 命令行模式 ----------

# 深度优化一次（PCL 模式，需管理员；由 GUI 提权调用或命令行手动执行）
if ($DeepClean) {
    if (-not (Test-IsAdmin)) {
        Show-Popup "深度优化需要管理员权限，请以管理员身份运行", 5
        exit 1
    }
    $freed = Invoke-PclDeepClean
    Show-Popup "深度优化完成，腾出 $freed MB 可用内存", 6
    exit
}

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

# 全局异常捕获：GUI 线程未处理异常写日志文件（带完整堆栈，便于定位）
$errLogPath = Join-Path (Split-Path $scriptPath) 'memory-tool-error.log'
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        try { Add-Content -Path $errLogPath -Value ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $e.Exception.ToString()) -Encoding UTF8 } catch {}
    })
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $e)
        try { Add-Content -Path $errLogPath -Value ("[DOMAIN " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $e.ExceptionObject.ToString()) -Encoding UTF8 } catch {}
    })
} catch {}

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
$lblVersion.Text = "v1.3.2"
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
    if (-not $txtLog) { return }
    try {
        $txtLog.AppendText("[" + (Get-Date -Format "HH:mm:ss") + "] " + $msg + "`r`n")
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    } catch {}
}

function Refresh-Memory {
    $m = Get-MemoryMB
    if (-not $m -or $null -eq $m.Free -or $null -eq $m.Total) { $m = @{ Free = 0; Total = 0 } }
    $used = $m.Total - $m.Free
    $pct  = 0
    if ($m.Total -gt 0) { $pct = [math]::Round($used / $m.Total * 100) }
    $script:uiPct = $pct
    $lblFreeBig.Text = ([double]$m.Free).ToString("N0") + " MB"
    $lblDetail.Text  = "总计 " + ([double]$m.Total).ToString("N0") + " MB  ｜  已用 " + ([double]$used).ToString("N0") + " MB (" + $pct + "%)"
    $prgPanel.Invalidate()
}

function Refresh-TimerStatus {
    # 双保险检测：进程 + 启动项；@() 保证结果一定是数组（避免单对象/空结果的 Count 陷阱）
    $watchProc = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine -like '*memory-tool.ps1*' -and $_.CommandLine -like '*-watch*'
    })
    $running = $watchProc.Count -gt 0
    $autostart = Test-Path $timerLnk
    if ($running) {
        $lblBadge.Text = "● 运行中"
        $lblBadge.ForeColor = $cGreen
        if (-not $autostart) { $lblBadge.Text = "● 运行中（自启缺失）" }
    } else {
        $lblBadge.Text = "● 未开启"
        $lblBadge.ForeColor = $cGray
    }
    # 开启按钮仅在未运行时可用；关闭按钮始终可用（幂等清理，避免 WMI 延迟导致按钮置灰点不了）
    $btnTimerOn.Enabled  = -not $running
    $btnTimerOff.Enabled = $true
}

$btnClean.Add_Click({
    $btnClean.Enabled = $false
    $btnClean.Text    = "优化中..."
    try {
        if (Test-IsAdmin) {
            # 已是管理员：直接执行 PCL 深度优化
            $freed = Invoke-PclDeepClean
            Add-Log ("深度优化完成：腾出 " + $freed + " MB（清工作集+文件缓存+待机页+内存合并）")
            Refresh-Memory
            $btnClean.Text    = "一键清理内存"
            $btnClean.Enabled = $true
        } else {
            # 普通权限：请求提权执行深度优化
            Add-Log "深度优化需要管理员权限，正在请求提权（UAC 弹窗请点“是”）..."
            try {
                Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"",'-deepclean' -WindowStyle Hidden | Out-Null
                Add-Log "已提交深度优化，完成后将自动刷新"
            } catch {
                Add-Log "提权被取消，已回退为普通清理"
                $r = Clear-WorkingSet
                if ($r) {
                    Add-Log ("普通清理：成功 " + $r.Cleaned + " 个进程，跳过 " + $r.Skipped + " 个")
                } else {
                    Add-Log "普通清理完成"
                }
            }
            # 3 秒后刷新内存读数并恢复按钮（给提权进程留出执行时间）
            # 注意：Add_Tick 回调必须 GetNewClosure() 显式闭包捕获 $rf，
            # 否则 PowerShell 5.1 事件回调可能解析不到局部变量（$rf=$null → $null.Stop() 报"不能对Null值表达式调用方法"）
            $rf = New-Object System.Windows.Forms.Timer
            $rf.Interval = 3000
            $rf.Add_Tick({
                try {
                    $rf.Stop()
                    Refresh-Memory
                } catch {
                    try { Add-Content -Path $errLogPath -Value ("[RF " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $_.Exception.ToString()) -Encoding UTF8 } catch {}
                }
                # 无论是否异常都恢复按钮，避免卡在"优化中..."
                $btnClean.Text    = "一键清理内存"
                $btnClean.Enabled = $true
            }.GetNewClosure())
            $rf.Start()
        }
    } catch {
        # 事件级兜底：任何未预期异常写入错误日志并恢复按钮
        try { Add-Content -Path $errLogPath -Value ("[CLEAN " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $_.Exception.ToString()) -Encoding UTF8 } catch {}
        Add-Log ("一键清理异常：" + $_.Exception.Message)
        $btnClean.Text    = "一键清理内存"
        $btnClean.Enabled = $true
    }
})

$btnTimerOn.Add_Click({
    $m = [int]$nudMinutes.Value
    Stop-TimerProcess
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($timerLnk)
        if (-not $sc) { throw "创建快捷方式失败" }
        $sc.TargetPath = 'powershell.exe'
        $sc.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -watch -Minutes $m"
        $sc.WorkingDirectory = Split-Path $scriptPath
        $sc.Save()
    } catch {
        Add-Log ("开启失败：" + $_.Exception.Message)
        return
    }
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$scriptPath`"",'-watch','-Minutes',"$m" -WindowStyle Hidden
    Add-Log "定时清理已开启（每 $m 分钟静默清理，开机自启）"
    # 延迟刷新：WMI 进程快照有延迟，立即查询可能查不到刚启动的后台进程
    $st = New-Object System.Windows.Forms.Timer
    $st.Interval = 1500
    $st.Add_Tick({ $st.Stop(); Refresh-TimerStatus }.GetNewClosure())
    $st.Start()
})

$btnTimerOff.Add_Click({
    Stop-TimerProcess
    if (Test-Path $timerLnk) { Remove-Item $timerLnk -Force }
    Add-Log "定时清理已关闭"
    # 延迟刷新：避免 WMI 缓存残留导致刚杀掉的进程仍被检测到
    $st = New-Object System.Windows.Forms.Timer
    $st.Interval = 800
    $st.Add_Tick({ $st.Stop(); Refresh-TimerStatus }.GetNewClosure())
    $st.Start()
})

$btnApply.Add_Click({
    $m = [int]$nudMinutes.Value
    $watchProc = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine -like '*memory-tool.ps1*' -and $_.CommandLine -like '*-watch*'
    })
    if ($watchProc.Count -gt 0) {
        Stop-TimerProcess
        try {
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($timerLnk)
            if (-not $sc) { throw "创建快捷方式失败" }
            $sc.TargetPath = 'powershell.exe'
            $sc.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -watch -Minutes $m"
            $sc.WorkingDirectory = Split-Path $scriptPath
            $sc.Save()
        } catch {
            Add-Log ("应用间隔失败：" + $_.Exception.Message)
            return
        }
        Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$scriptPath`"",'-watch','-Minutes',"$m" -WindowStyle Hidden
        Add-Log "定时间隔已改为 $m 分钟（后台已按新间隔重启）"
        # 延迟刷新，避开 WMI 快照延迟
        $st = New-Object System.Windows.Forms.Timer
        $st.Interval = 1500
        $st.Add_Tick({ $st.Stop(); Refresh-TimerStatus }.GetNewClosure())
        $st.Start()
    } else {
        Add-Log "定时间隔已设为 $m 分钟（开启定时时生效）"
    }
})

$form.Add_Shown({
    if (Test-Path $timerLnk) {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($timerLnk)
        if ($sc -and $sc.Arguments -match '-Minutes (\d+)') {
            $nudMinutes.Value = [math]::Min(720, [math]::Max(1, [int]$matches[1]))
        }
    }
    Refresh-Memory
    Refresh-TimerStatus
    Add-Log "工具已启动"
})

$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 10000
$uiTimer.Add_Tick({ Refresh-Memory; Refresh-TimerStatus })
$uiTimer.Start()

[System.Windows.Forms.Application]::Run($form)
