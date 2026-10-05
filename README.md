# shark8-damon-reclaim-off

KernelSU module: stops `damon_reclaim` from thrashing zram.

Tested on: Blackview Shark 8, Android 13 GSI on nubia "rama982" vendor kernel
`5.10.223-rama982-gki-v1.19-ksu-g44f88c743ae7`, 8 GB RAM, KernelSU 0.9.4.

## Why

The phone showed a steady 180-800 major faults per second with no memory
pressure: 5.4 GiB `MemAvailable`, `PSI memory 0.00`, `oom_kill 0`, and zram only
35% used with healthy 2.85:1 compression. Every LRU reclaim counter was pinned at
zero, yet `pswpout` climbed and `workingset_refault_anon` tracked `pswpin` 1:1.
Reclaim was happening through a path that never touches those counters.

`swapoff /dev/block/zram0` stopped it dead, which put the source outside the LRU
engine. A `swap_writepage` kprobe then named the callers directly:

```
pswpout delta      25993
swap_writepage     25346   (97.6% match)
  kdamond.0-148       25677
  CachedAppOptimi-2387 10230
madvise_cold_or_pageout_pte_range  1686
  CachedAppOptimi-2387             1686   (100%)
```

`kdamond.0` is the DAMON reclaim thread (`/sys/module/damon_reclaim/parameters/
kdamond_pid` = 148). It was configured with:

| parameter | value | meaning |
|---|---|---|
| `monitor_region_start` | 5368709120 (5 GiB) | physical region handed to DAMON |
| `monitor_region_end` | 9663672319 (9 GiB) | spans the top of an 7.6 GiB RAM |
| `min_age` | 30000000 (30 s) | page age before eligible |
| `skip_anon` | N | anonymous pages **are** reclaimed |
| `enabled` | Y | thread running |
| `quota_sz` / `quota_reset_interval_ms` | 512 MiB / 1 s | rate cap |

With `skip_anon=N` it walks application anonymous memory and writes it to zram
via `process_madvise(MADV_PAGEOUT)`, which page-outs directly instead of going
through LRU reclaim. That is exactly the fingerprint: `pswpout` rises while
`pgscan_kswapd`, `pgsteal_kswapd`, `pgscan_direct`, `pgsteal_direct` and
`allocstall` stay at zero. The pages then come back as
`workingset_refault_anon` refaults, one major fault each.

GMS, wellbeing and vending were victims, not causes. They simply hold the most
anonymous memory, so DAMON picked them first. A victim process showed the
signature directly: 8 consecutive rounds with **both** `minflt` and `majflt`
frozen while its RSS fell 25.6 -> 24.5 MB and its `VmSwap` grew. A process
executing zero faults cannot page itself out; something else was writing its
tables.

`CachedAppOptimizer` (an AOSP thread in `system_server`) was the second source.
It issues the same `MADV_PAGEOUT` through `madviseVmasFromBatch()` in
`libandroid_servers.so`, confirmed by 1686 hits on
`madvise_cold_or_pageout_pte_range` from that thread alone. After a reboot with
DAMON disabled it turns out to be the *only* remaining writer, so it is the
residual this module cannot remove. See "Residual churn after reboot".

## What it does

`service.sh` writes `0` to `/sys/module/damon_reclaim/parameters/enabled`, which
terminates the `kdamond.0` kernel thread. Nothing else is touched.

`enabled` is a builtin kernel parameter, not a loadable module: it appears in no
`init.rc`, no `modules.load`, no boot cmdline and no property, and returns to `Y`
on every boot. So the script re-asserts it over a bounded 120 s window rather
than assuming it won the race against sysfs.

Normal reclaim is untouched. `kswapd0` and `kcompactd0` keep running, and zram
stays swapon'd, so there is still swap headroom when memory actually runs out.
Only DAMON's proactive, pressure-free page-out stops.

## Measured result

`enabled=0`, sampled 90 s after the write, in the same session:

| counter | before | after |
|---|---|---|
| `pswpout` | 383-13721/s | **0/s** |
| `pswpin` | 800/s | **0.17/s** |
| `pgmajfault` | 821/s | **0.17/s** |
| `workingset_refault_anon` | 793/s | **0.46/s** |
| swap used | 1691728 kB | falling, 1440696 kB |
| `MemAvailable` | 5192844 kB | 4917268 kB |

