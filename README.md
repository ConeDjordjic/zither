# zither

A web framework in Zig, on top of
[martensite](https://github.com/ConeDjordjic/martensite).

martensite does the HTTP. zither adds routing, a context for each request
and the accept loop.

```zig
const std = @import("std");
const zither = @import("zither");

const State = struct { greeting: []const u8 };
const Ctx = zither.Ctx(State);

const App = zither.App(State, &.{
    .get("/hello/:name", hello),
});

fn hello(c: *Ctx) !void {
    const text = try std.fmt.allocPrint(c.arena, "{s} {s}\n", .{ c.state.greeting, c.param("name").? });
    try c.respond(.text(.ok, text));
}

pub fn main(init: std.process.Init) !void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    var listener = try addr.listen(init.io, .{ .reuse_address = true });
    var state: State = .{ .greeting = "hello" };
    try App.run(init.io, init.gpa, &listener, &state, .{});
}
```

`examples/hello.zig` is a complete version of this.

## Routes

The route table is fixed at compile time. A segment that starts with `:`
matches any one segment, and the handler gets it with `c.param(name)`,
percent-decoded. A value that doesn't decode is a 400 and the handler
isn't called.

Two routes that match the same requests, a param with no name or the
same name twice, and a pattern that doesn't start with `/` are compile
errors.

When more than one route matches, a literal segment beats a param,
compared from the left. So `/recipes/new` wins over `/recipes/:slug`
whatever order you list them in. Empty segments are skipped, so
`/recipes/` is the same as `/recipes`.

A HEAD request runs the GET route for the path, unless you gave it a HEAD
route of its own. martensite leaves the body out. A path that exists but
not for the method gets a 405 with `Allow`. A method martensite has no
name for is a 501.

## The context

A handler gets a `*Ctx(State)` with:

- `state`, the one you passed to `run`. Every connection has the same
  one at the same time, so anything in it that changes needs a lock.
- `arena`, which is reset before the next request on the connection.
  Allocate anything the response needs from it.
- `http` and `req`, martensite's `Server` and `Request`. Everything in
  martensite's README applies. Let errors from `readBody` go up with
  `try`, and zither answers them the way martensite's `serve` would.
- `params`, plus `param(name)` to get one.
- `query(name)`, the first value for `name` in the query, decoded into
  the arena. A value with a bad `%` escape is `error.BadQuery`, which
  becomes a 400 if you let it go up.

## Errors

zither answers some requests itself. That covers a 404, a 405, a 501, a
request that couldn't be read, a param that doesn't decode and any error
a handler returns before it responds. The status comes from martensite's
`Status.forError`, so an error of your own is a 500.

By default those responses are plain text. For something else, like
JSON, pass `refuse` in the options. It gets the status and returns a
`Response`. zither sets the status on it and adds `Allow` to a 405.

```zig
fn refuse(status: martensite.Status) martensite.Response {
    return .json(status, "{\"error\":true}");
}

try App.run(io, gpa, &listener, &state, .{ .refuse = refuse });
```

A handler error that becomes a 5xx goes to `log_error`, which logs it
with `std.log` unless you give it something else.

## Connections

`run` accepts connections until the listener is shut down, and serves
each one on its own task. The `gpa` you give it is used from all of them
at once, so it has to be thread-safe. Each connection allocates three
buffers of `buffer` bytes and an arena. A request head has to fit in one
buffer.

A connection is dropped when a single read waits longer than `read`. The
head of a request has to arrive within `head`, and the handler has
`body` for everything after that, reading the body included. A peer that
is too slow gets a 408.

If you want your own accept loop, call `App.serveStream` for each
connection. If you want your own connection loop too, `App.Dispatch` is
the handler to give martensite's `serve`.

## License

MIT
