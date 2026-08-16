# redis API

## RESP2 and RESP3

This is the thing that shapes the whole client, so it comes first.

**RESP3 changes the reply _type_ for identical commands.** The same
`CONFIG GET maxmemory` is a flat array under RESP2 and a map under RESP3;
`ZSCORE` is a bulk string under RESP2 and a double under RESP3; `SMEMBERS` is an
array under RESP2 and a set under RESP3; a missing key is `$-1` under RESP2 and
`_` under RESP3. `HELLO 3` itself answers a map whose `modules` value is an array
of maps, so nested aggregates show up in the very first reply of the connection.

So this client never decodes a reply by command name. It decodes **the wire type
it actually received**, and `RedisValue` can represent everything either protocol
can send.

On connect it sends `AUTH` (when the URL carries a password) and then attempts
`HELLO 3`. A server with no `HELLO` — Redis older than 6 — answers
`ERR unknown command`, and the connection falls back to RESP2. Any other error is
a real failure and is returned, never swallowed into a silent downgrade.
`protocol()` reports which one is live:

```milo
var c = Conn.connect("redis://127.0.0.1:6379")!
print(c.protocol().toString())                       // 3, or 2 on an old server
var old = Conn.connect("redis://127.0.0.1:6379?protocol=2")!   // force RESP2
```

If you do not care which is live, use the normalising accessors and you will not
have to:

```milo
let v = c.cmd(["CONFIG", "GET", "maxmemory"])!
for p in v.asPairs() {            // same answer for a RESP2 array and a RESP3 map
    print(p.key + " = " + p.text())
}
c.smembers("tags")!               // Vec<string>, whether it arrived as ~ or *
c.zscore("scores", "ada")!        // Option<f64>, whether it arrived as , or $
```

## Connecting

```
redis://[[user]:password@]host[:port][/db][?protocol=2&client_name=svc]
```

Everything but the host is optional; the port defaults to 6379 and the database
to 0. Userinfo is percent-decoded, so a password containing `@` or `/` is written
`%40` / `%2F`. `redis://secret@host` with no colon reads the whole userinfo as a
password, matching `redis-cli`. Recognised query parameters are `protocol`
(2 or 3), `client_name` and `db`; anything else is ignored, because a URL is
usually shared with other tools.

`Conn.connect` returns once the connection is authenticated, the protocol is
negotiated and the database is selected — not merely once the socket opened.

## Values

```milo
pub enum RedisValue {
    Nil,                       // $-1 / *-1 (RESP2), _ (RESP3)
    Str(string),               // + simple, $ bulk
    Int(i64),                  // :
    Float(f64),                // , (RESP3)
    Bool(bool),                // # (RESP3)
    BigNum(string),            // ( (RESP3) — wider than i64, so kept as text
    Verbatim(string),          // = (RESP3)
    Array(Vec<RedisValue>),    // *
    Map(Vec<RedisValue>),      // % (RESP3) — flattened k, v, k, v
    Set(Vec<RedisValue>),      // ~ (RESP3)
    Push(Vec<RedisValue>),     // > (RESP3) — pub/sub and invalidation
}
```

`Map` holds its entries flattened rather than as pairs, for two reasons: that is
exactly the RESP2 shape of the same reply, so `asPairs()` needs no second code
path; and Redis map keys are values, not strings, so a `HashMap<string, _>` would
lose both the key types and the server's ordering.

**There is no error variant.** A server error comes back as `Result.Err`, so a
caller cannot accidentally treat a failure as data.

| Accessor | Gives |
|---|---|
| `typeName()` | `"map"`, `"set"`, `"double"`… — the wire type it really arrived as |
| `isNil()` | true only for a genuine null |
| `asStr()` | `Option<string>` — None for Nil, so `$-1` and `$0` stay distinct |
| `asI64()` / `asF64()` / `asBool()` | accept both protocols' spellings |
| `items()` | elements of any aggregate |
| `asStrings()` | every element as text |
| `asPairs()` | `Vec<Pair>` from a map **or** a flat array |
| `get(key)` | look a key up in a map-shaped reply |
| `text()` / `toString()` | display / debug rendering |