In that window the churn went fully silent: `swap_writepage` and
`madvise_cold_or_pageout_pte_range` both recorded **zero** hits.

Immediately after the write there is a short burst of `pswpin` (about 21k pages
over 10 s) as applications fault back in what DAMON had already pushed out.
It decays within about two minutes.

### Residual churn after reboot

Measured on one reboot with the module installed, the calm window above did **not**
hold immediately after boot. That boot showed a lower but non-zero rate:

| counter | pre-fix | after reboot with module |
|---|---|---|
| `pswpout` | 383-13721/s | **83-259/s** |
| `pgmajfault` | 821/s | **106/s** |

Read those two rows as one boot's snapshot rather than the module's steady state.
A later re-verification found a quieter floor; see "Re-verification" below.

A 300 s `swap_writepage` probe after reboot attributed the remaining traffic
entirely to `CachedAppOptimi` (TID 2434, in `system_server`):

```
pswpout delta   53907
swap_writepage  53907
  CachedAppOptimi-2434   53907   (100%)
```

`kdamond.0` is confirmed dead throughout (`enabled=N`, `kdamond_pid=-1`), so the
module did its job. The leftover is AOSP `CachedAppOptimizer`, which we found is
**not** gated by `config_enableCachedAppOptimizer` on this build: that name has
**zero** occurrences in `framework-res.apk`. `CachedAppOptimizer` has its own
`SettingsContentObserver`, so its tuning lives in SettingsProvider rather than in
framework resources. `dumpsys activity settings` shows the live knobs:

```
use_compaction=true
compact_throttle_min_oom_adj=900
compact_throttle_max_oom_adj=999
low_swap_threshold_percent=0.1
```

Note `use_compaction=true`. Its per-process stats report
`Total Physical ZRAM Consumed (KB)` and `Avg Compression Ratio`, so part of what
survives is compaction compressing anon memory into zram, not page-out.

`cmd activity memory-factor set NORMAL|CRITICAL` does not help: NORMAL left the
rate unchanged at ~72/s and CRITICAL made it **worse**, at 321/s. That knob
scales memory pressure, not swap traffic, so it is the wrong lever.

Removing the rest means overriding the `CachedAppOptimizer` settings, which needs
either an RRO or a `services.jar` patch. Deliberately out of scope here: the
residual is an order of magnitude below the original, and patching the framework
jar is a much larger risk than the churn it would remove.

### Re-verification

Re-checked on 2026-10-05 at ~1.75 h uptime with the module installed and unmodified.
The floor is quieter than the table above suggests, but it is not flat: the churn
arrives in bursts, and a single window can land on a burst or miss it entirely.

Invariants held for the whole session:

| check | value |
|---|---|
| `enabled` | `N` |
| `kdamond_pid` | `-1` |
| damon threads in `ps -A -T` | none |
| `nr_reclaim_tried_regions` | `0` |
| `bytes_reclaim_tried_regions` | `0` |
| `nr_quota_exceeds` | `0` |

`enabled` is a builtin parameter that returns to `Y` on every boot, so `N` this far
into uptime means `service.sh` ran and won its window. The three DAMON reclaim
counters being zero since boot say it never attempted a single reclaim.

A 123 s window caught a burst; a 180 s `swap_writepage` probe immediately after it
caught nothing at all:

| counter | 123 s window | 180 s kprobe window |
|---|---|---|
| `pswpout` | 695/s | **0/s** |
| `pgmajfault` | 26/s | **0/s** |
| `swap_writepage` hits | not probed | **0** |
| `pswpin` | 21.75/s | 0/s |
| `workingset_refault_anon` | 21.75/s | 0/s |
| `workingset_refault_file` | 87.28/s | 0/s |

`pgscan_kswapd`, `pgsteal_kswapd`, `pgscan_direct`, `pgsteal_direct` and
`compact_stall` held at zero across both windows, so the page-out path still
bypasses the LRU engine.

A 30 s-granularity sweep over ~9.5 min gave 16 of 19 completed windows at 0/s for
both `pswpout` and `pgmajfault`, plus one `pswpout` burst at 208/s and two
`pgmajfault` spikes at 119/s and 94/s. Memory state throughout: 972 MB swapped,
`MemAvailable` 4.6 GiB, PSI memory `some avg300=0.06` / `full avg300=0.00`, zram
4.16 GiB at ~2:1.

