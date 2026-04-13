const std = @import("std");

pub fn build(b: *std.Build) void {
	const cpu_model_opt = b.option([]const u8, "cpu-model", "CPU model override (baseline|native)");
	var target_query = b.standardTargetOptionsQueryOnly(.{});
	if (cpu_model_opt) |mode| {
		if (std.mem.eql(u8, mode, "baseline")) {
			target_query.cpu_model = .baseline;
		} else if (std.mem.eql(u8, mode, "native")) {
			target_query.cpu_model = .native;
		} else {
			std.debug.print("unknown cpu-model '{s}' (use baseline|native)\n", .{mode});
			return;
		}
	}
	const target = b.resolveTargetQuery(target_query);
	const optimize = b.standardOptimizeOption(.{});


	const cli_mod = b.createModule(.{
		.root_source_file = b.path("src/cli.zig"),
		.target = target,
		.optimize = optimize,
	});
	const cli = b.addExecutable(.{
		.name = "nanorq",
		.root_module = cli_mod,
	});
	b.installArtifact(cli);

	const bench_mod = b.createModule(.{
		.root_source_file = b.path("src/bench.zig"),
		.target = target,
		.optimize = optimize,
	});
	const bench = b.addExecutable(.{
		.name = "nanorq-bench",
		.root_module = bench_mod,
	});
	b.installArtifact(bench);

	const tests_mod = b.createModule(.{
		.root_source_file = b.path("src/tests.zig"),
		.target = target,
		.optimize = optimize,
	});
	const tests = b.addTest(.{
		.root_module = tests_mod,
	});

	const test_step = b.step("test", "Run unit tests");
	const run_tests = b.addRunArtifact(tests);
	test_step.dependOn(&run_tests.step);

	const bench_step = b.step("bench", "Run benchmark/report suite");
	const run_bench = b.addRunArtifact(bench);
	if (b.args) |args| {
		run_bench.addArgs(args);
	}
	bench_step.dependOn(&run_bench.step);
}
