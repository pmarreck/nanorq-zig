const std = @import("std");
const nanorq = @import("nanorq.zig");
const core = @import("core/mod.zig");
const arg_parse = @import("arg_parse.zig");

// 0.16: std.time.nanoTimestamp() is gone. Use Io.Timestamp via the
// single-threaded global Io.
inline fn nsNow() i128 {
	const io = std.Io.Threaded.global_single_threaded.io();
	return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

const Formats = arg_parse.Formats;

const Row = struct {
	noise_pct: f64,
	trials: usize,
	successes: usize,
	success_rate: f64,
	avg_encode_mbps: f64,
	avg_decode_mbps: f64,
	avg_total_mbps: f64,
};

const MemProfile = struct {
	noise_pct: f64,
	iterations: usize,
	warmup: usize,
	baseline_current: usize,
	baseline_peak: usize,
	end_current: usize,
	end_peak: usize,
	delta_current: i64,
	delta_peak: i64,
	delta_allocated: usize,
	delta_freed: usize,
	allocs: usize,
	frees: usize,
	resizes: usize,
	remaps: usize,
	avg_allocated_per_iter: f64,
};

const MicroResult = struct {
	cols: usize,
	iters: usize,
	add_mbps: f64,
	axpy_b1_mbps: f64,
	axpy_b2_mbps: f64,
	scal_b2_mbps: f64,
};

const NoiseMode = enum {
	pct,
	ber,
};

fn noiseLabel(mode: NoiseMode) []const u8 {
	return switch (mode) {
		.pct => "noise_pct",
		.ber => "ber",
	};
}

fn shapeLabel(mode: NoiseMode, shape: nanorq.NoiseShape) []const u8 {
	return switch (mode) {
		.pct => shapeName(shape),
		.ber => "ber",
	};
}

fn setNoiseValue(noise: *nanorq.NoiseParams, mode: NoiseMode, value: f64) void {
	switch (mode) {
		.pct => {
			noise.pct = value;
			noise.ber = null;
		},
		.ber => {
			noise.ber = value;
			noise.pct = 0.0;
		},
	}
}

pub fn main(init: std.process.Init) !void {
	const allocator = init.gpa;
	const io = init.io;

	const args0 = try init.minimal.args.toSlice(init.arena.allocator());
	const args = try init.arena.allocator().alloc([]const u8, args0.len);
	for (args0, 0..) |a, idx| args[idx] = a;

	if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
		try printUsage(io);
		return;
	}

	var input_size: usize = 1 * 1024 * 1024;
	var params = nanorq.EncodeParams{ .symbol_size = 1280, .alignment = 8, .crc = true };
	var redundancy = nanorq.Redundancy{};
	var noise = nanorq.NoiseParams{ .pct = 0.0, .shape = .random };
	var noise_mode = NoiseMode.pct;
	var trials: usize = 5;
	var formats = Formats{ .text = true, .csv = true, .json = true };
	var noise_pcts = try defaultNoisePcts(allocator);
	var mem_profile = false;
	var mem_iterations: usize = 25;
	var mem_warmup: usize = 5;
	var micro = false;
	var micro_iters: usize = 50_000;
	var micro_cols: ?usize = null;
	defer allocator.free(noise_pcts);

	var i: usize = 1;
	while (i < args.len) : (i += 1) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--input-size")) {
			i += 1;
			input_size = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--symbol-size")) {
			i += 1;
			params.symbol_size = try parseU16(args, i);
		} else if (std.mem.eql(u8, arg, "--align")) {
			i += 1;
			params.alignment = try parseU8(args, i);
		} else if (std.mem.eql(u8, arg, "--overhead-pct")) {
			i += 1;
			redundancy.overhead_pct = try parseF64(args, i);
		} else if (std.mem.eql(u8, arg, "--repair-count")) {
			i += 1;
			redundancy.repair_symbols = try parseU32(args, i);
		} else if (std.mem.eql(u8, arg, "--drop-pct")) {
			i += 1;
			redundancy.drop_pct = try parseF64(args, i);
		} else if (std.mem.eql(u8, arg, "--crc")) {
			params.crc = true;
		} else if (std.mem.eql(u8, arg, "--no-crc")) {
			params.crc = false;
		} else if (std.mem.eql(u8, arg, "--noise-pcts")) {
			i += 1;
			allocator.free(noise_pcts);
			noise_pcts = try parsePctList(allocator, args[i]);
			noise_mode = .pct;
		} else if (std.mem.eql(u8, arg, "--ber")) {
			i += 1;
			const value = try parseF64(args, i);
			allocator.free(noise_pcts);
			noise_pcts = try singleValueList(allocator, value);
			noise_mode = .ber;
		} else if (std.mem.eql(u8, arg, "--ber-list")) {
			i += 1;
			allocator.free(noise_pcts);
			noise_pcts = try parsePctList(allocator, args[i]);
			noise_mode = .ber;
		} else if (std.mem.eql(u8, arg, "--shape")) {
			i += 1;
			noise.shape = try parseShape(args, i);
		} else if (std.mem.eql(u8, arg, "--include-tags")) {
			noise.symbol_bytes_only = false;
		} else if (std.mem.eql(u8, arg, "--cluster-size")) {
			i += 1;
			noise.cluster_size = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--cluster-count")) {
			i += 1;
			noise.cluster_count = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--center")) {
			i += 1;
			noise.center = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--sigma")) {
			i += 1;
			noise.sigma = try parseF64(args, i);
		} else if (std.mem.eql(u8, arg, "--seed")) {
			i += 1;
			noise.seed = try parseU64(args, i);
		} else if (std.mem.eql(u8, arg, "--trials")) {
			i += 1;
			trials = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--format")) {
			i += 1;
			formats = try parseFormats(args, i);
		} else if (std.mem.eql(u8, arg, "--mem-profile")) {
			mem_profile = true;
		} else if (std.mem.eql(u8, arg, "--mem-iterations")) {
			i += 1;
			mem_iterations = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--mem-warmup")) {
			i += 1;
			mem_warmup = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--micro")) {
			micro = true;
		} else if (std.mem.eql(u8, arg, "--micro-iters")) {
			i += 1;
			micro_iters = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--micro-cols")) {
			i += 1;
			micro_cols = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			try printUsage(io);
			return;
		} else {
			return error.UnknownOption;
		}
	}

	const input = try allocator.alloc(u8, input_size);
	defer allocator.free(input);
	fillRandom(input, noise.seed);

	var rows = std.ArrayList(Row).empty;
	defer rows.deinit(allocator);
	var mem_profiles = std.ArrayList(MemProfile).empty;
	defer mem_profiles.deinit(allocator);
	var micro_result: ?MicroResult = null;

	for (noise_pcts) |pct| {
		var local_noise = noise;
		setNoiseValue(&local_noise, noise_mode, pct);
		const result = try nanorq.simulate(allocator, input, params, redundancy, local_noise, trials);
		try rows.append(allocator, Row{
			.noise_pct = pct,
			.trials = result.trials,
			.successes = result.successes,
			.success_rate = result.success_rate,
			.avg_encode_mbps = result.avg_encode_mbps,
			.avg_decode_mbps = result.avg_decode_mbps,
			.avg_total_mbps = result.avg_total_mbps,
		});
	}

	if (mem_profile) {
		for (noise_pcts) |pct| {
			var local_noise = noise;
			setNoiseValue(&local_noise, noise_mode, pct);
			const profile = try runMemProfile(allocator, input, params, redundancy, local_noise, pct, mem_iterations, mem_warmup);
			try mem_profiles.append(allocator, profile);
		}
	}

	if (micro) {
		const cols = micro_cols orelse params.symbol_size;
		micro_result = try runMicroBench(allocator, cols, micro_iters);
	}

	try printReport(io, rows.items, formats, noise_mode, noise.shape, if (mem_profile) mem_profiles.items else null, micro_result);
}

