# 🪟 Windows 4090D unlock — single machine

[English](./README.md) | [简体中文](./README_CN.md)

This directory adds a **Windows 10/11 path** to this repository, next to the Ubuntu-fleet tooling above.

- The **Linux side of this repo** (hooks/scripts at the repo root) is **batch deployment for Ubuntu 20.04/22.04 GPU servers**: DKMS module + patched firmware + initramfs hooks + GRUB `gpu_unlock.*` params, activated by one ordinary reboot across a fleet.
- This **Windows side** is a **single-machine unlock for RTX 4090 D (`10de:2685`)**: an unsigned UEFI preboot program runs before the NVIDIA driver binds on **every boot** (cold start or restart) and re-applies a volatile unlock, then hands off to Windows. No VBIOS flash, no driver patch, power-off always returns the card to stock.

> **Status: first published Windows unlock for the 4090 D.** Validated end-to-end on one machine — ASUS TUF GAMING B460M-PLUS (WI-FI, BIOS 0708) + MSI RTX 4090 D 24 GB, Windows 11 Pro 23H2 (22631), driver 617.14 — as three boots with zero failures: read-only enrollment → one armed trial unlock (`RUN01`, selectors `SS0=0x88888888 / SS1=0x8` verified across FLR and GOP handoff) → resident auto mode (`RUN02`, no manual arming, `FINAL status=0 stage=post-unlock-handoff clean=1`). Treat it as experimental: one card, one board, one driver version.

## Linux vs Windows at a glance

| | Linux (repo root) | Windows (this directory) |
|---|---|---|
| Target | 4090 + 4090D servers, fleet batch | 4090 D desktop, single machine |
| Mechanism | DKMS kernel module + initramfs hooks + GRUB | UEFI preboot program + firmware boot entry (top of boot order) |
| Applies | once per boot, before nvidia binds | once per boot, before driver binds |
| Worst case | clean `-16`/`-2` safe failure | safe abort → boots Windows stock; hard hang → hold power, pick "Windows Boot Manager" in firmware menu |
| Rollback | remove 2 GRUB params / dpkg -r | `core.ps1 disable` → `uninstall` (partition restored to exact size) |

## Contents

