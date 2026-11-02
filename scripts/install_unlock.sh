#!/usr/bin/env bash
# gpu-unlock files-only deployment for RTX 4090 / RTX 4090D.
#
# Installs, in this order:
#   1. the two initramfs hooks   (BEFORE dpkg, so the dpkg-triggered rebuild
#                                  is already the skinny one)
#   2. the dkms + firmware debs  (from ./debs/, supplied by you)
#   3. gpu_unlock.ko for every kernel that has headers
#   4. GRUB gpu_unlock.* params  (appended, never overwrites existing params)
#   5. a full initramfs rebuild  (nvidia-free + firmware-carrying)
#
# NEVER reboots. The unlock engages at the NEXT reboot — see
# hot_reboot_check.sh / hot_reboot.sh for the activation path.
#
# usage: sudo install_unlock.sh <4090|4090D> [targets_csv]
#        targets_csv omitted -> generated from lspci (gen_targets.sh)
# env:   DEBS_DIR=<dir>   where the two .deb packages live (default ../debs)
set -u

MODEL="${1:-}"
TARGETS="${2:-}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEBS_DIR="${DEBS_DIR:-$ROOT_DIR/debs}"
DKMS_VER="1.1.1"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "RESULT FAIL: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
case "$MODEL" in 4090|4090D) ;; *) die "usage: install_unlock.sh <4090|4090D> [targets_csv]" ;; esac
command -v dkms    >/dev/null 2>&1 || die "dkms is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required (GRUB editing)"

# ---- targets ---------------------------------------------------------------
if [ -z "$TARGETS" ]; then
    log "no targets given; generating from lspci"
    TARGETS=$("$ROOT_DIR/scripts/gen_targets.sh" --targets-only) || die "gen_targets failed"
fi
case ",$TARGETS," in *",all,"*) die "targets=all is not supported; list the real PCI addresses (gen_targets.sh)" ;; esac
TCOUNT=$(echo "$TARGETS" | awk -F, '{print NF}')

# ---- pre-state -------------------------------------------------------------
N=$(nvidia-smi -L 2>/dev/null | grep -c .)
U=$(dmesg 2>/dev/null | grep -c "gpu_unlock: unlocked")
P=$(dpkg -l 2>/dev/null | grep gpu-unlock | grep -c "^ii")
log "pre-state: cards=$N unlocked=$U pkgs=$P targets=$TCOUNT"
if [ -n "$N" ] && [ "$N" -ne "$TCOUNT" ]; then
    log "WARN: nvidia-smi reports $N card(s) but targets list has $TCOUNT — verify the GPU count before any reboot"
fi

# ---- idempotency gate ------------------------------------------------------
if [ "$P" -ge 2 ] && [ -x /etc/initramfs-tools/hooks/gpu-unlock-firmware ] \
                 && [ -x /etc/initramfs-tools/hooks/zz-exclude-nvidia ]; then
    G2=$(grep -c gpu_unlock /boot/grub/grub.cfg 2>/dev/null)
    N2=$(lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -cE '(^|/)nvidia(_[a-z]+)?\.ko')
    F2=$(lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -c gpu-unlock)
    if [ "${G2:-0}" -ge 1 ] && [ "${N2:-1}" -eq 0 ] && [ "${F2:-0}" -ge 1 ]; then
        log "files already in place; nothing to do"
        echo "RESULT FILES-DONE pkgs=$P nvidia_ko=${N2:-?} fw=${F2:-?} grub=${G2:-?}"
        exit 0
    fi
    log "files present but incomplete (nvidia_ko=${N2:-?} fw=${F2:-?} grub=${G2:-?}); redeploying"
fi

# ---- /boot gate ------------------------------------------------------------
BK=$(df -k /boot | awk 'NR==2{print $4}')
log "/boot available: ${BK:-unknown} KB"
if [ -n "$BK" ] && [ "$BK" -lt 350000 ]; then
    die "boot-full: /boot has only ${BK} KB free (<350000). Remove old kernel initrds first."
fi

# ---- hooks BEFORE dpkg -----------------------------------------------------
log "writing initramfs hooks (before dpkg, so the first rebuild is already skinny)"
mkdir -p /etc/initramfs-tools/hooks
install -m 0755 "$ROOT_DIR/hooks/gpu-unlock-firmware" /etc/initramfs-tools/hooks/gpu-unlock-firmware \
    || die "hook-write-firmware"
install -m 0755 "$ROOT_DIR/hooks/zz-exclude-nvidia"   /etc/initramfs-tools/hooks/zz-exclude-nvidia \
    || die "hook-write-nvidia"

