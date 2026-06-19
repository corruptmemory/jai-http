# High-Concurrency Collapse: Root Cause, Fix, and Reproducible Setup

**Date:** 2026-06-19
**Machine:** desktop — AMD Ryzen Threadripper 3970X (32C/64T), Artix Linux (OpenRC), kernel 7.0.12, `amd-pstate-epp`.
**Status:** Fixed. ~1.8M req/s at 32t/2000c, beating nginx on the same box.

## TL;DR

Throughput collapsed at high concurrency (t16+) — ~480K req/s where it should scale — while the
machine sat ~70% idle. Root cause: **`write_response` formatted the response header with `tprint`,
which is hardwired to Jai's temporary storage (it ignores `context.allocator`).** The default temp
storage is **16 KB per worker thread** and is reset only once per epoll *batch*; under load one batch
serves dozens of requests, overflowing temp storage into repeated heap page allocations
(`add_new_page`) — perf showed this as **~45% of CPU**. Fix: route header formatting through the
**per-request Pool** (`sprint`/`String_Builder` on `context.allocator`), and send the response while
that Pool is the context allocator, resetting it per request. Result: the collapse disappears and we
exceed nginx.

## How we found it (so it isn't re-litigated)

Ruled out, in order: governor/ulimit/sysctl tuning (≈0 effect); CPU mitigations (helped low
concurrency only); CPU C-states (~20% of the *buggy* high-conc loss, moot after the fix); worker
count (more workers = worse). The **decisive control was nginx**: same box, same kernel, same 16
workers + `reuseport`, same loopback — nginx scaled cleanly to 1.65M with no collapse, proving the
ceiling was *our code*, not the environment. Profiling our process (`perf record -p <pid>`) then
pointed straight at the temp-storage allocation in `write_response`.

## The fix (code)

`modules/http_server/http.jai` — `write_response` uses `sprint` / `String_Builder` bound to
`context.allocator` (not `tprint`/temp storage). `modules/http_server/server.jai` — `handle_client`
now sends the response *inside* the per-request Pool `push_context`, and `Pool_Module.reset()` runs
*after* the send, recycling the request's blocks (handler scratch + response header) in one shot.

**Principle:** every per-request allocation goes through the per-request Pool, reset between requests.
`write_response` was the one path that bypassed it.

## Results (3970X, tuned; mitigations as noted)

| wrk | collapse (bug) | **fixed (Pool)** | nginx (control) |
|-----|---------------:|-----------------:|----------------:|
| t1 / c10   | 213K | 238K  | 190K |
| t8 / c500  | 819K | 1.03M | 1.03M |
| t16 / c1000| ~480K | **1.78M** | 1.65M |
| t32 / c2000| ~519K | **1.81M** | 1.56M |

(A hand-rolled zero-alloc buffer hit ~1.92M but was bespoke; the Pool version is ~7% behind it,
traded for idiomatic, uniform allocation. Still beats nginx.)

## REPRODUCIBLE ENVIRONMENT (repeat verbatim on another box)

Artix/OpenRC specifics noted; on a systemd distro substitute the service mechanisms. **None of
these are required to *fix* the collapse — that's pure code — but they are needed to reproduce the
absolute numbers.**

### 1. Network sysctls — `/etc/sysctl.d/99-benchmark.conf`
```
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
```
Apply now: `sudo sysctl -p /etc/sysctl.d/99-benchmark.conf` · Persist: `sudo rc-update add sysctl boot`

### 2. Open-file limit — append to `/etc/security/limits.conf`
```
*       soft    nofile  65536
*       hard    nofile  524288
root    soft    nofile  65536
root    hard    nofile  524288
```
Effective after re-login/reboot. **Critical**: wrk at t32/c2000 needs >4096 fds, or the high-conc
points collapse for an unrelated (fd-exhaustion) reason.

### 3. CPU governor — `/etc/local.d/cpu-governor.start` (OpenRC; `amd-pstate-epp` offers only
`performance`/`powersave` governors — "balanced" there is an EPP setting, not a governor)
```sh
#!/bin/sh
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null; done
```
`sudo chmod +x /etc/local.d/cpu-governor.start && sudo rc-update add local default`

### 4. CPU mitigations — TESTED, then reverted
`mitigations=off` (GRUB `GRUB_CMDLINE_LINUX_DEFAULT`, then `grub-mkconfig`) gave **+~50% at LOW
concurrency** (the per-syscall IBPB/STIBP/vmscape tax) but is irrelevant to the high-concurrency
result once the allocation bug is fixed. **Final state: mitigations ON (default).** It's a known
low-concurrency lever with a security trade-off — enable only deliberately.

### 5. C-states — known further lever, NOT applied
Holding `/dev/cpu_dma_latency` at 0 (PM-QoS, forbids deep idle) recovered ~20% at high concurrency in
the *buggy* code; moot after the fix. Left at default. The CPU stays ~70% idle even at peak, so
deeper kernel tuning (C-states, IRQ/flow steering, `SO_INCOMING_CPU`) could push past current numbers
— not pursued; current result is understood and sufficient.

### Verify before benchmarking
```
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # performance
ulimit -n                                                    # >= 65536
sysctl net.core.somaxconn net.ipv4.tcp_slow_start_after_idle # 65535 ; 0
```

## BENCHMARK PROCEDURE
```bash
~/jai/jai/bin/jai-linux first.jai - hello_world -release
setsid ./build_release/hello_world >/tmp/srv.log 2>&1 </dev/null &   # port 9090, 16 workers
pid=$!
# wait until it's listening, then run the grid:
for cc in "1 10" "4 100" "8 500" "16 1000" "32 2000"; do
  set -- $cc; wrk -t$1 -c$2 -d10s http://localhost:9090/
done
kill -9 $pid
```
**Gotcha:** never `pkill -f hello_world` from a script — the script's own command line contains
"hello_world", so pkill kills the shell. Always kill by the tracked `$pid`.

## nginx CONTROL (apples-to-apples reference)
Prefix dir `~/jai-http-bench/nginx/`, `mkdir -p tmp`, then `~/jai-http-bench/nginx/nginx.conf`:
```nginx
worker_processes 16;                 # match our server
worker_rlimit_nofile 200000;
daemon off;
error_log <prefix>/error.log crit;
pid <prefix>/nginx.pid;
events { worker_connections 32768; multi_accept on; use epoll; }
http {
    access_log off;
    client_body_temp_path <prefix>/tmp/client;  proxy_temp_path <prefix>/tmp/proxy;
    fastcgi_temp_path <prefix>/tmp/fcgi;  uwsgi_temp_path <prefix>/tmp/uwsgi;  scgi_temp_path <prefix>/tmp/scgi;
    tcp_nodelay on;  keepalive_requests 1000000;  keepalive_timeout 75s;
    server { listen 9091 reuseport; location / { return 200 "Hello, World!"; } }
}
```
Run: `setsid nginx -p <prefix> -c <prefix>/nginx.conf & ` then the same wrk grid on `:9091`;
stop with `kill $(cat <prefix>/nginx.pid)`.