The honest summary: quiet by default, with unexplained bursts up to ~700/s. The
`CachedAppOptimizer` attribution did not reproduce, because the probe that would
have named a caller landed in a zero window.

### Attribution caveat

Single 60-90 s windows are not enough to attribute the two sources, because they
alternate on a multi-minute pulse. One window showed DAMON at 72% and
`CachedAppOptimizer` at 28%; the next showed the reverse. Only long probes
(90 s and 300 s) are trustworthy here, and the post-reboot numbers above come
from the longer ones.

The burst structure makes this worse than a single slow or fast window: at the
observed floor, a 180 s probe can legitimately return zero hits and still miss the
bursts. Attribute a burst, never the floor, and re-run until a probe actually
lands inside a burst.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
adb push release\shark8-damon-reclaim-off-1.2.zip /data/local/tmp/
adb shell '/data/adb/ksud module install /data/local/tmp/shark8-damon-reclaim-off-1.2.zip'
adb reboot
```

`ksud` is not on `PATH` here; the binary is `/data/adb/ksud`.

Or straight from source:

```powershell
adb push module\module.prop  /data/adb/modules/damon_reclaim_off/module.prop
adb push module\service.sh   /data/adb/modules/damon_reclaim_off/service.sh
adb push scripts\revert.sh   /data/adb/modules/damon_reclaim_off/scripts/revert.sh
adb shell chmod 755 /data/adb/modules/damon_reclaim_off/service.sh
adb shell chmod 755 /data/adb/modules/damon_reclaim_off/scripts/revert.sh
adb reboot
```

## Verify

```bash
adb shell cat /sys/module/damon_reclaim/parameters/enabled      # expect N
adb shell cat /sys/module/damon_reclaim/parameters/kdamond_pid   # expect -1
adb shell 'ps -A -T | grep -i damon || echo no damon threads'    # expect no damon threads

# DAMON's own reclaim counters, zero since boot if the module won
adb shell 'for k in nr_reclaim_tried_regions bytes_reclaim_tried_regions nr_quota_exceeds; do echo "$k=$(cat /sys/module/damon_reclaim/parameters/$k)"; done'

# churn: 30 s window, expect 0/s in a calm window
adb shell 'set -- $(grep ^pswpout /proc/vmstat); a=$2; sleep 30; set -- $(grep ^pswpout /proc/vmstat); b=$2; echo pswpout/s=$(( (b-a)/30 ))'
```

Do not write `grep ^pswpout /proc/vmstat` straight into `$((b-a))`. The match is
`pswpout 633501`, and arithmetic on that string is a syntax error, not a number:

```
/system/bin/sh: pswpout 633501: unexpected '633501'
```

`cut -d" " -f2` is the other trap: adb strips the inner double quotes on the way
through, `cut` errors out, and the empty variables then yield a confident
`pswpout/s=0`. That is a false negative. `set -- $(grep ...)` splits on
whitespace with no quoting to lose, so it survives the trip through PowerShell.

Expect **0/s** in a calm window, not a fixed residual. The bursts described above
still reach ~700/s, so a clean 30 s window is necessary but not sufficient evidence.
For a steady-state read, sample every 30 s for ten minutes and look at the spread.
See "Re-verification" above.

Logging lands under the `damon_reclaim_off` tag:

```bash
adb shell logcat -s damon_reclaim_off:*
```

## Revert

```bash
adb shell su -c 'sh /data/adb/modules/damon_reclaim_off/scripts/revert.sh'
```

`revert.sh` ships in the release zip as `scripts/revert.sh`. Verified on-device in
both directions: revert reports `enabled=Y` with a fresh `kdamond_pid`, and writing
`0` back returns `kdamond_pid=-1`.

Or just remove the module. The knob returns to `Y` on the next boot regardless.

## Notes

`skip_anon=1` was tried first and **did not work**. The write succeeded and the
readback showed `Y`, but DAMON kept page-ing anonymous pages at the same rate.
Setting `enabled=0` is what actually terminates the thread, so the module sets
that and leaves `skip_anon` alone.