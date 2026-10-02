#!/usr/bin/env bash
#
# sashiko-watchdog.sh <commit-hash>
#
# Runs ./sashiko-gemini.sh <hash> and supervises it with a PROGRESS watchdog
# instead of a fixed timeout. A sashiko review has no bounded duration (minutes
# to an hour) but a HANG has a signature: no output, no CPU, and no live API
# connection for a long stretch. We poll for liveness and only kill when ALL
# signals have been dead for a generous grace window -- so a slow-but-alive
# review survives arbitrarily long, while a genuinely wedged one is reaped
# (along with the climit systemd scope it runs under).
#
# Env:
#   POLL   seconds between liveness samples          (default 30)
#   GRACE  seconds of total no-progress before kill  (default 900 = 15 min)
# The poll interval is only the SAMPLING rate; the kill decision needs GRACE
# worth of consecutive dead samples, never a single one.
#
# Exit codes (consumed by the sashiko-bounce agent):
#   0..N  sashiko-gemini.sh's own exit code (normal completion)
#   111   WATCHDOG killed a stalled run  (report as FAILURE, do NOT re-run)
#   2     bad usage / launch failure
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL="${POLL:-30}"
GRACE="${GRACE:-900}"
LOG_DIR="$SCRIPT_DIR/reviews"

hash="${1:-}"
case "$hash" in
    "" | -* )
        echo "usage: $0 <commit-hash-or-range>" >&2
        exit 2 ;;
esac

# For a range A..B the log is named by B's short hash (see sashiko-gemini.sh);
# for a single commit it is the hash itself. Use the last component for the
# log-discovery glob so a range run still finds its log.
disc="${hash##*..}"

now() { date +%s; }

# All descendant PIDs of $1 (recursive), via /proc — robust regardless of
# session/pgroup, which matters because sashiko-gemini.sh re-execs under climit
# (systemd-run --scope). The scope's processes stay descendants of MAIN_PID.
descendants() {
    local p=$1 kids k
    kids=$(cat "/proc/$p/task/$p/children" 2>/dev/null) || return 0
    for k in $kids; do
        echo "$k"
        descendants "$k"
    done
}

pid_set() { descendants "$MAIN_PID"; echo "$MAIN_PID"; }

# Sum of utime+stime (jiffies) over a set of pids. Parse after the "comm)" field
# so a process name containing spaces/parens can't shift the columns.
cpu_total() {
    local total=0 p line rest
    for p in "$@"; do
        line=$(cat "/proc/$p/stat" 2>/dev/null) || continue
        rest=${line#*) }              # drop "pid (comm) "
        set -- $rest                  # $1=state ... $12=utime $13=stime
        total=$(( total + ${12:-0} + ${13:-0} ))
        set -- "$@"                   # (no-op; keep shellcheck calm)
    done
    echo "$total"
}

# True if any of the pids holds a live network socket for the API call — an
# ESTABLISHED tcp connection, OR any udp socket (in case the HTTP client ever
# speaks QUIC/HTTP-3 over udp/443). Endpoint-agnostic on purpose, and matched by
# our own pids so unrelated connections (e.g. the calling session's) don't count.
# Deliberately inclusive: a false "alive" only delays a kill, a false "dead"
# would waste an expensive paid call, so we err toward not killing.
net_alive() {
    local re
    re=$(printf '%s|' "$@"); re=${re%|}
    [ -n "$re" ] || return 1
    { ss -tnpH state established 2>/dev/null; ss -unpH 2>/dev/null; } \
        | grep -qE "pid=($re)[,)]"
}

killtree() {
    local sig=$1 pids
    pids=$(pid_set)
    [ -n "$pids" ] && kill "-$sig" $pids 2>/dev/null
    return 0
}

# If the watchdog itself is terminated, take the whole review down with it so
# nothing (and no paid call) is orphaned.
trap 'killtree TERM; sleep 2; killtree KILL; exit 143' TERM INT

# Launch. exec so MAIN_PID stays stable across sashiko-gemini.sh's re-exec chain
# and `wait` returns the real exit code.
( exec "$SCRIPT_DIR/sashiko-gemini.sh" "$hash" ) &
MAIN_PID=$!

# Discover the log file sashiko writes (header appears within a second or two).
start=$(now)
logfile=""
for _ in $(seq 1 10); do
    logfile=$(ls -t "$LOG_DIR/${disc:0:7}"*-gemini-*.log 2>/dev/null | head -1)
    [ -n "$logfile" ] && break
    sleep 1
done

last_alive=$(now)
last_cpu=$(cpu_total $(pid_set))
last_logm=0
[ -n "$logfile" ] && last_logm=$(stat -c %Y "$logfile" 2>/dev/null || echo 0)

while kill -0 "$MAIN_PID" 2>/dev/null; do
    sleep "$POLL"
    pids=$(pid_set)

    cpu=$(cpu_total $pids)
    logm=0
    [ -n "$logfile" ] && logm=$(stat -c %Y "$logfile" 2>/dev/null || echo 0)

    if [ "$logm" -gt "$last_logm" ] || [ "$cpu" -gt "$last_cpu" ] || net_alive $pids; then
        last_alive=$(now)
    fi
    last_cpu=$cpu
    last_logm=$logm

    if [ $(( $(now) - last_alive )) -gt "$GRACE" ]; then
        echo "WATCHDOG: no progress (no output, no CPU, no live connection) for ${GRACE}s — killing stalled review." >&2
        killtree TERM; sleep 5; killtree KILL
        wait "$MAIN_PID" 2>/dev/null
        [ -z "$logfile" ] && logfile=$(ls -t "$LOG_DIR/${disc:0:7}"*-gemini-*.log 2>/dev/null | head -1)
        echo "WATCHDOG_KILLED after ${GRACE}s stall. Partial log: ${logfile:-<none written>}"
        exit 111
    fi
done

wait "$MAIN_PID"
rc=$?
[ -z "$logfile" ] && logfile=$(ls -t "$LOG_DIR/${disc:0:7}"*-gemini-*.log 2>/dev/null | head -1)
echo "sashiko finished rc=${rc}. Log: ${logfile:-<none written>}"
exit "$rc"
