# ============================================
# 一键内存优化（模拟 PCL 启动器内存优化原理）
# 原理：调用 Windows API SetProcessWorkingSetSizeEx
#       把各进程的工作集(物理内存页)换出到虚拟内存(页面文件)
# 效果：任务管理器可用内存数字明显上升
# 注意：并非真正释放内存，只是置换到硬盘；
#       系统/权限受限进程会被跳过
# ============================================

$ErrorActionPreference = 'SilentlyContinue'

# 定义 Win32 API
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

$cleaned = 0
$skipped = 0
$me = $PID

Get-Process | ForEach-Object {
    if ($_.Id -eq $me) { return }
    try {
        $handle = $_.Handle
        # 传入 -1 (uint64 最大值) 表示把工作集压缩到最小
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

Write-Output "内存优化完成: 成功 $cleaned 个, 跳过(系统/权限受限) $skipped 个"

# 弹出结果提示（3秒后自动关闭）
$msg = "内存优化完成！`n`n成功清理: $cleaned 个进程`n跳过(系统/权限受限): $skipped 个进程`n`n注意: 这是把内存换到虚拟内存, 并非真正释放"
$ws = New-Object -ComObject WScript.Shell
$null = $ws.Popup($msg, 3, "内存优化", 64)
