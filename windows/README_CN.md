# 🪟 Windows 4090D 解锁 —— 单机

[English](./README.md) | [简体中文](./README_CN.md)

本目录在本仓库原有内容旁边增加一条 **Windows 10/11 路径**。

- 仓库根目录的 **Linux 侧**（hooks/scripts）是 **Ubuntu 20.04/22.04 GPU 服务器的批量部署**：DKMS 内核模块 + 补丁固件 + initramfs hooks + GRUB `gpu_unlock.*` 参数，一次普通重启整批激活。
- 本目录的 **Windows 侧**是 **RTX 4090 D（`10de:2685`）单机解锁**：一个未签名的 UEFI preboot 程序在**每次开机**（冷启动或重启） NVIDIA 驱动绑定之前运行，重放一次易失性解锁后交还 Windows。不刷 VBIOS、不改驱动，断电即回原厂。

> **状态：首个公开发布的 4090 D Windows 解锁。** 单机端到端验证——ASUS TUF GAMING B460M-PLUS (WI-FI, BIOS 0708) + MSI RTX 4090 D 24GB，Windows 11 专业版 23H2 (22631)，驱动 617.14——三次开机零失败：只读登记（`RUN00`）→ 一次性武装试解锁（`RUN01`，选择器 `SS0=0x88888888 / SS1=0x8`，跨越 FLR 与 GOP 交还均验证通过）→ 常驻自动模式（`RUN02`，无手动武装，`FINAL status=0 stage=post-unlock-handoff clean=1`）。按实验性对待：一张卡、一块主板、一个驱动版本。

## Linux 与 Windows 一览

| | Linux（仓库根目录） | Windows（本目录） |
|---|---|---|
| 目标 | 4090 + 4090D 服务器，整批部署 | 4090 D 台式机，单机 |
| 机制 | DKMS 内核模块 + initramfs hooks + GRUB | UEFI preboot 程序 + 固件启动项（排在最前） |
| 生效时机 | 每次开机一次，nvidia 绑定前 | 每次开机一次，驱动绑定前 |
| 最坏情况 | 干净的 `-16`/`-2` 安全失败 | 安全中止 → 照常进 Windows 原厂；极端挂死 → 长按电源，固件菜单选 "Windows Boot Manager" |
| 回滚 | 删 2 个 GRUB 参数 / `dpkg -r` | `core.ps1 disable` → `uninstall`（分区精确恢复原大小） |

## 目录内容