fn printReport(io: std.Io, rows: []const Row, formats: Formats, mode: NoiseMode, shape: nanorq.NoiseShape, mem_profiles: ?[]const MemProfile, micro_result: ?MicroResult) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	const label = noiseLabel(mode);
	if (formats.text) {
		if (findZeroRow(rows)) |row| {
			try out.interface.print("raw throughput ({s}=0)\n", .{label});
			try out.interface.print("encode_mbps={d:.2} decode_mbps={d:.2} total_mbps={d:.2}\n\n", .{ row.avg_encode_mbps, row.avg_decode_mbps, row.avg_total_mbps });
		}
		try out.interface.print("resilience report (shape={s})\n", .{shapeLabel(mode, shape)});
		for (rows) |row| {
			if (mode == .ber) {
				try out.interface.print("{s}={e:.3} success_rate={d:.4} encode_mbps={d:.2} decode_mbps={d:.2} total_mbps={d:.2}\n", .{ label, row.noise_pct, row.success_rate, row.avg_encode_mbps, row.avg_decode_mbps, row.avg_total_mbps });
			} else {
				try out.interface.print("{s}={d:.2} success_rate={d:.4} encode_mbps={d:.2} decode_mbps={d:.2} total_mbps={d:.2}\n", .{ label, row.noise_pct, row.success_rate, row.avg_encode_mbps, row.avg_decode_mbps, row.avg_total_mbps });
			}
		}
		if (mem_profiles) |profiles| {
			try out.interface.print("\nmemory profile (shape={s})\n", .{shapeLabel(mode, shape)});
			for (profiles) |profile| {
				if (mode == .ber) {
					try out.interface.print(
						"{s}={e:.3} warmup={d} iterations={d} delta_current={d} delta_peak={d} alloc_bytes={d} freed_bytes={d} allocs={d} frees={d} resizes={d} remaps={d}\n",
						.{ label, profile.noise_pct, profile.warmup, profile.iterations, profile.delta_current, profile.delta_peak, profile.delta_allocated, profile.delta_freed, profile.allocs, profile.frees, profile.resizes, profile.remaps },
					);
				} else {
					try out.interface.print(
						"{s}={d:.2} warmup={d} iterations={d} delta_current={d} delta_peak={d} alloc_bytes={d} freed_bytes={d} allocs={d} frees={d} resizes={d} remaps={d}\n",
						.{ label, profile.noise_pct, profile.warmup, profile.iterations, profile.delta_current, profile.delta_peak, profile.delta_allocated, profile.delta_freed, profile.allocs, profile.frees, profile.resizes, profile.remaps },
					);
				}
			}
		}
		if (micro_result) |micro| {
			try out.interface.print("\nmicrobench (octmat cols={d} iters={d} simd_bytes={d})\n", .{ micro.cols, micro.iters, core.octmat.simdBytes() });
			try out.interface.print("addRow_mbps={d:.2} axpy_b1_mbps={d:.2} axpy_b2_mbps={d:.2} scal_b2_mbps={d:.2}\n", .{
				micro.add_mbps,
				micro.axpy_b1_mbps,
				micro.axpy_b2_mbps,
				micro.scal_b2_mbps,
			});
		}
	}
	if (formats.csv) {
		try out.interface.print("{s},shape,trials,successes,success_rate,avg_encode_mbps,avg_decode_mbps,avg_total_mbps\n", .{label});
		for (rows) |row| {
			if (mode == .ber) {
				try out.interface.print("{e:.6},{s},{d},{d},{d:.6},{d:.4},{d:.4},{d:.4}\n", .{ row.noise_pct, shapeLabel(mode, shape), row.trials, row.successes, row.success_rate, row.avg_encode_mbps, row.avg_decode_mbps, row.avg_total_mbps });
			} else {
				try out.interface.print("{d:.4},{s},{d},{d},{d:.6},{d:.4},{d:.4},{d:.4}\n", .{ row.noise_pct, shapeLabel(mode, shape), row.trials, row.successes, row.success_rate, row.avg_encode_mbps, row.avg_decode_mbps, row.avg_total_mbps });
			}
		}
		if (mem_profiles) |profiles| {
			try out.interface.print("mem_{s},shape,warmup,iterations,baseline_current,end_current,delta_current,baseline_peak,end_peak,delta_peak,delta_allocated,delta_freed,allocs,frees,resizes,remaps,avg_allocated_per_iter\n", .{label});
			for (profiles) |profile| {
				if (mode == .ber) {
					try out.interface.print(
						"{e:.6},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.4}\n",
						.{ profile.noise_pct, shapeLabel(mode, shape), profile.warmup, profile.iterations, profile.baseline_current, profile.end_current, profile.delta_current, profile.baseline_peak, profile.end_peak, profile.delta_peak, profile.delta_allocated, profile.delta_freed, profile.allocs, profile.frees, profile.resizes, profile.remaps, profile.avg_allocated_per_iter },
					);
				} else {
					try out.interface.print(
						"{d:.4},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.4}\n",
						.{ profile.noise_pct, shapeLabel(mode, shape), profile.warmup, profile.iterations, profile.baseline_current, profile.end_current, profile.delta_current, profile.baseline_peak, profile.end_peak, profile.delta_peak, profile.delta_allocated, profile.delta_freed, profile.allocs, profile.frees, profile.resizes, profile.remaps, profile.avg_allocated_per_iter },
					);
				}
			}
		}
	}
	if (formats.json) {
		try out.interface.writeAll("{\"shape\":\"");
		try out.interface.print("{s}", .{shapeLabel(mode, shape)});
		try out.interface.writeAll("\"");
		if (findZeroRow(rows)) |row| {
			try out.interface.writeAll(",\"raw_throughput\":{");
			try out.interface.writeAll("\"avg_encode_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_encode_mbps});
			try out.interface.writeAll(",\"avg_decode_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_decode_mbps});
			try out.interface.writeAll(",\"avg_total_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_total_mbps});
			try out.interface.writeAll("}");
		}
		if (mem_profiles) |profiles| {
			try out.interface.writeAll(",\"memory_profile\":[");
			for (profiles, 0..) |profile, idx| {
				if (idx != 0) try out.interface.writeAll(",");
				try out.interface.writeAll("{\"");
				try out.interface.writeAll(label);
				try out.interface.writeAll("\":");
				if (mode == .ber) {
					try out.interface.print("{e:.6}", .{profile.noise_pct});
				} else {
					try out.interface.print("{d:.6}", .{profile.noise_pct});
				}
				try out.interface.writeAll(",\"warmup\":");
				try out.interface.print("{d}", .{profile.warmup});
				try out.interface.writeAll(",\"iterations\":");
				try out.interface.print("{d}", .{profile.iterations});
				try out.interface.writeAll(",\"baseline_current\":");
				try out.interface.print("{d}", .{profile.baseline_current});
				try out.interface.writeAll(",\"end_current\":");
				try out.interface.print("{d}", .{profile.end_current});
				try out.interface.writeAll(",\"delta_current\":");
				try out.interface.print("{d}", .{profile.delta_current});
				try out.interface.writeAll(",\"baseline_peak\":");
				try out.interface.print("{d}", .{profile.baseline_peak});
				try out.interface.writeAll(",\"end_peak\":");
				try out.interface.print("{d}", .{profile.end_peak});
				try out.interface.writeAll(",\"delta_peak\":");
				try out.interface.print("{d}", .{profile.delta_peak});
				try out.interface.writeAll(",\"delta_allocated\":");
				try out.interface.print("{d}", .{profile.delta_allocated});
				try out.interface.writeAll(",\"delta_freed\":");
				try out.interface.print("{d}", .{profile.delta_freed});
				try out.interface.writeAll(",\"allocs\":");
				try out.interface.print("{d}", .{profile.allocs});
				try out.interface.writeAll(",\"frees\":");
				try out.interface.print("{d}", .{profile.frees});
				try out.interface.writeAll(",\"resizes\":");
				try out.interface.print("{d}", .{profile.resizes});
				try out.interface.writeAll(",\"remaps\":");
				try out.interface.print("{d}", .{profile.remaps});
				try out.interface.writeAll(",\"avg_allocated_per_iter\":");
				try out.interface.print("{d:.4}", .{profile.avg_allocated_per_iter});
				try out.interface.writeAll("}");
			}
			try out.interface.writeAll("]");
		}
		if (micro_result) |micro| {
			try out.interface.writeAll(",\"microbench\":{");
			try out.interface.writeAll("\"cols\":");
			try out.interface.print("{d}", .{micro.cols});
			try out.interface.writeAll(",\"iters\":");
			try out.interface.print("{d}", .{micro.iters});
			try out.interface.writeAll(",\"simd_bytes\":");
			try out.interface.print("{d}", .{core.octmat.simdBytes()});
			try out.interface.writeAll(",\"addRow_mbps\":");
			try out.interface.print("{d:.4}", .{micro.add_mbps});
			try out.interface.writeAll(",\"axpy_b1_mbps\":");
			try out.interface.print("{d:.4}", .{micro.axpy_b1_mbps});
			try out.interface.writeAll(",\"axpy_b2_mbps\":");
			try out.interface.print("{d:.4}", .{micro.axpy_b2_mbps});
			try out.interface.writeAll(",\"scal_b2_mbps\":");
			try out.interface.print("{d:.4}", .{micro.scal_b2_mbps});
			try out.interface.writeAll("}");
		}
		try out.interface.writeAll(",\"rows\":[");
		for (rows, 0..) |row, idx| {
			if (idx != 0) try out.interface.writeAll(",");
			try out.interface.writeAll("{\"");
			try out.interface.writeAll(label);
			try out.interface.writeAll("\":");
			if (mode == .ber) {
				try out.interface.print("{e:.6}", .{row.noise_pct});
			} else {
				try out.interface.print("{d:.6}", .{row.noise_pct});
			}
			try out.interface.writeAll(",\"trials\":");
			try out.interface.print("{d}", .{row.trials});
			try out.interface.writeAll(",\"successes\":");
			try out.interface.print("{d}", .{row.successes});
			try out.interface.writeAll(",\"success_rate\":");
			try out.interface.print("{d:.6}", .{row.success_rate});
			try out.interface.writeAll(",\"avg_encode_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_encode_mbps});
			try out.interface.writeAll(",\"avg_decode_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_decode_mbps});
			try out.interface.writeAll(",\"avg_total_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_total_mbps});
			try out.interface.writeAll("}");
		}
		try out.interface.writeAll("]}\n");
	}
	try out.interface.flush();
}

fn runMemProfile(
	allocator: std.mem.Allocator,
	input: []const u8,
	params: nanorq.EncodeParams,
	redundancy: nanorq.Redundancy,
	noise: nanorq.NoiseParams,
	noise_value: f64,
	iterations: usize,
	warmup: usize,
) !MemProfile {
	const counting = core.counting_allocator;
	var counter = counting.CountingAllocator.init(allocator);
	const tracked = counter.allocator();

	var i: usize = 0;
	while (i < warmup) : (i += 1) {
		_ = try nanorq.simulate(tracked, input, params, redundancy, noise, 1);
	}
	const baseline = counter.snapshot();

	i = 0;
	while (i < iterations) : (i += 1) {
		_ = try nanorq.simulate(tracked, input, params, redundancy, noise, 1);
	}
	const final = counter.snapshot();

	const delta_current = @as(i64, @intCast(final.current)) - @as(i64, @intCast(baseline.current));
	const delta_peak = @as(i64, @intCast(final.peak)) - @as(i64, @intCast(baseline.peak));
	const delta_allocated = final.total_allocated - baseline.total_allocated;
	const delta_freed = final.total_freed - baseline.total_freed;
	const avg_allocated_per_iter = if (iterations > 0)
		@as(f64, @floatFromInt(delta_allocated)) / @as(f64, @floatFromInt(iterations))
	else
		0.0;

	return MemProfile{
		.noise_pct = noise_value,
		.iterations = iterations,
		.warmup = warmup,
		.baseline_current = baseline.current,
		.baseline_peak = baseline.peak,
		.end_current = final.current,
		.end_peak = final.peak,
		.delta_current = delta_current,
		.delta_peak = delta_peak,
		.delta_allocated = delta_allocated,
		.delta_freed = delta_freed,
		.allocs = final.allocs - baseline.allocs,
		.frees = final.frees - baseline.frees,
		.resizes = final.resizes - baseline.resizes,
		.remaps = final.remaps - baseline.remaps,
		.avg_allocated_per_iter = avg_allocated_per_iter,
	};
}

fn benchOp(comptime op: fn (*core.octmat.Mat) void, mat: *core.octmat.Mat, iters: usize, bytes_per_iter: usize) f64 {
	const start = nsNow();
	var i: usize = 0;
	while (i < iters) : (i += 1) {
		op(mat);
	}
	const elapsed = nsNow() - start;
	const elapsed_s = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;
	const mb = @as(f64, @floatFromInt(bytes_per_iter * iters)) / (1024.0 * 1024.0);
	return mb / elapsed_s;
}

fn opAdd(mat: *core.octmat.Mat) void {
	mat.addRow(0, 1);
}

fn opAxpyB1(mat: *core.octmat.Mat) void {
	mat.axpy(0, 1, 1);
}

fn opAxpyB2(mat: *core.octmat.Mat) void {
	mat.axpy(0, 1, 2);
}

fn opScalB2(mat: *core.octmat.Mat) void {
	mat.scalRow(0, 2);
}

fn runMicroBench(allocator: std.mem.Allocator, cols: usize, iters: usize) !MicroResult {
	var mat = try core.octmat.Mat.init(allocator, 2, cols);
	defer mat.deinit(allocator);

	var prng = std.Random.DefaultPrng.init(123456);
	var rng = prng.random();
	for (mat.data) |*b| b.* = rng.int(u8);

	const add_mbps = benchOp(opAdd, &mat, iters, cols);
	const axpy_b1_mbps = benchOp(opAxpyB1, &mat, iters, cols);
	const axpy_b2_mbps = benchOp(opAxpyB2, &mat, iters, cols);
	const scal_b2_mbps = benchOp(opScalB2, &mat, iters, cols);

	return MicroResult{
		.cols = cols,
		.iters = iters,
		.add_mbps = add_mbps,
		.axpy_b1_mbps = axpy_b1_mbps,
		.axpy_b2_mbps = axpy_b2_mbps,
		.scal_b2_mbps = scal_b2_mbps,
	};
}

fn findZeroRow(rows: []const Row) ?Row {
	for (rows) |row| {
		if (row.noise_pct == 0.0) return row;
	}
	return null;
}

fn shapeName(shape: nanorq.NoiseShape) []const u8 {
	return switch (shape) {
		.random => "random",
		.clustered => "clustered",
		.normalized => "normalized",
	};
}

fn fillRandom(buf: []u8, seed: u64) void {
	var prng = std.Random.DefaultPrng.init(seed);
	var rng = prng.random();
	for (buf) |*b| b.* = rng.int(u8);
}

fn defaultNoisePcts(allocator: std.mem.Allocator) ![]f64 {
	var list = std.ArrayList(f64).empty;
	errdefer list.deinit(allocator);
	try list.appendSlice(allocator, &[_]f64{ 0.0, 1.0, 2.5, 5.0, 10.0 });
	return list.toOwnedSlice(allocator);
}

fn parsePctList(allocator: std.mem.Allocator, text: []const u8) ![]f64 {
	var list = std.ArrayList(f64).empty;
	errdefer list.deinit(allocator);
	var it = std.mem.splitScalar(u8, text, ',');
	while (it.next()) |part| {
		if (part.len == 0) continue;
		const value = try std.fmt.parseFloat(f64, part);
		try list.append(allocator, value);
	}
	return list.toOwnedSlice(allocator);
}

fn singleValueList(allocator: std.mem.Allocator, value: f64) ![]f64 {
	var list = std.ArrayList(f64).empty;
	errdefer list.deinit(allocator);
	try list.append(allocator, value);
	return list.toOwnedSlice(allocator);
}

const parseFormats = arg_parse.parseFormats;
const parseShape = arg_parse.parseShape;
const parseU16 = arg_parse.parseU16;
const parseU8 = arg_parse.parseU8;
const parseU32 = arg_parse.parseU32;
const parseU64 = arg_parse.parseU64;
const parseUsize = arg_parse.parseUsize;
const parseF64 = arg_parse.parseF64;

fn printUsage(io: std.Io) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	try out.interface.print("nanorq-bench [options]\n", .{});
	try out.interface.print("  --input-size <bytes>\n", .{});
	try out.interface.print("  --symbol-size <bytes>\n", .{});
	try out.interface.print("  --align <bytes>\n", .{});
	try out.interface.print("  --overhead-pct <float>\n", .{});
	try out.interface.print("  --repair-count <n>\n", .{});
	try out.interface.print("  --drop-pct <float>\n", .{});
	try out.interface.print("  --crc | --no-crc\n", .{});
	try out.interface.print("  --noise-pcts <a,b,c>\n", .{});
	try out.interface.print("  --ber <rate>\n", .{});
	try out.interface.print("  --ber-list <a,b,c>\n", .{});
	try out.interface.print("  --shape <random|clustered|normalized>\n", .{});
	try out.interface.print("  --include-tags\n", .{});
	try out.interface.print("  --cluster-size <n>\n", .{});
	try out.interface.print("  --cluster-count <n>\n", .{});
	try out.interface.print("  --center <index>\n", .{});
	try out.interface.print("  --sigma <float>\n", .{});
	try out.interface.print("  --seed <n>\n", .{});
	try out.interface.print("  --trials <n>\n", .{});
	try out.interface.print("  --format <text|csv|json|all>\n", .{});
	try out.interface.print("  --mem-profile\n", .{});
	try out.interface.print("  --mem-iterations <n>\n", .{});
	try out.interface.print("  --mem-warmup <n>\n", .{});
	try out.interface.print("  --micro\n", .{});
	try out.interface.print("  --micro-iters <n>\n", .{});
	try out.interface.print("  --micro-cols <n>\n", .{});
	try out.interface.flush();
}
