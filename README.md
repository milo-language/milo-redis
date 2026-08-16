# redis

This is a package for the [Milo language](https://milo-language.github.io/milo/).

## Overview

Talk to Redis: connect with a URL, run commands, read replies.

```milo
var db = Conn.connect("redis://:pw@127.0.0.1:6379/0")!
db.set("greeting", "hello")!
```

It speaks RESP directly, so there is no hiredis and no C dependency for the
protocol. One fact shapes the whole client: **RESP3 changes the reply _type_ for
identical commands**, so this client never decodes a reply by command name, only
by the wire type it actually received. It negotiates `HELLO 3` on connect and
falls back to RESP2 on a server too old to know it, and the normalising
accessors give you the same answer either way.

Absent rather than stubbed in v0.1: cluster redirection, sentinel, connection
pooling, TLS (`rediss://`), client-side caching, and helpers for streams or Lua.
`cmd` reaches any command that has no typed helper.

Full API, the value model, transactions, pub/sub and error kinds:
[docs/api.md](docs/api.md).

## Installation

```bash
milo add github.com/milo-language/milo-redis
```

```milo
from "redis" import { Conn, Pipeline }
```

## Examples

### Commands

```milo
from "redis" import { Conn }

fn main(): i32 {
    var db = Conn.connect("redis://127.0.0.1:6379/0")!
    print($"protocol {db.protocol()}")

    db.set("greeting", "hello")!
    print(db.get("greeting")! ?? "<nil>")

    // A key that is not there is None, not "".
    print(db.get("nope")! ?? "<nil>")

    db.hset("user:1", "name", "ada")!
    print(db.hget("user:1", "name")! ?? "<nil>")

    db.close()
    return 0
}
```

```
protocol 3
hello
<nil>
ada
```

`cmd` takes the command and its arguments as separate elements, each going on
the wire as its own length-prefixed bulk string, so an argument containing
spaces, newlines or NULs stays one argument:

```milo
let v = c.cmd(["SET", "k", untrusted])!     // not ["SET k " + untrusted]
```

### Pipelining

The single biggest performance lever a Redis client has. N commands cost N round
trips; the same N pipelined cost one, and against anything but a loopback socket
the round trip dominates everything else:

```milo
from "redis" import { Conn, Pipeline }

fn main(): i32 {
    var db = Conn.connect("redis://127.0.0.1:6379/0")!
    db.delOne("hits")!

    let before = db.writeCount()

    var p = Pipeline.new()
    for i in 0..100 {
        p.add(["INCR", "hits"])
    }
    let replies = db.runPipeline(p)!

    print($"{replies.len()} replies in {db.writeCount() - before} write")
    print($"hits = {db.get("hits")! ?? "0"}")

    db.close()
    return 0
}
```

```
100 replies in 1 write
hits = 100
```

`writeCount()` and `readCount()` expose the socket's syscall counters, which is
how that claim gets proven rather than asserted. Each reply is its own `Result`:
one command failing does not stop the others, because the server already ran
them all, and it does not shift the replies out of their slots.

### Pub/sub

```milo
from "redis" import { Conn }

fn main(): i32 {
    var sub = Conn.connect("redis://127.0.0.1:6379/0")!
    sub.subscribe(["news"])!

    // A second connection does the publishing.
    var pub = Conn.connect("redis://127.0.0.1:6379/0")!
    pub.publish("news", "ship it")!
    pub.close()

    match sub.nextMessage(5000)! {          // timeout in ms
        Option.Some(m) => {
            print($"{m.channel}: {m.payload}")
        }
        Option.None => {
            print("nothing within 5s")
        }
    }

    sub.close()
    return 0
}
```

```
news: ship it
```

`Ok(None)` means the wait expired: a subscriber with nothing to read is the
normal state, not a failure. Under RESP2 the server puts the connection into
subscriber mode and refuses ordinary commands, which this client enforces
locally rather than writing a command it knows will fail.
[docs/api.md](docs/api.md) explains why that matters.
