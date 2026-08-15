#!/bin/sh
# Stand up a throwaway Redis for the test suite and tear it down.
#
# It sets `requirepass` deliberately. A stock redis-server accepts unauthenticated
# connections, under which the client's AUTH path never executes — the tests would
# pass while the handshake went unexercised. Same reason the postgres harness
# forces scram-sha-256 instead of accepting the default `trust`.
#
#   sh scripts/test-server.sh start   # prints the URL
#   sh scripts/test-server.sh stop
set -e
DIR="${MILO_REDIS_DIR:-/tmp/milo-redis-test}"
PORT="${MILO_REDIS_PORT:-56379}"
PW="${MILO_REDIS_PASSWORD:-testpw}"

case "$1" in
  start)
    rm -rf "$DIR"; mkdir -p "$DIR"
    # --save '' keeps it in-memory: a test server has no business writing an RDB,
    # and a stray dump.rdb would leak state into the next run.
    redis-server --port "$PORT" --requirepass "$PW" --save '' --appendonly no \
                 --dir "$DIR" --daemonize yes --pidfile "$DIR/redis.pid" \
                 --logfile "$DIR/redis.log"
    for _ in $(seq 50); do
      redis-cli -p "$PORT" -a "$PW" --no-auth-warning ping >/dev/null 2>&1 && break
      sleep 0.1
    done
    echo "redis://:$PW@127.0.0.1:$PORT/0"
    ;;
  stop)
    [ -f "$DIR/redis.pid" ] && kill "$(cat "$DIR/redis.pid")" 2>/dev/null || true
    rm -rf "$DIR"
    ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
