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
    # --enable-debug-command lets the suite reach `DEBUG PROTOCOL <type>`, the only
    # way to make a server emit RESP3's big-number, verbatim, boolean and attribute
    # frames on demand. Without it those parser branches have no test at all. It is
    # a startup-only option, which is why tests/protocol_test.milo is a separate
    # file: a stock server (CI's service container) cannot turn it on afterwards.
    redis-server --port "$PORT" --requirepass "$PW" --save '' --appendonly no \
                 --enable-debug-command local \
                 --dir "$DIR" --daemonize yes --pidfile "$DIR/redis.pid" \
                 --logfile "$DIR/redis.log"
    # The loop must be followed by a CHECK, not just fall through. Without one
    # `start` prints a URL and exits 0 even when redis-server failed to bind —
    # every test then dies on a connect error that points nowhere, or worse
    # connects to a stale server on the port that has none of this config.
    ok=no
    for _ in $(seq 100); do
      if redis-cli -p "$PORT" -a "$PW" --no-auth-warning ping >/dev/null 2>&1; then
        ok=yes; break
      fi
      sleep 0.1
    done
    if [ "$ok" != yes ]; then
      echo "redis-server did not come up on port $PORT" >&2
      [ -f "$DIR/redis.log" ] && tail -20 "$DIR/redis.log" >&2
      exit 1
    fi
    echo "redis://:$PW@127.0.0.1:$PORT/0"
    ;;
  stop)
    # Wait for the process to actually go: kill(1) returns as soon as the signal
    # is queued, so a stop immediately followed by a start raced the old server
    # off the port and the new one failed to bind.
    if [ -f "$DIR/redis.pid" ]; then
      pid=$(cat "$DIR/redis.pid")
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
    fi
    rm -rf "$DIR"
    ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
