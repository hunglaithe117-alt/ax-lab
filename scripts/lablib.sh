#!/usr/bin/env bash
# Shared helpers for the ax learning lab's server-backed lessons.
#
# Sourced, never executed. Every lesson that needs Redis + ax-server sources
# this file and installs `trap lab_cleanup EXIT`, so a run always leaves the
# machine in the state it found it in.
#
# Nothing here touches a Kubernetes cluster, a kube context, or the network
# beyond 127.0.0.1. The CLI is pointed at the server with AX_SERVER, which
# internal/tunnel/tunnel.go:185-187 checks *before* it would ever look at a
# kube context.

# --- configuration ----------------------------------------------------------

# Port selection.
#
# The lab brief asked for host port 16379 for Redis and 18081 for the API
# server. In this environment both are contended: another project's container
# publishes 16379, and another lesson in this same track binds 18081 - and
# either can be torn down underneath a run, which turns a healthy run into a
# confusing "connection refused" halfway through.
#
# So the defaults are the lab-owned ports 16390 / 18091, and the brief's ports
# are honoured if you ask for them:
#
#   AXLAB_REDIS_PORT=16379 AXLAB_SERVER_ADDR=127.0.0.1:18081 ./examples/03-.../run.sh
#
# The Redis container port is always 6379; only the published host port moves.
LAB_REDIS_CONTAINER="axlab-redis"
LAB_REDIS_IMAGE="redis:7-alpine"
LAB_REDIS_PORTS=(16390 16391 16392 16379)
LAB_SERVER_PORTS=(18091 18092 18093 18081)
LAB_SERVER_ADDR=""

# --- output -----------------------------------------------------------------

lab_section() { printf '\n=== %s ===\n' "$*"; }
lab_note()    { printf '  %s\n' "$*"; }
lab_cmd()     { printf '\n$ %s\n' "$*"; }

# --- ports ------------------------------------------------------------------

lab_port_busy() {
  local port="$1"
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$"
}

lab_pick_redis_port() {
  local port
  for port in "${LAB_REDIS_PORTS[@]}"; do
    if ! lab_port_busy "$port"; then
      echo "$port"
      return 0
    fi
  done
  echo "no free host port among: ${LAB_REDIS_PORTS[*]}" >&2
  return 1
}

# lab_pick_server_addr returns 127.0.0.1:<port> for the first free port.
lab_pick_server_addr() {
  local port
  for port in "${LAB_SERVER_PORTS[@]}"; do
    if ! lab_port_busy "$port"; then
      echo "127.0.0.1:$port"
      return 0
    fi
  done
  echo "no free host port among: ${LAB_SERVER_PORTS[*]}" >&2
  return 1
}

# --- redis ------------------------------------------------------------------

# lab_start_redis removes any container this lab left behind, then starts a
# fresh one so every run begins from a known-empty Redis. The
# LAB_STARTED_REDIS flag is set as soon as the container exists, so even a
# Redis that never answers PING is cleaned up by the caller's EXIT trap.
lab_start_redis() {
  docker rm -f "$LAB_REDIS_CONTAINER" >/dev/null 2>&1 || true
  if ! docker run -d --name "$LAB_REDIS_CONTAINER" -p "$LAB_REDIS_PORT:6379" "$LAB_REDIS_IMAGE" >/dev/null; then
    LAB_ERROR="docker run --name $LAB_REDIS_CONTAINER -p $LAB_REDIS_PORT:6379 failed"
    return 1
  fi
  LAB_STARTED_REDIS=1
  local i
  for i in $(seq 1 50); do
    if [ "$(docker exec "$LAB_REDIS_CONTAINER" redis-cli ping 2>/dev/null)" = "PONG" ]; then
      return 0
    fi
    sleep 0.1
  done
  LAB_ERROR="redis in $LAB_REDIS_CONTAINER never answered PING"
  return 1
}

lab_redis() { docker exec "$LAB_REDIS_CONTAINER" redis-cli "$@"; }

