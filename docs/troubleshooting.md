# Troubleshooting

## Failure quick-ref (dmesg lines)

| dmesg symptom | root cause | fix |
|---|---|---|
| `unlock failed (-16)`, no other output | the initramfs ships nvidia modules; udev binds the cards before `gpu_unlock` | keep the `zz-exclude-nvidia` hook; rebuild the initramfs (`update-initramfs -u -k all`); verify with `hot_reboot_check.sh` |
| `firmware load failed (-2)` | unlock firmware missing from the initramfs | keep the `gpu-unlock-firmware` hook; rebuild the initramfs |
| `-110` + `firmware did not stop; keeping its DMA buffers until power off`; that card missing from `nvidia-smi` | only a **power-off cold boot** clears this state (the module says so itself; a warm reboot will not) | power-cycle the machine (needs an authorized maintenance action) |
| after a kernel upgrade, `unlocked=0` while the old kernel worked | the new kernel's initramfs lacks the module/firmware | `apt-get install -y --no-install-recommends linux-headers-<k>`; `dkms install -m gpu-unlock -v 1.1.1 -k <k>`; `update-initramfs -u -k <k>` |
| unlocked count ≠ targets count | a card was removed/pulled at some point | treat as a WARN, not an error; the targets list is written in full, the real card count is whatever `nvidia-smi -L` reports |

## Pitfalls (ordered by how often they bite)

| pitfall | symptom | fix |
|---|---|---|
| hooks written after `dpkg -i` | first initramfs rebuild is fat; -16 at boot | write both hooks **before** installing the debs (`install_unlock.sh` does this) |
| initramfs ships nvidia modules | instant `-16`, no diagnostics | the `zz-exclude-nvidia` hook + rebuild; `hot_reboot_check.sh` reports `REBUILD-FIRST` |
| `/boot` full | `mkinitramfs` zstd write failure | delete old kernel initrds; the scripts gate at 350 MB free |
| editing GRUB with sed | `update-grub` reports `splash: not found` (quotes mangled) | `install_unlock.sh` edits `/etc/default/grub` with python3 and keeps a dated backup |
| bare `nohup shutdown -r now &` | reboot dies silently when the SSH session closes | `setsid nohup bash -c 'sleep 2; shutdown -r now' </dev/null >/dev/null 2>&1 &` (what `hot_reboot.sh` does) |
| health probe on the host's port 80 | misleading 502 from a fronting proxy | probe the service **inside** the container (`verify_unlock.sh` does) |
| containers created with `--rm` | workload containers vanish after a reboot | recreate them with your own deployment tooling in the same maintenance window |
| regenerated env files | service env vars appended outside the deployment tooling are lost on rebuild | re-verify required env vars after every reboot |
| `update-initramfs` under heavy load | rc=124, the parent shell is killed but the orphaned `mkinitramfs` keeps writing | `pkill -f "mkinitramfs -o /boot/initrd.img"` and clean `/boot/*.new`; try `nice -19` once; if it still times out, rebuild in a drained maintenance window — a fat initramfs only fails safe (-16), the machine still boots |
| `.dpkg-bak` files look like free space | deleting them frees nothing (hard links) | the real cleanup is the skinny initramfs rebuild itself |

## Performance notes

Measured on RTX 4090 (2026-10): FP16 GEMM (FP32 accumulate) +5~22% on small
matrices, **+52~64% in the 4096–6144³ sweet spot**, +12~16% at 8192³ and above
(HBM bandwidth bound — the ceiling applies to all cards, it is not an unlock
failure), FP8 +56%. FP32 is unchanged as a control. Power draw rises ~12-13%
per card; 4090D peaks around 415 W / 73 °C — check cooling before unlocking a
full 8-GPU host.

## Rollback

1. Edit `/etc/default/grub` and remove the `gpu_unlock.*` params
   (`install_unlock.sh` leaves a dated backup, `grub.bak_unlock_<date>`).
2. `update-grub`; verify `grep -c gpu_unlock /boot/grub/grub.cfg` returns 0.
3. On the next boot the module has no parameters and is fully inert —
   the GPUs run stock.
4. Full uninstall: `dpkg -r gpu-unlock-dkms gpu-unlock-firmware`, delete both
   files in `/etc/initramfs-tools/hooks/`, then `update-initramfs -u -k all`.

## Safety notes

- The module is state-safe and cannot brick a card: already-unlocked cards
  are skipped; a bad state fails cleanly with `-16` and the machine boots
  normally.
- `targets=all` is intentionally rejected by the scripts — always enumerate
  the real PCI addresses (`gen_targets.sh`).
- Never reboot a machine with running workloads; `hot_reboot.sh` checks and
  refuses first.