`$-1` (no such key) and `$0` (a key holding an empty string) are different
answers, and this client keeps them apart: `get()` returns `None` for the first
and `Some("")` for the second.

Values are binary-safe. RESP bulk strings are length-prefixed and never scanned
for a terminator, and Milo's `string` is an owned byte buffer, so a value
containing NUL bytes, CRLF or invalid UTF-8 round-trips byte for byte — in keys,
values and pub/sub payloads.

## Commands

`cmd` takes the command and its arguments as separate elements. Each goes on the
wire as its own length-prefixed bulk string, so an argument containing spaces,
newlines or NULs stays one argument:

```milo
let v = c.cmd(["SET", "k", untrusted])!     // not ["SET k " + untrusted]
```

Typed helpers wrap `cmd` for the common surface — they exist for discoverability,
not as a separate abstraction:

| | |
|---|---|
| strings | `get` `set` `setEx` `del` `delOne` `exists` `incr` `incrBy` `decr` `expire` `ttl` `keys` |
| hashes | `hget` `hset` `hgetall` `hdel` |
| lists | `lpush` `rpush` `lpop` `rpop` `lrange` `llen` |
| sets | `sadd` `srem` `smembers` `sismember` |
| sorted sets | `zadd` `zrange` `zscore` `zrem` |
| server | `ping` `flushdb` `publish` |

Anything not listed is one `cmd` call away.

## Pipelining

The single biggest performance lever a Redis client has. N commands cost N round
trips; the same N pipelined cost one, and against anything but a loopback socket
the round trip dominates everything else.

```milo
var p = Pipeline.new()
p.add(["SET", "a", "1"])
p.add(["INCR", "a"])
p.add(["GET", "a"])
let replies = c.runPipeline(p)!        // Vec<Result<RedisValue, RedisError>>
```

Each reply is its own `Result`: one command failing does not stop the others,
because the server already ran them all, and it does not shift the replies —
each keeps its slot. A socket failure comes back as the outer `Err`.

`writeCount()` and `readCount()` expose the socket's syscall counters, which is
how the test suite proves the claim rather than asserting a wall-clock time:
twenty pipelined commands add **1** to `writeCount()`, twenty separate ones add
twenty.

## Transactions

```milo
c.multi()!
let _ = c.cmd(["SET", "k", "v"])!      // server answers +QUEUED
let _ = c.cmd(["INCR", "n"])!
let res = c.exec()!
```

`exec()` gives an `ExecResult`:

- `replies` — one `Result` per queued command;
- `aborted` — the transaction was declined because a `WATCH`ed key changed. That
  is not a failure: nothing ran, and the right response is to retry.

**A command that queued cleanly can still fail at `EXEC`** — `INCR` on a list
queues fine and fails when it runs — so those errors surface per reply, not as
one failure for the whole transaction. Redis has no rollback: the commands after
a failing one still took effect, and reporting the whole transaction as failed
would be a lie about them.

A command that cannot even be queued (wrong arity, unknown name) aborts the
transaction, and `exec()` then returns `Err` with kind `EXECABORT`.

`discard()` throws the queue away.

## Pub/sub

```milo
var sub = Conn.connect(url)!
sub.subscribe(["news"])!
match sub.nextMessage(5000)! {         // timeout in ms
    Option.Some(m) => { print(m.channel + ": " + m.payload) }
    Option.None    => { print("nothing within 5s") }
}
```

`Ok(None)` means the wait expired — a subscriber with nothing to read is the
normal state, not a failure. `psubscribe` / `punsubscribe` do the pattern
variants and deliver `pmessage` with `m.pattern` set.

**The two protocols differ here in a way you cannot ignore, and this is where
naive clients break:**

- **RESP3** — deliveries arrive as push frames (`>`), out of band. The connection
  keeps working for ordinary commands while subscribed. A push that lands while a
  command reply is outstanding is stashed, not mistaken for the reply, and
  `nextMessage` hands it over afterwards.
