#!/bin/sh
# The whole gate in one command: bring up a throwaway Redis, run both test files
# and the example against it, cross-check what was written with redis-cli, and
# tear the server down whether or not any of that passed.
#
#   sh scripts/run-tests.sh
#   MILO="bun run ../../milo/src/main.ts" sh scripts/run-tests.sh   # from a checkout
set -e
cd "$(dirname "$0")/.."
MILO="${MILO:-milo}"
PORT="${MILO_REDIS_PORT:-56379}"
PW="${MILO_REDIS_PASSWORD:-testpw}"

# EXIT alone is not enough: a ^C during the test run leaves a redis-server behind
# holding the port, and the next run then fails to bind.
cleanup() {
  sh scripts/test-server.sh stop >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "==> starting throwaway server"
MILO_REDIS_URL="$(sh scripts/test-server.sh start)"
export MILO_REDIS_URL
echo "    $MILO_REDIS_URL"

echo "==> tests"
$MILO test tests/redis_test.milo

# Separate file, separate reason: these need `DEBUG PROTOCOL`, which only exists
# on a server started with --enable-debug-command. They are not optional here —
# they are the only coverage the big-number, verbatim, boolean and attribute
# branches of the parser get.
echo "==> resp3 frame tests"
$MILO test tests/protocol_test.milo

echo "==> example"
$MILO run examples/cache.milo

# Everything above is this client agreeing with itself. redis-cli is a second,
# independent implementation reading the keys the example just wrote — without
# this step a client that mis-encoded every value identically on write and read
# would look perfect.
echo "==> redis-cli cross-check"
q() {
  redis-cli -p "$PORT" -a "$PW" --no-auth-warning "$@"
}
[ "$(q GET milo:greeting)" = "hello" ]   || { echo "milo:greeting wrong"; exit 1; }
[ "$(q GET milo:counter)" = "100" ]      || { echo "the pipeline did not apply 100 INCRs"; exit 1; }
[ "$(q GET milo:tx)" = "committed" ]     || { echo "the transaction did not commit"; exit 1; }
[ "$(q HGET milo:user name)" = "ada" ]   || { echo "hash field wrong"; exit 1; }
[ "$(q TYPE milo:scores)" = "zset" ]     || { echo "milo:scores is not a sorted set"; exit 1; }
[ "$(q ZSCORE milo:scores ada)" = "99.5" ] || { echo "sorted-set score wrong"; exit 1; }
[ "$(q LLEN milo:queue)" = "2" ]         || { echo "list length wrong"; exit 1; }
# The binary value: redis-cli counts the bytes, so this is an independent
# statement that the NULs and the embedded CRLF really are stored as data.
[ "$(q STRLEN milo:binary)" = "23" ]     || { echo "binary value is not 23 bytes on the server"; exit 1; }
q --no-raw GET milo:binary | grep -q '\\x00' || { echo "the stored value has no NUL byte"; exit 1; }
q --no-raw GET milo:binary | grep -q '\\xff' || { echo "the stored value has no 0xff byte"; exit 1; }
echo "    redis-cli agrees: strings, hash, list, zset, the 100-command pipeline"
echo "    and a 23-byte binary value containing NUL and 0xff"

echo "==> all green"
