#!/usr/bin/env bash
# Pre-flight checklist for the hot reboot — run this BEFORE every reboot.
#
# Checks the NEXT bootable kernel (newest vmlinuz in /boot), not just the
# currently running one. Any blocking finding exits 1 and prints what to do.
#
# usage: sudo hot_reboot_check.sh
# env:   CONTAINER_PATTERN=<regex>   workload container name pattern (default RunningHub)
set -u

CHK() { printf '  %-20s %s\n' "$1" "$2"; }
BLOCK=()
ADD() { BLOCK+=("$1"); }

NK=$(ls -v /boot/vmlinuz-* 2>/dev/null | tail -1 | sed 's/.*vmlinuz-//')
if [ -z "$NK" ]; then
    echo "ERROR: no kernel image found in /boot"
    exit 1
fi
echo "next bootable kernel : $NK"
echo "currently running    : $(uname -r)"
echo

# 1. both initramfs hooks present and executable
if [ -x /etc/initramfs-tools/hooks/gpu-unlock-firmware ] && [ -x /etc/initramfs-tools/hooks/zz-exclude-nvidia ]; then
    CHK hooks OK
else
    CHK hooks FAIL
    ADD "hooks missing/not executable — run install_unlock.sh (hooks must exist before dpkg)"
fi

# 2. initramfs of the NEXT kernel must not ship nvidia modules (binding race)
N2=$(lsinitramfs "/boot/initrd.img-$NK" 2>/dev/null | grep -cE '(^|/)nvidia(_[a-z]+)?\.ko')
if [ "${N2:-1}" -eq 0 ]; then
    CHK initrd-no-nvidia OK
else
    CHK initrd-no-nvidia REBUILD-FIRST
    ADD "initramfs of $NK still ships nvidia modules -> udev binds the cards first -> clean -16 failure. Rebooting now is safe (machine boots, unlock just does not engage): run 'update-initramfs -u -k all' first, then re-check"
fi

# 3. initramfs of the NEXT kernel must carry the unlock firmware
F2=$(lsinitramfs "/boot/initrd.img-$NK" 2>/dev/null | grep -c gpu-unlock)
if [ "${F2:-0}" -ge 1 ]; then
    CHK initrd-firmware OK
else
    CHK initrd-firmware FAIL
    ADD "unlock firmware missing from the initramfs of $NK (gpu-unlock-firmware hook not effective?)"
fi

# 4. gpu_unlock.ko built for the NEXT kernel
if [ -e "/lib/modules/$NK/updates/dkms/gpu_unlock.ko" ]; then
    CHK "module($NK)" OK
else
    CHK "module($NK)" MISSING
    ADD "gpu_unlock.ko missing for kernel $NK — install linux-headers-$NK, then: dkms install -m gpu-unlock -v 1.1.1 -k $NK; update-initramfs -u -k $NK"
fi

# 5. GRUB carries the gpu_unlock params
G=$(grep -c gpu_unlock /boot/grub/grub.cfg 2>/dev/null)
if [ "${G:-0}" -ge 1 ]; then
    CHK grub-gpu-unlock OK
else
    CHK grub-gpu-unlock FAIL
    ADD "no gpu_unlock params in /boot/grub/grub.cfg — run install_unlock.sh, then update-grub"
fi

# 6. workload containers (reboot kills them)
C=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "${CONTAINER_PATTERN:-RunningHub}")
if [ "${C:-0}" -eq 0 ]; then
    CHK workload-containers OK
else
    CHK workload-containers "BUSY ($C)"
    ADD "$C workload container(s) running — drain the traffic / pick a maintenance window first; a reboot kills running jobs"
fi

# 7. /boot free space
B=$(df -k /boot | awk 'NR==2{print $4}')
if [ -n "$B" ] && [ "$B" -ge 350000 ]; then
    CHK boot-free-KB OK
else
    CHK boot-free-KB "LOW (${B:-?} KB)"
    ADD "/boot free space below 350000 KB — remove old kernel initrds before rebooting"
fi

echo
if [ "${#BLOCK[@]}" -eq 0 ]; then
    echo "VERDICT: READY FOR HOT REBOOT"
    echo "next: sudo scripts/hot_reboot.sh"
    exit 0
fi
echo "VERDICT: BLOCKED — resolve these first:"
for r in "${BLOCK[@]}"; do
    echo "  - $r"
done
exit 1
