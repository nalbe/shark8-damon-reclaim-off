#!/system/bin/sh
# Re-enable damon_reclaim. Undoes damon_reclaim_off at runtime.
# The module's service.sh will fight this on the next boot.

PARAM=/sys/module/damon_reclaim/parameters

if [ ! -e "$PARAM/enabled" ]; then
    echo "damon_reclaim absent, nothing to revert"
    exit 0
fi

echo 1 > "$PARAM/enabled" 2>/dev/null || {
    echo "write failed"
    exit 1
}

echo "enabled=$(cat $PARAM/enabled)"
echo "kdamond_pid=$(cat $PARAM/kdamond_pid 2>/dev/null)"