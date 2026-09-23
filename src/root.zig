//! A web framework on top of martensite.
//!
//! martensite does the HTTP. zither adds routing, a context for each
//! request and the accept loop.

const app = @import("app.zig");
const context = @import("context.zig");
const stop_mod = @import("stop.zig");

/// The martensite zither was built with. Use this one, so your types
/// match the ones on `Ctx`.
pub const martensite = @import("martensite");

pub const App = app.App;
pub const Route = app.Route;
pub const Handler = app.Handler;
pub const Options = app.Options;
pub const Ctx = context.Ctx;
pub const Params = context.Params;
pub const QueryError = context.QueryError;
pub const ReadJsonError = context.ReadJsonError;
pub const Cookie = context.Cookie;
pub const stop = stop_mod.stop;
pub const stopOnSignals = stop_mod.stopOnSignals;

test {
    _ = app;
    _ = context;
    _ = @import("router.zig");
    _ = @import("percent.zig");
    _ = @import("cookie.zig");
    _ = stop_mod;
}
