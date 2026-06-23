#!/usr/bin/env bash
# Benchmark runner for jai-http with transient CPU-governor management.
#
# Flips every CPU to the `performance` governor ONLY for the duration of the run,
# and restores each CPU to ITS OWN previous governor on exit. The restore runs
# from a trap, so it fires on normal exit, Ctrl-C, and failures alike — a laptop
# is never left stuck on `performance` draining battery. The previous governors
# are snapshotted per-policy (not assumed uniform, not hardcoded to powersave).
#
# Usage:
#   ./bench.sh            # benchmark our release server  (build_release/hello_world, :9090)
#   ./bench.sh nginx      # benchmark the nginx control reference (:9091)
#
# Env knobs:  DUR=10s  (per-point wrk duration)
#
# Requires a release build first:  ~/jai/jai/bin/jai-linux first.jai - hello_world -release
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-server}"
DUR="${DUR:-10s}"
GRID=("1 10" "4 100" "8 500" "16 1000" "32 2000")

GOV_GLOB=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
SAVED="$(mktemp /tmp/jai-bench-gov.XXXXXX)"
PID=""
NGINX_PID_FILE=""

# Snapshot each policy's current governor: "<path> <governor>" per line.
for f in "${GOV_GLOB[@]}"; do printf '%s %s\n' "$f" "$(cat "$f")"; done > "$SAVED"

set_all_gov() { sudo env G="$1" sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do printf "%s\n" "$G" > "$f"; done'; }
restore_gov() { sudo env S="$SAVED" sh -c 'while read -r f g; do printf "%s\n" "$g" > "$f"; done < "$S"'; }

cleanup() {
  # Graceful nginx master shutdown first (reaps its reuseport workers), then hard-kill the tracked pid.
  if [ "$MODE" = nginx ] && [ -n "$NGINX_PID_FILE" ] && [ -f "$NGINX_PID_FILE" ]; then
    kill "$(cat "$NGINX_PID_FILE")" 2>/dev/null; sleep 0.3
  fi
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
  restore_gov
  echo "[bench] governors restored to their previous values (cpu0 -> $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor))"
  rm -f "$SAVED"
}
trap cleanup EXIT INT TERM

echo "[bench] governor -> performance (transient; previous values saved to $SAVED)"
set_all_gov performance
echo "[bench] $(grep -l performance "${GOV_GLOB[@]}" | wc -l)/$(nproc) CPUs at performance"

if [ "$MODE" = nginx ]; then
  PREFIX="$HOME/jai-http-bench/nginx"
  mkdir -p "$PREFIX/tmp"
  NGINX_PID_FILE="$PREFIX/nginx.pid"
  cat > "$PREFIX/nginx.conf" <<EOF
worker_processes 16;
worker_rlimit_nofile 60000;
daemon off;
error_log $PREFIX/error.log crit;
pid $PREFIX/nginx.pid;
events { worker_connections 32768; multi_accept on; use epoll; }
http {
    access_log off;
    client_body_temp_path $PREFIX/tmp/client;  proxy_temp_path $PREFIX/tmp/proxy;
    fastcgi_temp_path $PREFIX/tmp/fcgi;  uwsgi_temp_path $PREFIX/tmp/uwsgi;  scgi_temp_path $PREFIX/tmp/scgi;
    tcp_nodelay on;  keepalive_requests 1000000;  keepalive_timeout 75s;
    server { listen 9091 reuseport; location / { return 200 "Hello, World!"; } }
}
EOF
  PORT=9091; TARGET="nginx control"
  setsid nginx -p "$PREFIX" -c "$PREFIX/nginx.conf" >/tmp/nginx-bench.log 2>&1 </dev/null &
  PID=$!
else
  PORT=9090; TARGET="jai-http (build_release/hello_world)"
  setsid "$REPO/build_release/hello_world" >/tmp/srv.log 2>&1 </dev/null &
  PID=$!
fi
URL="http://127.0.0.1:$PORT/"
echo "[bench] started $TARGET pid=$PID on :$PORT (16 workers)"

ok=0
for i in $(seq 1 80); do
  if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then ok=1; break; fi
  sleep 0.1
done
if [ "$ok" != 1 ]; then
  echo "[bench] $TARGET did not come up:"
  if [ "$MODE" = nginx ]; then cat /tmp/nginx-bench.log "$HOME/jai-http-bench/nginx/error.log" 2>/dev/null; else cat /tmp/srv.log; fi
  exit 1
fi

wrk -t2 -c50 -d3s "$URL" >/dev/null 2>&1   # warmup, not measured
echo "[bench] $TARGET — grid ($DUR each):"
for cc in "${GRID[@]}"; do
  set -- $cc
  echo "=================== wrk -t$1 -c$2 ==================="
  wrk -t"$1" -c"$2" -d"$DUR" "$URL"
done
