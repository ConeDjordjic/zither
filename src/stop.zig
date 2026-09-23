//! Stopping `run`. Both of these shut the listener down for reading,
//! which wakes a blocked accept with `SocketNotListening`. `run` takes
//! that as the signal to drain.

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const posix = std.posix;

/// Makes `run` stop accepting and drain. Safe to call from any thread.
pub fn stop(io: std.Io, listener: *const net.Server) void {
    const s: net.Stream = .{ .socket = listener.socket };
    s.shutdown(io, .recv) catch {};
}

var signaled: std.atomic.Value(posix.fd_t) = .init(-1);

/// Stops `run` on SIGINT or SIGTERM, which is what Ctrl-C, `docker stop`
/// and systemd send. Only one listener at a time, and POSIX only.
pub fn stopOnSignals(listener: *const net.Server) void {
    if (builtin.os.tag == .windows) @compileError("stopOnSignals needs POSIX signals");
    signaled.store(listener.socket.handle, .seq_cst);
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
}

/// A signal handler can only make async-signal-safe calls, so this goes
/// straight to the syscall instead of through an Io.
fn onSignal(_: posix.SIG) callconv(.c) void {
    const fd = signaled.load(.seq_cst);
    if (fd != -1) _ = posix.system.shutdown(fd, posix.SHUT.RD);
}
