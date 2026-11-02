#!/usr/bin/env bash
# Post-reboot verification for the GPU unlock.
#
# Checks:
#   1. dmesg unlocked count vs visible cards        (target: unlocked == cards, no failures)
#   2. any "unlock failed" lines in dmesg           (none expected)
#   3. nvidia-smi lists all cards                   (retry once if the driver is still settling)
#   4. workload container health                    (best-effort, inside the container)
#
# usage: sudo verify_unlock.sh [expected_card_count]
# env:   CONTAINER_PATTERN=<regex>   workload container name pattern (default RunningHub)
#        HEALTH_URL=<url>            in-container health endpoint (default http://127.0.0.1:8188/system_stats)
set -u

if [ "$(id -u)" != 0 ]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

EXPECT="${1:-}"
fail=0

printf '  %-18s %s\n' "dmesg unlocked" "$(dmesg 2>/dev/null | grep -c 'gpu_unlock: unlocked')"
U=$(dmesg 2>/dev/null | grep -c "gpu_unlock: unlocked")
F=$(dmesg 2>/dev/null | grep -c "unlock failed")
S=$(nvidia-smi -L 2>/dev/null | grep -c .)
printf '  %-18s %s\n' "unlock-failed" "$F"
printf '  %-18s %s\n' "nvidia-smi cards" "$S"

# 1. expected count, if given
if [ -n "$EXPECT" ] && [ "$U" -ne "$EXPECT" ]; then
    printf '  %-18s expected %s, got %s\n' "MISMATCH" "$EXPECT" "$U"
    fail=1
fi

# 3. nvidia-smi settles slowly on some boots — retry once
if [ "$S" -eq 0 ]; then
    sleep 30
    S=$(nvidia-smi -L 2>/dev/null | grep -c .)
    printf '  %-18s %s (after retry)\n' "nvidia-smi cards" "$S"
fi
if [ "$S" -eq 0 ]; then
    echo "  nvidia-smi shows no cards — check the failure quick-ref (docs/troubleshooting.md)"
    fail=1
fi

# 2. failure lines
if [ "$F" -gt 0 ]; then
    fail=1
    echo "  dmesg failure lines:"
    dmesg 2>/dev/null | grep -E "gpu_unlock" | head -12
fi

# unlocked must cover every visible card
if [ -n "$S" ] && [ "$S" -gt 0 ] && [ "$U" -lt "$S" ]; then
    printf '  %-18s unlocked %s < visible %s — see docs/troubleshooting.md (-110 row)\n' "SHORTFALL" "$U" "$S"
    fail=1
fi

# 4. workload container health (best-effort: a missing curl inside the container is a WARN, not a FAIL)
if command -v docker >/dev/null 2>&1; then
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        code=$(docker exec "$c" curl -s -o /dev/null -w '%{http_code}' -m 6 "${HEALTH_URL:-http://127.0.0.1:8188/system_stats}" 2>/dev/null)
        if [ "$code" = "200" ]; then
            printf '  %-18s %s HTTP 200\n' "container" "$c"
        elif [ -n "$code" ]; then
            printf '  %-18s %s HTTP %s\n' "container" "$c" "$code"
            fail=1
        else
            printf '  %-18s %s no response (curl missing inside container, or service still starting — verify manually)\n' "container" "$c"
        fi
    done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep "${CONTAINER_PATTERN:-RunningHub}")
    echo "  note: if your deployment tooling regenerates container env files on rebuild, re-verify required env vars after every reboot"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "VERDICT: PASS ($U card(s) unlocked)"
    exit 0
fi
echo "VERDICT: FAIL — see docs/troubleshooting.md (failure quick-ref)"
exit 1