# ---- packages --------------------------------------------------------------
DKMS_DEB=$(ls "$DEBS_DIR"/gpu-unlock-*dkms*.deb     2>/dev/null | head -1)
FW_DEB=$(ls   "$DEBS_DIR"/gpu-unlock-*firmware*.deb 2>/dev/null | head -1)
[ -n "$DKMS_DEB" ] || die "no gpu-unlock-*dkms*.deb found in $DEBS_DIR (see README: where to get the packages)"
[ -n "$FW_DEB" ]   || die "no gpu-unlock-*firmware*.deb found in $DEBS_DIR"
log "installing $(basename "$DKMS_DEB") + $(basename "$FW_DEB") (dkms build may take 1-2 min)"
dpkg -i "$DKMS_DEB" "$FW_DEB" >/tmp/gpu-unlock-dpkg.log 2>&1 \
    || { tail -5 /tmp/gpu-unlock-dpkg.log >&2; die "dpkg failed - see /tmp/gpu-unlock-dpkg.log"; }
P=$(dpkg -l 2>/dev/null | grep gpu-unlock | grep -c "^ii")
[ "$P" -ge 2 ] || die "dpkg: packages not fully installed (ii=$P)"

# ---- dkms for every kernel -------------------------------------------------
log "building gpu_unlock.ko for every kernel with headers"
for k in $(ls /lib/modules 2>/dev/null); do
    [ -e "/lib/modules/$k/build" ] || continue
    dkms install -m gpu-unlock -v "$DKMS_VER" -k "$k" >/tmp/gpu-unlock-dkms.log 2>&1 \
        || log "dkms $k install rc=$? (check /tmp/gpu-unlock-dkms.log)"
done
NK=$(ls -v /boot/vmlinuz-* 2>/dev/null | tail -1 | sed 's/.*vmlinuz-//')
MISSING=""
for k in "$NK" "$(uname -r)"; do
    [ -n "$k" ] && [ -e "/lib/modules/$k/build" ] || continue
    [ -e "/lib/modules/$k/updates/dkms/gpu_unlock.ko" ] || MISSING="$MISSING $k"
done
if [ -n "$MISSING" ]; then
    die "gpu_unlock.ko missing for kernel(s):$MISSING (install linux-headers-<k>, then dkms install -m gpu-unlock -v $DKMS_VER -k <k>)"
fi

# ---- initramfs rebuild -----------------------------------------------------
log "rebuilding initramfs (all kernels)"
update-initramfs -u -k all >/tmp/gpu-unlock-uif.log 2>&1 \
    || { tail -3 /tmp/gpu-unlock-uif.log >&2; die "update-initramfs failed - see /tmp/gpu-unlock-uif.log"; }
NCHK=$(lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -cE '(^|/)nvidia(_[a-z]+)?\.ko')
FCHK=$(lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -c gpu-unlock)
log "initramfs check: nvidia_ko=${NCHK:-?} (need 0), gpu_unlock_files=${FCHK:-?} (need >=1)"
if [ "${NCHK:-1}" -gt 0 ] || [ "${FCHK:-0}" -lt 1 ]; then
    die "initramfs check failed (nvidia_ko=${NCHK:-?} fw=${FCHK:-?}) - see docs/troubleshooting.md"
fi

# ---- GRUB ------------------------------------------------------------------
log "appending GRUB params (backup: /etc/default/grub.bak_unlock_<date>)"
cat > /tmp/gpu-unlock-grub.py <<'PYEOF'
import re, sys, time
model, targets = sys.argv[1], sys.argv[2]
path = "/etc/default/grub"
src = open(path).read()
open(path + ".bak_unlock_" + time.strftime("%Y%m%d"), "w").write(src)
add = "gpu_unlock.targets=%s" % targets
if model == "4090D":
    add += " gpu_unlock.rtx4090d_experimental=1"
if "gpu_unlock." in src:
    print("grub already has gpu_unlock params; no edit")
else:
    m = re.search(r'(?m)^GRUB_CMDLINE_LINUX="([^"]*)"', src)
    if m is None:
        src = src + '\nGRUB_CMDLINE_LINUX="%s"\n' % add
    else:
        cur = m.group(1).strip()
        new = (cur + " " + add).strip()
        src = src[:m.start()] + 'GRUB_CMDLINE_LINUX="%s"' % new + src[m.end():]
    open(path, "w").write(src)
    print("grub updated; added:", add)
PYEOF
python3 /tmp/gpu-unlock-grub.py "$MODEL" "$TARGETS" || die "grub-edit failed"
rm -f /tmp/gpu-unlock-grub.py
update-grub >/tmp/gpu-unlock-grub.log 2>&1 || die "update-grub failed - see /tmp/gpu-unlock-grub.log"
GCHK=$(grep -c gpu_unlock /boot/grub/grub.cfg 2>/dev/null)
if [ "${GCHK:-0}" -lt 1 ]; then
    die "grub-cfg has no gpu_unlock entries (count=${GCHK:-0})"
fi

echo "RESULT FILES-OK pkgs=$P nvidia_ko=${NCHK:-?} fw=${FCHK:-?} grub=$GCHK cards=$N targets=$TCOUNT"
log "files-only deployment done. The unlock engages at the NEXT reboot."
log "next: sudo scripts/hot_reboot_check.sh   # pre-flight checklist before rebooting"
