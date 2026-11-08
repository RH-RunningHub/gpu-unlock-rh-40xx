# ============================================================
# Phase 0 前置检查 —— RTX 4090 D Windows 热重启解锁
# 用法(管理员 PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\phase0-admin-prep.ps1          # 只读体检
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\phase0-admin-prep.ps1 -Apply   # 体检 + 关闭快速启动
# 产物: 脚本同目录 phase0-report.txt
# 本脚本不重启、不改启动项、不动分区;除 -Apply 关快速启动外无任何系统变更。
# ============================================================
param([switch]$Apply)
$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]
function Log($t) { $lines.Add($t); Write-Host $t }
function Sec($t) { Log ""; Log "==== $t ====" }

# --- 管理员自检 ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log "管理员权限: $isAdmin"
if (-not $isAdmin) { Log "!! 请以管理员身份运行(右键 PowerShell -> 管理员)。本报告不完整。"; }

Sec "1. Secure Boot"
try { Log ("Secure Boot = " + (Confirm-SecureBootUEFI)) }
catch { Log "读取失败: $($_.Exception.Message)" }
Log "要求: False(关闭)。稳定后可参照 goldlionren/4080s 自签证书路径回到开启。"

Sec "2. BitLocker"
try {
  $bl = Get-BitLockerVolume
  if ($bl) {
    $bl | ForEach-Object { Log ("{0}  {1}  Protection={2}" -f $_.MountPoint, $_.VolumeStatus, $_.ProtectionStatus) }
    $sys = $bl | Where-Object { $_.MountPoint -like "*:" -and $_.VolumeStatus -ne 'FullyDecrypted' } | Where-Object { (Get-Volume -DriveLetter $_.MountPoint.TrimEnd(':') -ErrorAction SilentlyContinue).DriveType -eq 'Fixed' -and $_.ProtectionStatus -eq 'On' }
    if ($sys) { Log "!! 存在 BitLocker 保护卷: 改启动项顺序前必须 Suspend-BitLocker(重启计数型挂起)或解密, 否则触发恢复界面。" }
  } else { Log "无 BitLocker 卷 (OK)" }
} catch { Log "读取失败: $($_.Exception.Message)" }

Sec "3. 快速启动 / 休眠"
$hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
Log ("HiberbootEnabled(快速启动) = {0}  要求: 0" -f $(if ($null -ne $hb) { $hb } else { '(未设置, 默认按1处理)' }))
$hv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HibernateEnabled
Log ("HibernateEnabled = $hv (休眠总开关)")
if ($Apply) {
  Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
  Log "已应用: HiberbootEnabled = 0"
} elseif ($hb -ne 0) {
  Log "!! 需要关闭: 以 -Apply 重跑, 或手动: Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0"
}
Log "边界提示: S3 睡眠唤醒后解锁丢失(pre-OS 方案通病), 重启即恢复。"

Sec "4. 固件启动项(现状)"
try {
  $fw = (bcdedit /enum '{fwbootmgr}') -join "`n"
  $fw -split "`n" | Select-String -Pattern 'identifier|description|path' | Select-Object -First 15 | ForEach-Object { Log $_.Line.Trim() }
  Log "---- displayorder ----"
  (bcdedit /enum '{fwbootmgr}') | Select-String -Context 0,8 -Pattern 'displayorder' | ForEach-Object { $_.Context.PostContext } | ForEach-Object { Log $_.Trim() }
} catch { Log "bcdedit 读取失败: $($_.Exception.Message)" }
Log "安装器将把 'GPU Unlock (auto)' 置顶于此; 先留档现状以便回退对照。"

Sec "5. GPU 与驱动"
try {
  $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' }
  $gpu | ForEach-Object { Log ("{0}  Driver={1}  PNP={2}" -f $_.Name, $_.DriverVersion, $_.PNPDeviceID) }
  if ($gpu.PNPDeviceID -notmatch 'DEV_2685') { Log "!! 未检测到 DEV_2685 (RTX 4090 D) — 确认目标卡。" }
  Log "驱动 617.14 未被底座测过(底座验证于 610.88, 家族 581/610/616 多版本接受) — 列入验收观察项。"
} catch { Log "读取失败: $($_.Exception.Message)" }

Sec "6. 分区空间(installer partition 模式需让出 304MiB)"
try {
  Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object {
    $v = Get-Volume -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue
    if ($v -and $v.FileSystem -eq 'NTFS') {
      $d = Get-Disk -Number $_.DiskNumber
      Log ("{0}: NTFS  剩余 {1:N0} MB  磁盘{2} {3}  GPT={4}  分区表类型={5}" -f $_.DriveLetter, [math]::Round($v.SizeRemaining/1MB), $_.DiskNumber, $d.FriendlyName, ($d.PartitionStyle -eq 'GPT'), $d.PartitionStyle)
    }
  }
  Log "条件: GPT + NTFS + 可缩 >304MiB; C: 为 BitLocker 时会命中上面第2节的告警。"
} catch { Log "读取失败: $($_.Exception.Message)" }

Sec "7. 需要进 BIOS 手工确认的项(Windows 读不到)"
Log "主板: $((Get-CimInstance Win32_BaseBoard).Manufacturer) $((Get-CimInstance Win32_BaseBoard).Product)  BIOS $((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)"
Log "  [ ] Above 4G Decoding = 开"
Log "  [ ] Fast Boot = 关"
Log "  [ ] Secure Boot = 关(第一轮)"
Log "  [ ] 主显示输出接在 RTX 4090 D 上(GOP 交接要求)"

$report = Join-Path $PSScriptRoot 'phase0-report.txt'
$lines | Out-File -FilePath $report -Encoding utf8
Log ""
Log "报告已写入: $report"
