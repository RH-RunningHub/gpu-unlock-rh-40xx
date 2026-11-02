#!/usr/bin/env bash
# Issue the hot reboot that activates the GPU unlock.
#
# 1. Runs the pre-flight checklist (hot_reboot_check.sh) and refuses on any
#    blocking finding.
# 2. Schedules the reboot detached from the SSH session — a bare
#    `nohup shutdown -r now &` is killed when the SSH session drops, so use
#    the setsid form below.
#
# usage: sudo hot_reboot.sh
# env:   I_UNDERSTAND_THIS_REBOOTS_THE_MACHINE=yes   required confirmation
#        FORCE=1                                     proceed despite checklist failure (not recommended)
set -u

if [ "$(id -u)" != 0 ]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"

if ! bash "$DIR/hot_reboot_check.sh"; then
    if [ "${FORCE:-0}" != "1" ]; then
        echo
        echo "ABORT: pre-flight checklist failed (see above). Fix the blockers and retry."
        echo "override (not recommended): FORCE=1 sudo scripts/hot_reboot.sh"
        exit 1
    fi
    echo "WARN: FORCE=1 — proceeding despite a failed checklist"
fi

if [ "${I_UNDERSTAND_THIS_REBOOTS_THE_MACHINE:-}" != "yes" ]; then
    echo
    echo "This will REBOOT this machine in 2 seconds. All running jobs die."
    echo "confirm: I_UNDERSTAND_THIS_REBOOTS_THE_MACHINE=yes sudo scripts/hot_reboot.sh"
    exit 1
fi

# Detached reboot: setsid detaches from the controlling terminal so the
# shutdown survives the SSH session closing; sleep 2 lets the command return.
setsid nohup bash -c 'sleep 2; shutdown -r now' </dev/null >/dev/null 2>&1 &

echo "reboot scheduled (2s). The SSH session may hang briefly — disconnect normally."
echo "the machine takes a few minutes to actually go down; reconnect after ~5-10 minutes, then run:"
echo "  sudo scripts/verify_unlock.sh"
