const std = @import("std");
const nanorq = @import("nanorq.zig");

const Formats = struct {
	text: bool,
	csv: bool,
	json: bool,
};

const Row = struct {
	noise_pct: f64,
	trials: usize,
	successes: usize,
	success_rate: f64,
	avg_encode_mbps: f64,
	avg_decode_mbps: f64,
	avg_total_mbps: f64,
};

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);

	if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
		try printUsage();
		return;
	}

	var input_size: usize = 1 * 1024 * 1024;
	var params = nanorq.EncodeParams{ .symbol_size = 1280, .alignment = 8, .crc = true };
	var redundancy = nanorq.Redundancy{};
	var noise = nanorq.NoiseParams{ .pct = 0.0, .shape = .random };
	var trials: usize = 5;
	var formats = Formats{ .text = true, .csv = true, .json = true };
	var noise_pcts = try defaultNoisePcts(allocator);
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
		} else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			try printUsage();
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

	for (noise_pcts) |pct| {
		var local_noise = noise;
		local_noise.pct = pct;
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

	try printReport(rows.items, formats, noise.shape);
}

fn printReport(rows: []const Row, formats: Formats, shape: nanorq.NoiseShape) !void {
	var buf: [4096]u8 = undefined;
	var out = std.fs.File.stdout().writer(&buf);
	if (formats.text) {
		if (findZeroRow(rows)) |row| {
			try out.interface.print("raw throughput (noise_pct=0)\n", .{});
			try out.interface.print("encode_mbps={d:.2} decode_mbps={d:.2} total_mbps={d:.2}\n\n", .{ row.avg_encode_mbps, row.avg_decode_mbps, row.avg_total_mbps });
		}
		try out.interface.print("resilience report (shape={s})\n", .{shapeName(shape)});
		for (rows) |row| {
			try out.interface.print("noise_pct={d:.2} success_rate={d:.4} encode_mbps={d:.2} decode_mbps={d:.2} total_mbps={d:.2}\n", .{ row.noise_pct, row.success_rate, row.avg_encode_mbps, row.avg_decode_mbps, row.avg_total_mbps });
		}
	}
	if (formats.csv) {
		try out.interface.print("noise_pct,shape,trials,successes,success_rate,avg_encode_mbps,avg_decode_mbps,avg_total_mbps\n", .{});
		for (rows) |row| {
			try out.interface.print("{d:.4},{s},{d},{d},{d:.6},{d:.4},{d:.4},{d:.4}\n", .{ row.noise_pct, shapeName(shape), row.trials, row.successes, row.success_rate, row.avg_encode_mbps, row.avg_decode_mbps, row.avg_total_mbps });
		}
	}
	if (formats.json) {
		try out.interface.writeAll("{\"shape\":\"");
		try out.interface.print("{s}", .{shapeName(shape)});
		try out.interface.writeAll("\",");
		if (findZeroRow(rows)) |row| {
			try out.interface.writeAll("\"raw_throughput\":{");
			try out.interface.writeAll("\"avg_encode_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_encode_mbps});
			try out.interface.writeAll(",\"avg_decode_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_decode_mbps});
			try out.interface.writeAll(",\"avg_total_mbps\":");
			try out.interface.print("{d:.4}", .{row.avg_total_mbps});
			try out.interface.writeAll("},");
		}
		try out.interface.writeAll("\"rows\":[");
		for (rows, 0..) |row, idx| {
			if (idx != 0) try out.interface.writeAll(",");
			try out.interface.writeAll("{\"noise_pct\":");
			try out.interface.print("{d:.6}", .{row.noise_pct});
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

fn parseFormats(args: []const []const u8, idx: usize) !Formats {
	const value = args[idx];
	if (std.mem.eql(u8, value, "all")) {
		return Formats{ .text = true, .csv = true, .json = true };
	}
	if (std.mem.eql(u8, value, "text")) {
		return Formats{ .text = true, .csv = false, .json = false };
	}
	if (std.mem.eql(u8, value, "csv")) {
		return Formats{ .text = false, .csv = true, .json = false };
	}
	if (std.mem.eql(u8, value, "json")) {
		return Formats{ .text = false, .csv = false, .json = true };
	}
	return error.InvalidFormat;
}

fn parseShape(args: []const []const u8, idx: usize) !nanorq.NoiseShape {
	const value = args[idx];
	if (std.mem.eql(u8, value, "random")) return .random;
	if (std.mem.eql(u8, value, "clustered")) return .clustered;
	if (std.mem.eql(u8, value, "normalized")) return .normalized;
	return error.InvalidNoiseShape;
}

fn parseU16(args: []const []const u8, idx: usize) !u16 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(u16, args[idx], 10);
}

fn parseU8(args: []const []const u8, idx: usize) !u8 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(u8, args[idx], 10);
}

fn parseU32(args: []const []const u8, idx: usize) !u32 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(u32, args[idx], 10);
}

fn parseU64(args: []const []const u8, idx: usize) !u64 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(u64, args[idx], 10);
}

fn parseUsize(args: []const []const u8, idx: usize) !usize {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(usize, args[idx], 10);
}

fn parseF64(args: []const []const u8, idx: usize) !f64 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseFloat(f64, args[idx]);
}

fn printUsage() !void {
	var buf: [4096]u8 = undefined;
	var out = std.fs.File.stdout().writer(&buf);
	try out.interface.print("nanorq-bench [options]\n", .{});
	try out.interface.print("  --input-size <bytes>\n", .{});
	try out.interface.print("  --symbol-size <bytes>\n", .{});
	try out.interface.print("  --align <bytes>\n", .{});
	try out.interface.print("  --overhead-pct <float>\n", .{});
	try out.interface.print("  --repair-count <n>\n", .{});
	try out.interface.print("  --drop-pct <float>\n", .{});
	try out.interface.print("  --crc | --no-crc\n", .{});
	try out.interface.print("  --noise-pcts <a,b,c>\n", .{});
	try out.interface.print("  --shape <random|clustered|normalized>\n", .{});
	try out.interface.print("  --include-tags\n", .{});
	try out.interface.print("  --cluster-size <n>\n", .{});
	try out.interface.print("  --cluster-count <n>\n", .{});
	try out.interface.print("  --center <index>\n", .{});
	try out.interface.print("  --sigma <float>\n", .{});
	try out.interface.print("  --seed <n>\n", .{});
	try out.interface.print("  --trials <n>\n", .{});
	try out.interface.print("  --format <text|csv|json|all>\n", .{});
	try out.interface.flush();
}
