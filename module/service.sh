#!/system/bin/sh
# damon_reclaim off - KernelSU module, v1.0
#
# damon_reclaim is a DAMON reclaim kernel thread, built into the nubia
# "rama982" kernel rather than a loadable module. On this device it is handed
# the physical region 5-9 GiB with min_age=30s and skip_anon=N, so it walks
# application anonymous memory and pushes it into zram through
# process_madvise(MADV_PAGEOUT). That path skips the LRU reclaim engine, which
# is why pswpout climbed while pgscan_kswapd, pgsteal_kswapd, pgscan_direct,
# pgsteal_direct and allocstall all stayed pinned at zero.
#
# Measured effect of enabled=0 over 90s:
#   pswpout      383-13721/s -> 0/s
#   pgmajfault   821/s       -> 0.17/s
#
# Reclaim still happens the normal way when memory actually runs out: kswapd0
# and kcompactd0 are untouched, and zram remains swapon'd as OOM headroom.
#
# enabled is a kernel builtin parameter, so it returns to Y on every boot.
# Re-assert it until the sysfs node is stable rather than racing the mount.

TAG=damon_reclaim_off
PARAM=/sys/module/damon_reclaim/parameters

log() { /system/bin/log -p i -t "$TAG" "$1" 2>/dev/null; }

log "=== damon_reclaim_off service start ==="

if [ ! -e "$PARAM/enabled" ]; then
    log "damon_reclaim absent, nothing to do"
    exit 0
fi

# Re-assert for a bounded window: early boot may mount sysfs after us, and a
# later writer could flip the flag back. Bounded, never an open loop.
i=0
while [ $i -lt 60 ]; do
    if [ -e "$PARAM/enabled" ]; then
        cur=$(cat "$PARAM/enabled" 2>/dev/null)
        [ "$cur" = "Y" ] && echo 0 > "$PARAM/enabled" 2>/dev/null
    fi
    sleep 2
    i=$((i + 1))
done

log "enabled=$(cat $PARAM/enabled 2>/dev/null) kdamond_pid=$(cat $PARAM/kdamond_pid 2>/dev/null)"
log "=== done ==="