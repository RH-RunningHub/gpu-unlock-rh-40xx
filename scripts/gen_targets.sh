#!/usr/bin/env bash
# Generate the GRUB "gpu_unlock.targets=" option from the RTX 4090/4090D
# GPUs physically present in this machine.
#
# usage: gen_targets.sh [--targets-only]
#   --targets-only   print only the comma-joined PCI address list (for piping
#                    into install_unlock.sh)
#
# Targets are machine-specific — never copy a list between machines, and
# never use targets=all.
set -euo pipefail

out=$(lspci -Dnn 2>/dev/null | awk '/10de:(2684|2685)/ {print $1}')
if [ -z "$out" ]; then
    echo "ERROR: no RTX 4090 (10de:2684) / RTX 4090D (10de:2685) device found" >&2
    exit 1
fi

targets=$(echo "$out" | paste -sd, -)
count=$(echo "$out" | wc -l)
n4090d=$(lspci -Dnn 2>/dev/null | grep -c '10de:2685' || true)

if [ "${1:-}" = "--targets-only" ]; then
    echo "$targets"
    exit 0
fi

echo "GPUs found : $count (4090: $((count - n4090d)), 4090D: $n4090d)"
echo "targets    : $targets"
opt="gpu_unlock.targets=$targets"
if [ "$n4090d" -ge 1 ]; then
    opt="$opt gpu_unlock.rtx4090d_experimental=1"
fi
echo "boot option:"
echo "  $opt"
echo
echo "cross-check: nvidia-smi -L   # should list the same $count GPU(s)"