- **RESP2** — the confirmation and every message are ordinary arrays, and the
  server puts the connection into *subscriber mode*, where it refuses everything
  except the subscribe commands, `PING`, `QUIT` and `RESET`. This client refuses
  those commands **locally**, with kind `CLIENT`, instead of writing them: a
  message frame may already be queued ahead of the server's error, so "read the
  reply" would return someone's published message and leave the error for the
  next call. Unsubscribing releases the restriction.

## Errors

```milo
pub struct RedisError { kind: string, message: string }
```

`kind` is the error's first word — for a server error that is Redis's prefix:
`WRONGTYPE`, `NOAUTH`, `WRONGPASS`, `MOVED`, `EXECABORT`, `ERR`. That prefix is
the stable part; message text gets reworded between releases, so it is the prefix
a program should branch on.

```milo
match c.incr("some-list") {
    Result.Ok(n)  => { print(n.toString()) }
    Result.Err(e) => {
        if e.kind == "WRONGTYPE" { print("that key is not a counter") }
    }
}
```

Client-side failures use three kinds Redis never sends — `CONNECTION` (the socket
failed), `PROTOCOL` (the bytes are not RESP we can parse, so the stream is
desynchronised and the connection must be discarded) and `CLIENT` (the call was
impossible before any bytes moved). `isLocal()` / `isServer()` tell them apart.

Note that `WRONGTYPE` means the key is the wrong *container*: `INCR` on a string
holding `"abc"` is `ERR value is not an integer`, because a string is a valid
target for `INCR`. Redis distinguishes the two and so does this client.

## Not implemented

Deliberately out of scope for v0.1:

- **Cluster** — no `MOVED` / `ASK` redirection following, no slot map. `MOVED`
  arrives as an ordinary error with `kind == "MOVED"`.
- **Sentinel** — no master discovery or failover.
- **Connection pooling** — one `Conn` is one socket carrying one conversation at
  a time. It is not thread-safe.
- **TLS** (`rediss://`) — rejected at parse time with a message saying so, rather
  than failing later in a way that looks like a protocol bug.
- **Client-side caching** — no `CLIENT TRACKING`, no invalidation push handling
  beyond parsing the frame.
- **`EVAL` / Lua and functions** — send them with `cmd` if you need them; there is
  no scripting-specific API.
- **Streams** — no `XADD` / `XREAD` helpers. `cmd` reaches them; the reply is a
  deeply nested aggregate you would have to walk yourself.
- **RESP3 attribute frames** are skipped, not surfaced. They are metadata attached
  to the next reply, and dropping them is correct; reading them is not.
- **`UNSUBSCRIBE` with no channels** — refused with kind `CLIENT`. The server
  answers it once per channel it happens to hold, and a client that guessed wrong
  would read a confirmation as the next command's reply. Name the channels.
- **IPv6 literals in a URL** (`redis://[::1]:6379`) are rejected. A hostname that
  resolves to IPv6 is fine.
- **`RESET`, `WAIT`, `SCAN` cursors** have no helpers; `cmd` reaches them all.

## Tests

The suite runs against a real server, never a mock:

```bash
sh scripts/run-tests.sh              # the whole gate, server started and stopped for you
```

or, against a server you already have:

```bash
sh scripts/test-server.sh start      # prints the URL
milo test tests/redis_test.milo
milo run examples/cache.milo
sh scripts/test-server.sh stop
```

`scripts/test-server.sh` sets `requirepass` **on purpose**. A stock redis-server
accepts unauthenticated connections, and under that the client's `AUTH` path
never executes — the suite would be green with the handshake entirely
unexercised. `testNoAuthRejected` is the negative control that proves auth is
really on.

It also passes `--enable-debug-command local`, which is what lets
`tests/protocol_test.milo` drive `DEBUG PROTOCOL <type>` and make the server emit
RESP3's big-number, verbatim, boolean and attribute frames. No ordinary command
produces those, so without it those parser branches have no coverage at all.
That option is startup-only, which is why those tests are a separate file: CI's
stock service container cannot be talked into it, and a test that silently passes
when the server cannot produce the frames it is testing would be worse than not
having it.

The last step of the gate is `redis-cli` reading back what the example wrote.
Everything before it is this client agreeing with itself.
