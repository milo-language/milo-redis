# RESP notes

From probing a real Redis 8.10 before writing the client. `docs/resp-probe.milo`
reproduces all of it — start the harness, then `milo run docs/resp-probe.milo`.

## Framing is the easy part

Every reply is a one-byte type tag then CRLF-delimited payload, and Milo strings
carry it directly — `TcpStream.send`/`recvOnce` is a usable byte channel (proven
the same way as the postgres client). Observed, RESP2:

    +OK\r\n                     simple string
    $5\r\nhello\r\n             bulk string
    $-1\r\n                     null bulk
    :1\r\n                      integer
    *2\r\n$1\r\nb\r\n$1\r\na\r\n array
    -ERR value is not an integer or out of range\r\n   error

## The real hazard is RESP2 vs RESP3

After `HELLO 3` the **same command returns a different type**:

    CONFIG GET maxmemory
      RESP2 → *2\r\n$9\r\nmaxmemory\r\n$1\r\n0\r\n     flat array, pairs by position
      RESP3 → %1\r\n$9\r\nmaxmemory\r\n$1\r\n0\r\n     map

`HELLO 3` itself answers `%7` — a map whose `modules` value is an array of maps,
so the parser must handle **nested aggregates** from the very first reply of the
connection.

This is the design constraint: a client cannot decode replies by command name.
It must parse the wire type it actually receives, and the value model has to
represent map and set types that only exist in RESP3. Two workable designs:

1. Speak RESP2 only, and never send `HELLO 3` — simplest, and every command still
   works. RESP3 push messages (needed for good pub/sub) are then unavailable.
2. Speak RESP3, and normalise maps down to pairs so callers see one shape.

Pick one deliberately and say which in the README. Do not let it depend on
whether `HELLO` happened to be sent.

## Auth runs, because the harness forces it

`scripts/test-server.sh` sets `requirepass`. Without it a stock redis-server
accepts unauthenticated connections and the client's `AUTH` path never executes
while the tests still pass. Unauthenticated commands answer
`-NOAUTH Authentication required.`, which is also the negative control a test
should assert.
