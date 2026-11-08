# gpu-unlock-rh-40xx

[![RunningHub China](https://img.shields.io/badge/RunningHub-China-2F80ED)](https://www.runninghub.cn/?inviteCode=rh-v1367)
[![RunningHub International](https://img.shields.io/badge/RunningHub-International-7B61FF)](https://www.runninghub.ai/?inviteCode=rh-v1367)
[![English](https://img.shields.io/badge/Language-English-2563EB)](./README.md)
[![简体中文](https://img.shields.io/badge/Language-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-EF4444)](./README_CN.md)

![License](https://img.shields.io/badge/License-MIT-green)

RTX 4090 (10de:2684) / RTX 4090D (10de:2685) Ubuntu 服务器张量核心解锁部署工具，重点是**热重启激活**——无需断电冷启。

> **🆕 更新（2026-11）：Windows 4090D 单机解锁。** 同款张量解锁现已支持 Windows 10/11 台式机：通过固件启动顺序置顶的未签名 UEFI preboot 程序，每次开机自动重放解锁——无需 U 盘、不刷 VBIOS、可安全回滚。与下方 Linux 路径机制完全不同，见 **[windows/README_CN.md](windows/README_CN.md)**。

## ✨ 功能特点

- **🔥 热重启即激活** —— 不用断电冷启、不用进机房，一次普通重启全部生效；把"解锁"从小时级的运维窗口，压缩成分钟级的例行操作。
- **📈 实测硬核提速** —— FP16 GEMM 甜点区（4096–6144³）**+52~64%**，FP8 **+56%**，FP32 对照不变——同一批卡，白赚一半算力。
- **🏭 生产工作流实测** —— 线上使用量前 100 的 ComfyUI 工作流，解锁后成功任务中位时长最高提速 **61%**、前十平均 **31%**、整体平均 **12.4%**——不是跑分，是生产环境的真实账单。
- **🛡️ 永不变砖，随时可退** —— 最坏情况也只是干净的 `-16` 安全失败，机器照常启动、业务无感；删两条 GRUB 参数即完整回滚。
- **🎯 静默失败提前拦截** —— 七项重启前预检，把最典型的"莫名其妙 -16"挡在重启之前；清单全绿才放行，一次成功，不赌概率。
- **🤖 防呆批量部署** —— targets 按 `lspci` 现场生成、拒绝 `targets=all`、卡数自动交叉核对、幂等可重跑——大规模混装机群也能放心滚动。

核心的 DKMS 内核模块与固件来自上游 gpu-unlock-ada 项目。本仓库只包含围绕它们所必需的解锁文件：上游 deb 缺失的两个 initramfs hook、一个部署脚本，以及在大量生产 GPU 机器上实战验证过的热重启检查清单与流程。

## 🧠 为什么热重启能生效

这套解锁唯一的失败模式是**绑定竞争**：

1. Ubuntu 默认 `MODULES=most` 会把 `nvidia.ko` 打进 initramfs；
2. 开机时 udev 先加载 NVIDIA 驱动并**绑走显卡**，`gpu_unlock` 随后才运行；
3. `gpu_unlock` 发现所有目标卡都被占用，以 `-EBUSY (-16)` 退出——没有任何诊断输出。

冷启动治不了这个病：断电冷启后同样存在这个竞争。两个 hook 从**结构上**解决它：`zz-exclude-nvidia` 把 nvidia 模块从 initramfs 里剔除（不再有东西抢先绑卡），`gpu-unlock-firmware` 把解锁固件带进 initramfs（模块能加载固件）。两项校验通过后，热重启即可完成激活——机器重启、`gpu_unlock` 先跑、卡解锁、驱动随后绑定。

上游其实自带一套 initramfs 集成：deb 里有 `modules.d/gpu-unlock.conf`（把 `gpu_unlock` 模块塞进 initramfs）和 dracut 的 `force_drivers` 配置，装包后也会自动重建 initramfs——设计意图就是热重启激活。但在 Ubuntu 22.04 生产机上实测，这套集成两头落空：固件进不了 initramfs（`-2`，22.04 没有 `copy_directory`，上游没写固件 hook），nvidia 模块照样被 `MODULES=most` 打进 initramfs 抢先绑卡（`-16`）。本仓库的两个 hook 补齐的正是这两环，热重启在生产机上稳定生效。

下面的检查清单存在的意义：这两个 hook 任何一个悄悄缺失，就是"2 分钟激活"和"莫名其妙 -16"之间的差别。

## 🛠️ 环境要求

- Ubuntu 20.04 / 22.04，root 权限
- 上游两个软件包，放入 `debs/` 目录（下载见下方 📥 软件包下载）：
  - `gpu-unlock-dkms_1.1.1_all.deb`（DKMS 内核模块源码）
  - `gpu-unlock-firmware_1.1.1_all.deb`（修改版固件）
- `dkms`、`linux-headers-$(uname -r)`（以及其他每个已装内核对应的 headers）、`python3`
- `/boot` 可用空间 ≥ 350MB
- NVIDIA 驱动已绑定显卡（`nvidia-smi -L` 能列出全部卡）

## 📥 软件包下载

两个 deb（DKMS 模块源码 + 修改版固件）不进 GitHub 仓库，已打包放在夸克网盘：

**夸克网盘**：<https://pan.quark.cn/s/82b89a14bbb1>

下载后放入本仓库的 `debs/` 目录即可（`install_unlock.sh` 默认从这里取包）：

```
debs/
├── gpu-unlock-dkms_1.1.1_all.deb        # DKMS 内核模块源码
└── gpu-unlock-firmware_1.1.1_all.deb    # 修改版固件
```

也可从上游 gpu-unlock-ada 仓库自行获取或构建。

## 📦 安装（仅放文件）

```bash
git clone https://github.com/RH-RunningHub/gpu-unlock-rh-40xx.git
cd gpu-unlock-rh-40xx
cp /path/to/gpu-unlock-*.deb debs/        # 自备上游两个软件包

# 按本机实际存在的显卡生成 GRUB targets
sudo scripts/gen_targets.sh

# 一键部署：软件包、hook、内核模块、GRUB 参数、initramfs
sudo scripts/install_unlock.sh 4090                  # targets 自动生成
sudo scripts/install_unlock.sh 4090D                 # 4090D 自动追加实验参数
# 或显式指定：
sudo scripts/install_unlock.sh 4090 "0000:01:00.0,0000:41:00.0"

# RESULT FILES-OK  → 等待重启激活
```

注意：

- `install_unlock.sh` 幂等——已部署的机器重跑会返回 `FILES-DONE`。
- targets 与机器相关。不要跨机器复制同一份列表，也不要用 `targets=all`（脚本会直接拒绝）。
- 4090D 需要额外的 `gpu_unlock.rtx4090d_experimental=1` 参数（对 `4090D` 自动添加）。

## 🔥 热重启

### 1. 重启前检查清单 —— `sudo scripts/hot_reboot_check.sh`

校验的是**下一个将启动的内核**（`/boot` 里最新的 `vmlinuz`），而不只是当前在跑的内核。七项全部 `OK` 才允许重启：

| 检查项 | 通过条件 | 含义 |
|---|---|---|
| `hooks` | 两个 hook 文件存在且可执行 | hook 在 dpkg 之前写入 |
| `initrd-no-nvidia` | 下一内核 initramfs 中 nvidia 模块数为 `0` | udev 赢不了绑定竞争 → 即 `REBUILD-FIRST` 闸门 |
| `initrd-firmware` | initramfs 中 gpu-unlock 文件数 ≥1 | 开机时固件可加载 |
| `module(<kernel>)` | 下一内核已有 `gpu_unlock.ko` | DKMS 为将要启动的内核构建过模块 |
| `grub-gpu-unlock` | `grub.cfg` 中 gpu_unlock 条目 ≥1 | 参数将在启动时生效 |
| `workload-containers` | 业务容器数 `0` | 重启会杀掉在跑任务——先摘流 |
| `boot-free-KB` | ≥ 350000 | `mkinitramfs` 不会写满 |

`initrd-no-nvidia = REBUILD-FIRST` 是最典型的静默失败：机器照常启动，只是解锁以 `-16` 安全失败、不生效。修法永远是 `update-initramfs -u -k all`——高负载下可能超时（`rc=124`），可先 `nice -19` 试一次，仍超时就摘流后重建。

### 2. 重启 —— `sudo scripts/hot_reboot.sh`

- 先跑检查清单，有阻塞项直接拒绝。
- 以**脱离 SSH 会话的方式**发起重启：

```bash
setsid nohup bash -c 'sleep 2; shutdown -r now' </dev/null >/dev/null 2>&1 &
```

裸 `nohup shutdown -r now &` 会随 SSH 会话断开被杀、根本不会执行——能活下来的是 `setsid` 这个写法。机器真正下线还要几分钟，约 5–10 分钟后重连。

### 3. 验证 —— `sudo scripts/verify_unlock.sh`

| 检查项 | 通过条件 |
|---|---|
| `dmesg unlocked` | 计数等于可见卡数（`nvidia-smi -L`） |
| `unlock-failed` | 零条 |
| `nvidia-smi cards` | 全卡在列（驱动未就绪时自动 30 秒后重试一次） |
| 业务容器健康 | 容器内健康检查端点返回 200（尽力而为） |

另外，凡是部署工具会在容器重建时重新生成的配置（尤其是 env 文件），重启后都要复查一遍——重启窗口正是它们被冲掉的时候。

## 🩺 故障排查

速查表：

| 现象 | 根因 | 处置 |
|---|---|---|
| `unlock failed (-16)`，无其他输出 | initramfs 带 nvidia 模块 → udev 先绑卡 | `zz-exclude-nvidia` hook + 重建 initramfs |
| `firmware load failed (-2)` | initramfs 缺固件 | `gpu-unlock-firmware` hook + 重建 |
| `-110` + `firmware did not stop; keeping its DMA buffers until power off`，该卡从 `nvidia-smi` 消失 | 只有**断电冷启**能清除该状态 | 整机断电冷启（需授权操作） |
| 内核升级后 `unlocked=0` | 新内核 initramfs 缺模块/固件 | 装 headers + `dkms install -k <k>` + `update-initramfs -k <k>` |
| unlocked ≠ targets | 卡数变动 | WARN 不算错误；用 `nvidia-smi -L` 复核 |

完整表格、踩坑清单与内核升级配方见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## ↩️ 回滚

1. 从 `/etc/default/grub` 删除 `gpu_unlock.*` 参数（脚本自动留有日期备份 `grub.bak_unlock_<日期>`）。
2. `update-grub`；确认 `grep -c gpu_unlock /boot/grub/grub.cfg` 为 0。
3. 下次启动：模块无参数、完全惰性，显卡按原样运行。
4. 彻底卸载：`dpkg -r gpu-unlock-dkms gpu-unlock-firmware`，删除 `/etc/initramfs-tools/hooks/` 下两个文件，再 `update-initramfs -u -k all`。

## 📄 许可证

本项目以 [MIT License](LICENSE) 发布。上游内核模块与固件软件包遵循其自身的许可证，不包含在本仓库中。

## 🔗 链接

[![RunningHub China](https://img.shields.io/badge/RunningHub-China-2F80ED)](https://www.runninghub.cn/?inviteCode=rh-v1367)
[![RunningHub International](https://img.shields.io/badge/RunningHub-International-7B61FF)](https://www.runninghub.ai/?inviteCode=rh-v1367)

- 上游项目：[gpu-unlock-ada（JustAResearcher）](https://github.com/JustAResearcher/gpu-unlock-ada)
- Windows 4090D 解锁底座：[gpu-unlock-for-windows（Zihao-Wu06）](https://github.com/Zihao-Wu06/gpu-unlock-for-windows)
- Windows 移植参照：[gpu-unlock-4070tis-ad103-win（Yuuki-Rosario）](https://github.com/Yuuki-Rosario/gpu-unlock-4070tis-ad103-win) —— 加卡移植笔记（`PORT-2705.md`）
- Windows Secure Boot 参照：[gpu-unlock-4080s（Goldlionren）](https://github.com/Goldlionren/gpu-unlock-4080s)

## 🙏 致谢

本项目基于 [gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada)（作者 JustAResearcher）的内核模块与固件——上游覆盖 RTX 4090/4090D 及其他 Ada 架构设备 ID——为其提供部署与热重启工具封装（已安装的机器上 DKMS 源码树位于 `/usr/src/gpu-unlock-1.1.1`）。

[`windows/`](windows/README_CN.md) 下的 Windows 4090D 解锁是 [gpu-unlock-for-windows](https://github.com/Zihao-Wu06/gpu-unlock-for-windows)（Zihao-Wu06，GPL-2.0-only）的移植——其自身源自 gpu-unlock-ada → [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) → [TOTOROONG/AD103_win_unlocker](https://huggingface.co/TOTOROONG)（AD102 四重 PLM payload）以及 CMP 30/40/50HX 的 V67 研究线。加卡方法论遵循 [Yuuki-Rosario 的 PORT-2705 笔记](https://github.com/Yuuki-Rosario/gpu-unlock-4070tis-ad103-win)；Secure Boot 开启运行见 [Goldlionren/gpu-unlock-4080s](https://github.com/Goldlionren/gpu-unlock-4080s)。
