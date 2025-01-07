const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tiny = b.addModule("tiny", .{
        .root_source_file = b.path("src/tiny.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });

    const test_data = b.addModule("test-data", .{
        .root_source_file = b.path("test-data/data.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.root_module.addImport("test-data", test_data);
    const run_unit_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const exe = b.addExecutable(.{
        .name = "tiny",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lsp = b.dependency("zig-lsp-kit", .{});

    exe.root_module.addImport("tiny", tiny);
    exe.root_module.addImport("lsp", lsp.module("lsp"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const check_step = b.step("check", "ensure that the build suceeds");
    check_step.dependOn(&exe.step);

    const release_step = b.step("release", "compile binaries for all targets");
    const targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
    };

    for (targets) |t| {
        const release_target = b.resolveTargetQuery(t);
        const release_exe = b.addExecutable(.{
            .name = "tiny",
            .root_source_file = b.path("src/cli.zig"),
            .target = release_target,
            .optimize = .ReleaseSafe,
        });

        exe.root_module.addImport("tiny", tiny);
        exe.root_module.addImport("lsp", lsp.module("lsp"));

        const target_output = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{
                .custom = try t.zigTriple(b.allocator),
            } },
        });

        release_step.dependOn(&target_output.step);
    }
}
