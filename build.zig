const std = @import("std");

const examples: []const []const u8 = &.{
    "compiler",
    "comptime",
    "csv",
    "eval",
    "json",
    "jsonpath",
    "mule",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run tests");

    const mod = b.addModule("zpc", .{
        .root_source_file = b.path("src/zpc.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const rt_path = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;

    if (coverage) {
        mod_tests.use_llvm = true;
        mod_tests.sanitize_coverage_trace_pc_guard = true;
        mod_tests.root_module.link_libc = true;
        if (rt_path) |p| mod_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }

    inline for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ example ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zpc", .module = mod },
                },
            }),
        });

        b.installArtifact(exe);

        const exe_run_step = b.step(example, "Run the " ++ example ++ " example");

        const exe_run_cmd = b.addRunArtifact(exe);
        exe_run_step.dependOn(&exe_run_cmd.step);

        exe_run_cmd.step.dependOn(b.getInstallStep());

        exe_run_cmd.addPassthruArgs();

        if (false) {
            const exe_tests = b.addTest(.{
                .root_module = exe.root_module,
            });

            const run_exe_tests = b.addRunArtifact(exe_tests);
            test_step.dependOn(&run_exe_tests.step);
        }
    }
}