| File | What it is |
|---|---|
| `2685-port.patch` | The whole port: 3 files, +50/−13 lines vs [`Zihao-Wu06/gpu-unlock-for-windows`](https://github.com/Zihao-Wu06/gpu-unlock-for-windows) HEAD `0075edde` — chip-table entry `{0x2685,0x192,"GeForce RTX 4090 D",24512,24576,FALSE}`, manifest 2685 entry, and an offline-input adaptation (see Supply chain) |
| `payload/gpuunlock.efi` | Prebuilt 2685 EFI (96,256 B, SHA-256 `b27ac31ecfa9d9592e1e53fecf199ab011a8d7c163b44b95ff8d16208ce212a9`). GPL-2.0-only, source = Zihao tree + patch; the build is reproducible byte-for-byte (the unmodified tree reproduces the author's shipped `e2780f1a…` exactly) |
| `preflight.ps1` | Admin preflight: Secure Boot / BitLocker / fast startup / firmware boot entries snapshot / shrink candidates. `-Apply` disables Windows fast startup |
| `README_CN.md` | 中文版 |

## Procedure (partition mode, no USB needed)

1. Run `preflight.ps1` as admin (read-only first, then `-Apply` to turn fast startup off). Requirements: UEFI, Secure Boot **off**, BitLocker **off** (or suspended), Windows fast startup **off**, ~304 MiB shrinkable NTFS on GPT.
2. Clone the upstream tree, apply the patch, and either use the prebuilt EFI or rebuild it (Zig 0.15.2, `python efi/windows/build.py generic`; the unmodified tree reproduces the shipped binary byte-for-byte — verify before trusting your toolchain):
   ```powershell
   git clone https://github.com/Zihao-Wu06/gpu-unlock-for-windows
   cd gpu-unlock-for-windows
   git apply <path-to>\2685-port.patch
   copy <path-to>\payload\gpuunlock.efi installer\payload\gpuunlock.efi   # or rebuild; manifest efi.sha256 is already patched to b27ac31e…
   ```
3. Install (elevated): `installer\core.ps1 install -Mode partition -Yes -NoPause -AcceptExperimental -Lang zh` — preflights again, generates the five AD102 firmware assets locally from hash-pinned NVIDIA inputs, shrinks ~304 MiB into a hidden FAT32 partition `GPUAUTO`, copies the program + assets, and puts a `GPU Unlock (auto)` entry at the **top** of the firmware boot order.
4. Reboot **1 — enrollment only**: the program reads the card and writes `PROFILE.TXT` (log: `FINAL stage=enrolled-experimental attempted=0`). Nothing is written to the card.
5. Arm one trial (elevated): `core.ps1 trial` → reboot **2**. The transaction runs once: FWSEC → AD102 four-PLM payload → `SS0=0x88888888 / SS1=0x8` → PCIe FLR → GOP handoff → Windows. Verify: `RUN01` must contain `POST-GOP register_unlock_verified=1` and `FINAL status=0 stage=post-unlock-handoff attempted=1 clean=1`.
6. Make it resident (elevated): `core.ps1 enable` (writes `AUTO.TXT`) → reboot **3** is the hot-reboot acceptance: no arming, `auto_confirmed=1`, same `FINAL status=0`. From now on **every cold start and every restart re-applies the unlock automatically**.
7. Optional performance check: `tools\bench_gemm.py` in the upstream tree (FP16→FP32 accumulate up, FP32 control flat). Expect cuBLAS ≈1.5–1.76× on FP16 at 8192³ under a stock power limit.

Logs live on the `GPUAUTO` volume (`GPU-UNLOCK\RUN00–RUN07`) and `%ProgramData%\GPU-Unlock\installer.log`; `core.ps1 status | logs` summarizes them.

## Supply chain (all pins intact)

The pinned CachyOS `nvidia-utils-610.43.03-1-x86_64_v3` package was **pruned from archive.cachyos.org** (404). The ported `prepare_assets.py` accepts three standalone cache files instead of the package — `gsp_ga10x.bin`, the NVIDIA license notice, `.PKGINFO` — each verified against the **same pinned SHA-256 values** the package path enforced. They were extracted from the same-version package on [archive.archlinux.org](https://archive.archlinux.org); NVIDIA's signed `gsp_ga10x.bin` is byte-identical across distro rebuilds (84,277,400 B, `572373620a37…`). The two V67 payloads are built deterministically in code and verified against their own pins; the booter/GSP-boot assets come from the hash-pinned NVIDIA kernel-module source archive. All five generated assets are re-verified by the installer, and the EFI verifies them again at every boot (`asset verified:` lines in the RUN logs).

## Boundaries, failure modes, rollback

- **Sleep/hibernate**: the unlock is lost on resume (the preboot program does not run on resume); a restart re-applies it. Keep Windows fast startup **off** (hybrid shutdown makes the post-power-on card state unpredictable).
- **Known non-fatal**: `FBPA` PLM reaches `0xffffff0f` vs expected `0xffffffff` — same as the upstream 4070 Ti SUPER canary; the three required permissions match.
- **Failure = stock, not brick**: any gate failure aborts and Windows boots normally; every boot writes a numbered RUN log. Hard hang (not observed): hold power, then pick **Windows Boot Manager** in the firmware boot menu and run `core.ps1 disable`.
- **Rollback**: `core.ps1 disable` (next boot stock) → `core.ps1 uninstall` (deletes the boot entry and the `GPUAUTO` partition, restoring the volume to its exact prior size). Nothing is flashed; power loss always returns the card to stock.

## Credits and license

The Windows path is a port of [Zihao-Wu06/gpu-unlock-for-windows](https://github.com/Zihao-Wu06/gpu-unlock-for-windows) (GPL-2.0-only) — port notes for adding a card: [Yuuki-Rosario/gpu-unlock-4070tis-ad103-win](https://github.com/Yuuki-Rosario/gpu-unlock-4070tis-ad103-win) (`PORT-2705.md`); Secure Boot-on operation reference: [Goldlionren/gpu-unlock-4080s](https://github.com/Goldlionren/gpu-unlock-4080s). Upstream chain: gpu-unlock-ada (JustAResearcher) → Zagitta/gpu-unlock → TOTOROONG/AD103_win_unlocker (AD102 four-PLM payload) → CMP 30/40/50HX V67 research. NVIDIA firmware is downloaded and generated locally under NVIDIA's own terms; this repository ships none. The documentation in this directory is MIT like the rest of the repo; the EFI and its source remain GPL-2.0-only.