# lab_assert_redis re-checks that the lesson's Redis is still ours and still
# answering. A shared machine means something else can tear the container down
# mid-run; catching that here gives a clear message instead of a gRPC
# "connection refused" several steps later. If LAB_EXPECT_KEY is set, that
# exact key must still hold a value.
lab_assert_redis() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$LAB_REDIS_CONTAINER"; then
    LAB_ERROR="the Redis container $LAB_REDIS_CONTAINER is no longer running (something else on this machine removed it)"
    return 1
  fi
  if [ "$(lab_redis ping 2>/dev/null)" != "PONG" ]; then
    LAB_ERROR="redis in $LAB_REDIS_CONTAINER stopped answering PING"
    return 1
  fi
  if [ -n "${LAB_EXPECT_KEY:-}" ] && [ -z "$(lab_redis get "$LAB_EXPECT_KEY" 2>/dev/null)" ]; then
    LAB_ERROR="$LAB_EXPECT_KEY vanished from Redis mid-run"
    return 1
  fi
  return 0
}

# --- ax-server --------------------------------------------------------------

lab_start_server() {
  local logfile="$LAB_TMP/ax-server.log"
  : >"$logfile"
  "$LAB_AX_SERVER_BIN" --addr "$LAB_SERVER_ADDR" --redis-addr "127.0.0.1:$LAB_REDIS_PORT" \
    >>"$logfile" 2>&1 &
  LAB_SERVER_PID=$!
  export AX_SERVER="$LAB_SERVER_ADDR"
  local i
  for i in $(seq 1 100); do
    if ! kill -0 "$LAB_SERVER_PID" 2>/dev/null; then
      LAB_ERROR="ax-server exited immediately; log: $(cat "$logfile")"
      return 1
    fi
    # --max-time matters: if some *other* process already owns this port and
    # accepts without answering, an untimed curl blocks forever.
    if curl -fsS --max-time 2 "http://$LAB_SERVER_ADDR/healthz" >/dev/null 2>&1; then
      # A stale listener on the same port would answer /healthz for us while
      # our own process dies of "address already in use". Re-check liveness
      # after a beat so that race cannot pass silently.
      sleep 0.3
      if ! kill -0 "$LAB_SERVER_PID" 2>/dev/null; then
        LAB_ERROR="something else is already serving $LAB_SERVER_ADDR; log: $(cat "$logfile")"
        return 1
      fi
      LAB_LOG_FILE="$logfile"
      return 0
    fi
    sleep 0.1
  done
  LAB_ERROR="ax-server never became healthy on $LAB_SERVER_ADDR; log: $(cat "$logfile")"
  return 1
}

lab_stop_server() {
  [ -n "${LAB_SERVER_PID:-}" ] || return 0
  kill "$LAB_SERVER_PID" 2>/dev/null || true
  local i
  for i in $(seq 1 50); do
    kill -0 "$LAB_SERVER_PID" 2>/dev/null || { LAB_SERVER_PID=""; return 0; }
    sleep 0.1
  done
  kill -9 "$LAB_SERVER_PID" 2>/dev/null || true
  wait "$LAB_SERVER_PID" 2>/dev/null || true
  LAB_SERVER_PID=""
}

# --- CLI --------------------------------------------------------------------

# lab_ax runs the real prebuilt CLI against the lesson's server.
lab_ax() { AX_SERVER="$LAB_SERVER_ADDR" "$LAB_AX_BIN" "$@"; }

# --- cleanup ----------------------------------------------------------------

lab_cleanup() {
  local rc=$?
  lab_stop_server || true
  if [ -n "${LAB_REDIS_PORTS[0]:-}" ] && [ "${LAB_STARTED_REDIS:-0}" = "1" ]; then
    docker rm -f "$LAB_REDIS_CONTAINER" >/dev/null 2>&1 || true
  fi
  [ -n "${LAB_TMP:-}" ] && rm -rf "$LAB_TMP"
  return $rc
}
