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
- `respond(r)`, which sends a martensite `Response` along with any
  headers you added with `header` or `setCookie`. Calling
  `c.http.respond` yourself sends the response without them.

## JSON

```zig
fn login(c: *Ctx) !void {
    const in = try c.readJson(struct { email: []const u8, password: []const u8 });
    // ...
    try c.json(.ok, .{ .id = id });
}
```

`readJson(T)` reads the body and parses it into a `T` in the arena.
Fields `T` doesn't have are skipped. Let its errors go up with `try` and
zither answers them:

- No body, bad JSON, or JSON that doesn't fit `T` is `error.BadJson`, a
  400.
- A Content-Type that isn't `application/json` is `error.NotJson`, a
  415. That also keeps a plain HTML form on another site from posting to
  a JSON route with your user's cookies, because a browser won't send
  `application/json` across sites without asking your server first.
- A body over `max_body` (1 MiB by default) is a 413. A chunked body
  gets a buffer of `max_body`, because it doesn't say how long it is.

Catch the error instead if one route wants its own answer.

`json(status, value)` writes `value` as JSON into the arena and sends it.

## Cookies

`c.cookie(name)` is the value of the first cookie with that name, from
any of the request's Cookie headers. Surrounding quotes are stripped and
nothing is decoded.

```zig
try c.setCookie(.{ .name = "sid", .value = sid, .max_age = 30 * 24 * 3600 });
try c.json(.ok, .{ .ok = true });
```

A cookie gets `Path=/`, `HttpOnly`, `Secure` and `SameSite=Lax` unless
you turn them off on it. Set `insecure_cookies` in the options to leave
`Secure` off everywhere while you develop over plain HTTP. Without
`max_age` it lasts until the browser closes. `c.clearCookie(name)`
deletes one that was set with the default path.

A name that isn't a token, or a value with a space, `;`, `,`, `"` or `\`
in it, is `error.InvalidCookie`. So is a path or domain with a `;`. A
value like that would otherwise add attributes of its own.

Cookies and headers are collected on the context and go out with the
next `respond` or `json`. If the handler fails instead, the response
zither sends for the error doesn't include them. So a login that set a
session cookie and then failed doesn't leave the browser with a session.

## Errors

zither answers some requests itself. That covers a 404, a 405, a 501, a
request that couldn't be read, a param that doesn't decode and any error
a handler returns before it responds. zither's own errors get the
statuses above. Anything else gets martensite's `Status.forError`, so an
error of your own is a 500.

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

`run` accepts connections until it is stopped, and serves each one on
its own task. The `gpa` you give it is used from all of them
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

## Stopping

`zither.stopOnSignals(&listener)` stops `run` on SIGINT or SIGTERM,
which covers Ctrl-C, `docker stop` and systemd. From your own code, call
`zither.stop(io, &listener)`.

Once stopped, `run` accepts nothing new. Requests already in a handler
get `grace` (10 seconds by default) to finish, and their responses say
`Connection: close`. After that, or as soon as no handler is running,
the connections left are closed and `run` returns. A request that
arrives on an idle connection right at that moment is cut off without an
answer. Canceling `run` instead closes everything at once.

`stopOnSignals` handles one listener and needs POSIX signals.

## License

MIT
