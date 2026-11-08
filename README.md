# gpu-unlock-rh-40xx

[![RunningHub China](https://img.shields.io/badge/RunningHub-China-2F80ED)](https://www.runninghub.cn/?inviteCode=rh-v1367)
[![RunningHub International](https://img.shields.io/badge/RunningHub-International-7B61FF)](https://www.runninghub.ai/?inviteCode=rh-v1367)
[![English](https://img.shields.io/badge/Language-English-2563EB)](./README.md)
[![简体中文](https://img.shields.io/badge/Language-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-EF4444)](./README_CN.md)

![License](https://img.shields.io/badge/License-MIT-green)

Deployment toolkit for unlocking the tensor cores of **RTX 4090 (10de:2684) / RTX 4090D (10de:2685)** on Ubuntu servers, with a focus on **hot-reboot activation** — no power cycle needed.

> **🆕 Update (2026-11): Windows 4090D single-machine unlock.** The same tensor unlock now runs on a Windows 10/11 desktop via an unsigned UEFI preboot program that re-applies the unlock at every boot — no USB, no VBIOS flash, safe rollback. Entirely different mechanics from the Linux path below; see **[windows/README.md](windows/README.md)**.

## ✨ Features

- **🔥 Hot-reboot activation** — no power cycle, no datacenter visit: one ordinary reboot unlocks every card, turning activation from an hours-long maintenance window into a minutes-long routine operation.
- **📈 Measured, hardcore speedups** — FP16 GEMM sweet spot (4096–6144³) **+52–64%**, FP8 **+56%**, FP32 unchanged as control — the same cards, roughly half again the throughput where it matters.
- **🏭 Proven on production workloads** — across the top-100 busiest ComfyUI workflows, post-unlock median task time improved by up to **61%** (top-10 average **31%**, overall **+12.4%** across all workflows that got faster) — real production numbers, not synthetic benchmarks.
- **🛡️ Cannot brick, always reversible** — the worst case is a clean `-16` safe failure: the machine boots normally, workloads unaffected; full rollback is removing two GRUB parameters.
- **🎯 Silent failures caught before the reboot** — a seven-point pre-flight checklist stops the classic "mysterious -16" before you ever reboot; everything green before anything ships.
- **🤖 Idiot-proof batch deployment** — targets generated per-machine from `lspci`, `targets=all` rejected, GPU counts cross-checked, idempotent reruns — safe to roll across a large mixed fleet.

The heavy lifting (DKMS kernel module + patched firmware) comes from the upstream gpu-unlock-ada project. This repo ships only the necessary unlock files around them: the two initramfs hooks the upstream deb is missing, a deployment script, and the hot-reboot checklist / procedure battle-tested across a large production GPU fleet.

## 🧠 Why the hot reboot works

The single failure mode of this unlock is a **binding race**:

1. Ubuntu's default `MODULES=most` packs `nvidia.ko` into the initramfs.
2. At boot, udev loads the NVIDIA driver and **binds the cards** before `gpu_unlock` runs.
3. `gpu_unlock` then finds every target busy and exits with `-EBUSY (-16)` — silently.

Cold-booting does not fix this: the same race happens after a full power cycle. The two hooks fix it **structurally**: `zz-exclude-nvidia` removes nvidia modules from the initramfs (so nothing binds early) and `gpu-unlock-firmware` carries the unlock firmware into the initramfs (so the module can load it). With both hooks verified, a warm reboot is all that is needed — the machine reboots, `gpu_unlock` runs first, the cards unlock, and the driver binds afterwards.

Upstream actually ships some initramfs integration: the deb carries `modules.d/gpu-unlock.conf` (pulling the `gpu_unlock` module into the initramfs) and a dracut `force_drivers` drop-in, and the postinst rebuilds the initramfs automatically — the design intent is hot-reboot activation. On our Ubuntu 22.04 production fleet it fell short on both ends: the unlock firmware never made it into the initramfs (`-2`; 22.04 has no `copy_directory` and upstream ships no firmware hook), and nvidia modules still rode into the initramfs via `MODULES=most`, binding the cards first (`-16`). The two hooks in this repo close exactly those two gaps, and with them hot reboot works reliably in production.

The checklist below exists because one of these two hooks silently missing is the difference between a 2-minute activation and a confusing `-16`.

## 🛠️ Requirements

- Ubuntu 20.04 / 22.04, root access
- The two upstream packages, placed in `debs/` (download below):
  - `gpu-unlock-dkms_1.1.1_all.deb` (DKMS kernel module source)
  - `gpu-unlock-firmware_1.1.1_all.deb` (patched firmware)
- `dkms`, `linux-headers-$(uname -r)` (and headers for every other installed kernel), `python3`
- ≥ 350 MB free in `/boot`
- NVIDIA driver bound to the cards (`nvidia-smi -L` lists them)

## 📥 Package Download

The two debs (DKMS module source + patched firmware) are not shipped in the GitHub repo; they are packaged on Quark netdisk:

**Quark**: <https://pan.quark.cn/s/82b89a14bbb1>

Drop them into this repo's `debs/` directory (`install_unlock.sh` looks there by default):

```
debs/
├── gpu-unlock-dkms_1.1.1_all.deb        # DKMS kernel module source
└── gpu-unlock-firmware_1.1.1_all.deb    # patched firmware
```

Alternatively, obtain or build them from the upstream gpu-unlock-ada repository.

## 📦 Installation (files-only)

```bash
git clone https://github.com/RH-RunningHub/gpu-unlock-rh-40xx.git
cd gpu-unlock-rh-40xx
cp /path/to/gpu-unlock-*.deb debs/        # supply the two upstream packages

# Generate the GRUB targets from the GPUs actually present
sudo scripts/gen_targets.sh

# Deploy everything — packages, hooks, module, GRUB params, initramfs
sudo scripts/install_unlock.sh 4090                  # targets auto-generated
sudo scripts/install_unlock.sh 4090D                 # 4090D adds the experimental flag
# or with an explicit list:
sudo scripts/install_unlock.sh 4090 "0000:01:00.0,0000:41:00.0"

# RESULT FILES-OK  → activation pending reboot
```

Notes:

- `install_unlock.sh` is idempotent — re-running it on a deployed machine returns `FILES-DONE`.
- Targets are machine-specific. Never copy a list between machines and never use `targets=all`; the scripts reject it.
- 4090D requires the additional `gpu_unlock.rtx4090d_experimental=1` parameter (added automatically for `4090D`).

## 🔥 Hot Reboot

### 1. Pre-flight checklist — `sudo scripts/hot_reboot_check.sh`

Checks the **next bootable kernel** (newest `vmlinuz` in `/boot`), not just the running one. All seven items must be `OK`:

| check | passes when | meaning |
|---|---|---|
| `hooks` | both hook files exist and are executable | hooks were written before dpkg |
| `initrd-no-nvidia` | `0` nvidia modules in the next kernel's initramfs | udev cannot win the binding race → this is the `REBUILD-FIRST` gate |
| `initrd-firmware` | ≥1 gpu-unlock file in the initramfs | firmware will be loadable at boot |
| `module(<kernel>)` | `gpu_unlock.ko` exists for the next kernel | DKMS built for the kernel that will boot |
| `grub-gpu-unlock` | ≥1 `gpu_unlock` entry in `grub.cfg` | params will apply at boot |
| `workload-containers` | `0` running workload containers | reboot kills running jobs — drain first |
| `boot-free-KB` | ≥ 350000 | `mkinitramfs` will not run out of space |

`initrd-no-nvidia = REBUILD-FIRST` is the classic silent failure: the machine boots fine, the unlock just fails with `-16`. Fix is always `update-initramfs -u -k all` — under heavy load it may time out (`rc=124`); try `nice -19` once, otherwise rebuild in a drained maintenance window.

### 2. Reboot — `sudo scripts/hot_reboot.sh`

- Runs the checklist first and refuses on any blocker.
- Schedules the reboot **detached from the SSH session**:

```bash
setsid nohup bash -c 'sleep 2; shutdown -r now' </dev/null >/dev/null 2>&1 &
```

A bare `nohup shutdown -r now &` dies with the SSH session before it ever fires — the `setsid` form is the one that survives. The machine takes a few minutes to actually go down; reconnect after ~5–10 minutes.

### 3. Verify — `sudo scripts/verify_unlock.sh`

| check | passes when |
|---|---|
| `dmesg unlocked` | count equals the visible card count (`nvidia-smi -L`) |
| `unlock-failed` | zero lines |
| `nvidia-smi cards` | all cards listed (retried once after 30 s if the driver is still settling) |
| workload container health | in-container health endpoint returns 200 (best-effort) |

Then re-check anything your deployment tooling regenerates at container rebuild (env files in particular) — a reboot window is when such things get wiped.

## 🩺 Troubleshooting

Quick-ref:

| symptom | root cause | fix |
|---|---|---|
| `unlock failed (-16)`, no other output | initramfs ships nvidia modules → udev binds first | `zz-exclude-nvidia` hook + rebuild initramfs |
| `firmware load failed (-2)` | firmware missing from initramfs | `gpu-unlock-firmware` hook + rebuild |
| `-110` + `firmware did not stop; keeping its DMA buffers until power off`, card missing from `nvidia-smi` | only a **power-off cold boot** clears this state | power-cycle the host (authorized action) |
| after a kernel upgrade `unlocked=0` | new kernel lacks module/firmware in initramfs | headers + `dkms install -k <k>` + `update-initramfs -k <k>` |
| unlocked ≠ targets | card count changed | WARN, not an error; re-verify with `nvidia-smi -L` |

Full table, pitfalls and the kernel-upgrade recipe: [docs/troubleshooting.md](docs/troubleshooting.md).

## ↩️ Rollback

1. Remove the `gpu_unlock.*` params from `/etc/default/grub` (a dated backup `grub.bak_unlock_<date>` is left automatically).
2. `update-grub`; verify `grep -c gpu_unlock /boot/grub/grub.cfg` is 0.
3. Next boot: module has no parameters and is fully inert — GPUs run stock.
4. Full uninstall: `dpkg -r gpu-unlock-dkms gpu-unlock-firmware`, delete both `/etc/initramfs-tools/hooks/` files, `update-initramfs -u -k all`.

## 📄 License

This project is released under the [MIT License](LICENSE). The upstream kernel module and firmware packages are distributed under their own licenses and are not included in this repository.

## 🔗 Links

[![RunningHub China](https://img.shields.io/badge/RunningHub-China-2F80ED)](https://www.runninghub.cn/?inviteCode=rh-v1367)
[![RunningHub International](https://img.shields.io/badge/RunningHub-International-7B61FF)](https://www.runninghub.ai/?inviteCode=rh-v1367)

- Upstream Project: [gpu-unlock-ada (JustAResearcher)](https://github.com/JustAResearcher/gpu-unlock-ada)
- Windows 4090D unlock base: [gpu-unlock-for-windows (Zihao-Wu06)](https://github.com/Zihao-Wu06/gpu-unlock-for-windows)
- Windows port reference: [gpu-unlock-4070tis-ad103-win (Yuuki-Rosario)](https://github.com/Yuuki-Rosario/gpu-unlock-4070tis-ad103-win) — card-porting notes (`PORT-2705.md`)
- Windows Secure Boot reference: [gpu-unlock-4080s (Goldlionren)](https://github.com/Goldlionren/gpu-unlock-4080s)

## 🙏 Acknowledgements

This project is based on [gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada) by JustAResearcher — which covers RTX 4090/4090D and other Ada-architecture device IDs — packaging deployment and hot-reboot tooling around its kernel module and firmware (the DKMS source tree also ships with installed packages under `/usr/src/gpu-unlock-1.1.1`).

The Windows 4090D unlock under [`windows/`](windows/README.md) is a port of [gpu-unlock-for-windows](https://github.com/Zihao-Wu06/gpu-unlock-for-windows) by Zihao-Wu06 (GPL-2.0-only), which itself descends from gpu-unlock-ada → [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) → [TOTOROONG/AD103_win_unlocker](https://huggingface.co/TOTOROONG) (AD102 four-PLM payload) and the CMP 30/40/50HX V67 research line. Card-porting methodology follows [Yuuki-Rosario's PORT-2705 notes](https://github.com/Yuuki-Rosario/gpu-unlock-4070tis-ad103-win); Secure Boot-on operation is documented in [Goldlionren/gpu-unlock-4080s](https://github.com/Goldlionren/gpu-unlock-4080s).