| 文件 | 说明 |
|---|---|
| `2685-port.patch` | 移植本体：相对 [`Zihao-Wu06/gpu-unlock-for-windows`](https://github.com/Zihao-Wu06/gpu-unlock-for-windows) HEAD `0075edde` 共 3 个文件 +50/−13 行——芯片表条目 `{0x2685,0x192,"GeForce RTX 4090 D",24512,24576,FALSE}`、manifest 2685 条目、离线输入适配（见供应链一节） |
| `payload/gpuunlock.efi` | 预构建 2685 EFI（96,256 字节，SHA-256 `b27ac31ecfa9d9592e1e53fecf199ab011a8d7c163b44b95ff8d16208ce212a9`）。GPL-2.0-only，源码 = Zihao 树 + 补丁；构建可逐字节复现（未改码的树复现作者发布物 `e2780f1a…` 完全一致） |
| `preflight.ps1` | 管理员预检：Secure Boot / BitLocker / 快速启动 / 固件启动项存档 / 可缩卷候选。`-Apply` 关闭 Windows 快速启动 |
| `README.md` | 英文版 |

## 操作流程（partition 模式，无需 U 盘）

1. 管理员运行 `preflight.ps1`（先只读体检，再 `-Apply` 关快速启动）。前置：UEFI、Secure Boot **关**、BitLocker **关**（或挂起）、Windows 快速启动 **关**、GPT 盘上有可缩 304MiB 的 NTFS 卷。
2. 克隆上游树、打补丁，然后二选一：用预构建 EFI，或自行重编（Zig 0.15.2，`python efi/windows/build.py generic`；未改码的树可逐字节复现发布物——先验证再信任你的工具链）：
   ```powershell
   git clone https://github.com/Zihao-Wu06/gpu-unlock-for-windows
   cd gpu-unlock-for-windows
   git apply <路径>\2685-port.patch
   copy <路径>\payload\gpuunlock.efi installer\payload\gpuunlock.efi   # 或重编; manifest 的 efi.sha256 已随补丁改为 b27ac31e…
   ```
3. 安装（提权）：`installer\core.ps1 install -Mode partition -Yes -NoPause -AcceptExperimental -Lang zh`——再次预检、从哈希钉值的 NVIDIA 输入本地生成五个 AD102 固件资产、缩约 304MiB 建隐藏 FAT32 分区 `GPUAUTO`、复制程序与资产、把 `GPU Unlock (auto)` 启动项放到固件启动顺序**最前**。
4. 重启 **1 —— 仅登记**：程序只读显卡并写 `PROFILE.TXT`（日志：`FINAL stage=enrolled-experimental attempted=0`），对卡零写入。
5. 武装一次试解锁（提权）：`core.ps1 trial` → 重启 **2**。事务执行一次：FWSEC → AD102 四重 PLM payload → `SS0=0x88888888 / SS1=0x8` → PCIe FLR → GOP 交还 → Windows。验证：`RUN01` 必须含 `POST-GOP register_unlock_verified=1` 与 `FINAL status=0 stage=post-unlock-handoff attempted=1 clean=1`。
6. 转常驻（提权）：`core.ps1 enable`（写 `AUTO.TXT`）→ 重启 **3** 即热重启验收：无武装、`auto_confirmed=1`、同样 `FINAL status=0`。此后**每次冷启动与重启都会自动重放解锁**。
7. 可选性能验证：上游树内 `tools\bench_gemm.py`（FP16→FP32 累加上升，FP32 对照持平）。原厂功耗墙下 8192³ cuBLAS FP16 预期 ≈1.5–1.76×。

日志在 `GPUAUTO` 卷（`GPU-UNLOCK\RUN00–RUN07`）与 `%ProgramData%\GPU-Unlock\installer.log`；`core.ps1 status | logs` 汇总。

## 供应链（钉值全部保持）

钉值的 CachyOS `nvidia-utils-610.43.03-1-x86_64_v3` 包已从 archive.cachyos.org **被清理（404）**。移植版 `prepare_assets.py` 改为接受三个独立缓存文件代替整包——`gsp_ga10x.bin`、NVIDIA 许可证文本、`.PKGINFO`——每个都按**原包路径所强制的同一批 SHA-256 钉值**校验。三者抽取自 [archive.archlinux.org](https://archive.archlinux.org) 的同版本包；NVIDIA 签名的 `gsp_ga10x.bin` 跨发行版重打包逐字节相同（84,277,400 字节，`572373620a37…`）。两个 V67 payload 由代码内确定性构造并对照各自钉值验证；booter/GSP-boot 资产来自哈希钉值的 NVIDIA 内核模块源码包。五个生成资产由安装器再校验一遍，EFI 每次开机还会再验一次（RUN 日志中的 `asset verified:` 行）。

## 边界、失败模式、回滚

- **睡眠/休眠**：唤醒后解锁丢失（preboot 程序不在唤醒路径上），重启即恢复。保持 Windows 快速启动**关闭**（混合关机会让下次开机的卡状态不可预期）。
- **已知非致命**：`FBPA` PLM 达到 `0xffffff0f` 而非期望 `0xffffffff`——与上游 4070 Ti SUPER 金丝雀一致；三项必需权限全部到位。
- **失败 = 原厂，不是砖**：任一门控失败即安全中止，Windows 照常启动；每次开机写一个编号 RUN 日志。极端挂死（未观测到）：长按电源 → 固件启动菜单选 **Windows Boot Manager** → 进系统后 `core.ps1 disable`。
- **回滚**：`core.ps1 disable`（下次开机原生）→ `core.ps1 uninstall`（删启动项与 `GPUAUTO` 分区，卷精确恢复原大小）。无任何刷写；断电任何时候都回原厂。

## 致谢与许可

Windows 路径是 [Zihao-Wu06/gpu-unlock-for-windows](https://github.com/Zihao-Wu06/gpu-unlock-for-windows)（GPL-2.0-only）的移植——加卡方法论参照 [Yuuki-Rosario/gpu-unlock-4070tis-ad103-win](https://github.com/Yuuki-Rosario/gpu-unlock-4070tis-ad103-win)（`PORT-2705.md`）；Secure Boot 开启运行参照 [Goldlionren/gpu-unlock-4080s](https://github.com/Goldlionren/gpu-unlock-4080s)。上游链：gpu-unlock-ada（JustAResearcher）→ Zagitta/gpu-unlock → TOTOROONG/AD103_win_unlocker（AD102 四重 PLM payload）→ CMP 30/40/50HX V67 研究。NVIDIA 固件按 NVIDIA 自身条款本地下载与生成，本仓库不分发任何 NVIDIA 固件。本目录文档与其余仓库同为 MIT；EFI 及其源码保持 GPL-2.0-only。
