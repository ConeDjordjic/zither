const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const martensite = b.dependency("martensite", .{
        .target = target,
        .optimize = optimize,
    }).module("martensite");

    const mod = b.addModule("zither", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "martensite", .module = martensite }},
    });

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const hello = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zither", .module = mod }},
        }),
    });
    b.installArtifact(hello);
}
