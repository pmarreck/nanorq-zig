const std = @import("std");
const nanorq = @import("nanorq.zig");
const arg_parse = @import("arg_parse.zig");

pub fn main(init: std.process.Init) !void {
	const allocator = init.gpa;
	const io = init.io;

	const args0 = try init.minimal.args.toSlice(init.arena.allocator());
	// Convert [:0]const u8 to []const u8 once for downstream consumers.
	const args = try init.arena.allocator().alloc([]const u8, args0.len);
	for (args0, 0..) |a, idx| args[idx] = a;

	if (args.len < 2) {
		try printUsage(io);
		return;
	}

	const cmd = args[1];
	if (std.mem.eql(u8, cmd, "encode")) {
		try cmdEncode(io, allocator, args[2..]);
	} else if (std.mem.eql(u8, cmd, "decode")) {
		try cmdDecode(io, allocator, args[2..]);
	} else if (std.mem.eql(u8, cmd, "noise")) {
		try cmdNoise(io, allocator, args[2..]);
	} else if (std.mem.eql(u8, cmd, "simulate")) {
		try cmdSimulate(io, allocator, args[2..]);
	} else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
		try printUsage(io);
	} else {
		try printUsage(io);
		return error.UnknownCommand;
	}
}

fn cmdEncode(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
	var params = nanorq.EncodeParams{ .symbol_size = 1280, .alignment = 8, .crc = true };
	var redundancy = nanorq.Redundancy{};
	var precalc = false;

	var i: usize = 0;
	while (i < args.len) : (i += 1) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--symbol-size")) {
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
		} else if (std.mem.eql(u8, arg, "--source-symbols")) {
			i += 1;
			params.source_symbols = try parseU16(args, i);
		} else if (std.mem.eql(u8, arg, "--blocks")) {
			i += 1;
			params.blocks = try parseU16(args, i);
		} else if (std.mem.eql(u8, arg, "--precalculate")) {
			precalc = true;
		} else if (std.mem.eql(u8, arg, "--crc")) {
			params.crc = true;
		} else if (std.mem.eql(u8, arg, "--no-crc")) {
			params.crc = false;
		} else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			try printEncodeUsage(io);
			return;
		} else {
			return error.UnknownOption;
		}
	}

	params.precalculate = precalc;
	const input = try readAllStdin(io, allocator);
	defer allocator.free(input);

	const encoded = try nanorq.encode(allocator, input, params, redundancy);
	defer allocator.free(encoded);

	try writeAllStdout(io, encoded);
}

fn cmdDecode(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
	if (args.len != 0 and !(args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")))) return error.UnknownOption;
	if (args.len == 1) {
		try printDecodeUsage(io);
		return;
	}

	const input = try readAllStdin(io, allocator);
	defer allocator.free(input);

	const decoded = try nanorq.decode(allocator, input);
	defer allocator.free(decoded.data);

	try writeAllStdout(io, decoded.data);
}

fn cmdNoise(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
	var params = nanorq.NoiseParams{ .pct = 0.0, .shape = .random };

	var i: usize = 0;
	while (i < args.len) : (i += 1) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--pct")) {
			i += 1;
			params.pct = try parseF64(args, i);
		} else if (std.mem.eql(u8, arg, "--shape")) {
			i += 1;
			params.shape = try parseShape(args, i);
		} else if (std.mem.eql(u8, arg, "--ber")) {
			i += 1;
			params.ber = try parseF64(args, i);
			params.pct = 0.0;
		} else if (std.mem.eql(u8, arg, "--cluster-size")) {
			i += 1;
			params.cluster_size = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--cluster-count")) {
			i += 1;
			params.cluster_count = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--center")) {
			i += 1;
			params.center = try parseUsize(args, i);
		} else if (std.mem.eql(u8, arg, "--sigma")) {
			i += 1;
			params.sigma = try parseF64(args, i);
		} else if (std.mem.eql(u8, arg, "--seed")) {
			i += 1;
			params.seed = try parseU64(args, i);
		} else if (std.mem.eql(u8, arg, "--include-header")) {
			params.include_header = true;
		} else if (std.mem.eql(u8, arg, "--include-tags")) {
			params.symbol_bytes_only = false;
		} else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			try printNoiseUsage(io);
			return;
		} else {
			return error.UnknownOption;
		}
	}

	const input = try readAllStdin(io, allocator);
	defer allocator.free(input);

	if (params.ber) |ber| {
		const result = try nanorq.applyBerErasures(allocator, input, ber, params.seed);
		defer allocator.free(result);
		try writeAllStdout(io, result);
		return;
	}

	const result = try nanorq.applyNoise(allocator, input, params);
	defer allocator.free(result.data);

	try writeAllStdout(io, result.data);
}

fn cmdSimulate(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
	var params = nanorq.EncodeParams{ .symbol_size = 1280, .alignment = 8, .crc = true };
	var redundancy = nanorq.Redundancy{};
	var noise = nanorq.NoiseParams{ .pct = 0.0, .shape = .random };
	var trials: usize = 10;
	var formats = Formats{ .text = true, .csv = false, .json = false };

	var i: usize = 0;
	while (i < args.len) : (i += 1) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--symbol-size")) {
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
		} else if (std.mem.eql(u8, arg, "--source-symbols")) {
			i += 1;
			params.source_symbols = try parseU16(args, i);
		} else if (std.mem.eql(u8, arg, "--blocks")) {
			i += 1;
			params.blocks = try parseU16(args, i);
		} else if (std.mem.eql(u8, arg, "--precalculate")) {
			params.precalculate = true;
		} else if (std.mem.eql(u8, arg, "--crc")) {
			params.crc = true;
		} else if (std.mem.eql(u8, arg, "--no-crc")) {
			params.crc = false;
		} else if (std.mem.eql(u8, arg, "--noise-pct")) {
			i += 1;
			noise.pct = try parseF64(args, i);
		} else if (std.mem.eql(u8, arg, "--ber")) {
			i += 1;
			noise.ber = try parseF64(args, i);
			noise.pct = 0.0;
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
			try printSimulateUsage(io);
			return;
		} else {
			return error.UnknownOption;
		}
	}

	const input = try readAllStdin(io, allocator);
	defer allocator.free(input);

	const result = try nanorq.simulate(allocator, input, params, redundancy, noise, trials);
	try printSimResult(io, result, formats);
}

const Formats = arg_parse.Formats;
const parseFormats = arg_parse.parseFormats;

fn printSimResult(io: std.Io, result: nanorq.SimResult, formats: Formats) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	if (formats.text) {
		try out.interface.print("trials: {d}\n", .{result.trials});
		try out.interface.print("successes: {d}\n", .{result.successes});
		try out.interface.print("success_rate: {d:.4}\n", .{result.success_rate});
		try out.interface.print("avg_encode_mbps: {d:.2}\n", .{result.avg_encode_mbps});
		try out.interface.print("avg_decode_mbps: {d:.2}\n", .{result.avg_decode_mbps});
		try out.interface.print("avg_total_mbps: {d:.2}\n", .{result.avg_total_mbps});
	}
	if (formats.csv) {
		try out.interface.print("trials,successes,success_rate,avg_encode_mbps,avg_decode_mbps,avg_total_mbps\n", .{});
		try out.interface.print("{d},{d},{d:.6},{d:.4},{d:.4},{d:.4}\n", .{ result.trials, result.successes, result.success_rate, result.avg_encode_mbps, result.avg_decode_mbps, result.avg_total_mbps });
	}
	if (formats.json) {
		try out.interface.writeAll("{\"trials\":");
		try out.interface.print("{d}", .{result.trials});
		try out.interface.writeAll(",\"successes\":");
		try out.interface.print("{d}", .{result.successes});
		try out.interface.writeAll(",\"success_rate\":");
		try out.interface.print("{d:.6}", .{result.success_rate});
		try out.interface.writeAll(",\"avg_encode_mbps\":");
		try out.interface.print("{d:.4}", .{result.avg_encode_mbps});
		try out.interface.writeAll(",\"avg_decode_mbps\":");
		try out.interface.print("{d:.4}", .{result.avg_decode_mbps});
		try out.interface.writeAll(",\"avg_total_mbps\":");
		try out.interface.print("{d:.4}", .{result.avg_total_mbps});
		try out.interface.writeAll("}\n");
	}
	try out.interface.flush();
}

const parseShape = arg_parse.parseShape;
const parseU16 = arg_parse.parseU16;
const parseU8 = arg_parse.parseU8;
const parseU32 = arg_parse.parseU32;
const parseU64 = arg_parse.parseU64;
const parseUsize = arg_parse.parseUsize;
const parseF64 = arg_parse.parseF64;

fn readAllStdin(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
	var scratch: [4096]u8 = undefined;
	var r = std.Io.File.stdin().reader(io, &scratch);
	return r.interface.allocRemaining(allocator, .limited(1 << 30));
}

fn writeAllStdout(io: std.Io, data: []const u8) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	try out.interface.writeAll(data);
	try out.interface.flush();
}

fn printUsage(io: std.Io) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	try out.interface.print("nanorq <command> [options]\n\n", .{});
	try out.interface.print("Commands:\n", .{});
	try out.interface.print("  encode\tEncode stdin to nanorq stream\n", .{});
	try out.interface.print("  decode\tDecode nanorq stream to stdout\n", .{});
	try out.interface.print("  noise\tApply noise to stdin bytes\n", .{});
	try out.interface.print("  simulate\tEmpirical recovery simulation\n\n", .{});
	try out.interface.print("Run: nanorq <command> --help\n", .{});
	try out.interface.flush();
}

fn printEncodeUsage(io: std.Io) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	try out.interface.print("nanorq encode [options]\n", .{});
	try out.interface.print("  --symbol-size <bytes>\n", .{});
	try out.interface.print("  --align <bytes>\n", .{});
	try out.interface.print("  --overhead-pct <float>\n", .{});
	try out.interface.print("  --repair-count <n>\n", .{});
	try out.interface.print("  --source-symbols <n>\n", .{});
	try out.interface.print("  --blocks <n>\n", .{});
	try out.interface.print("  --precalculate\n", .{});
	try out.interface.print("  --crc | --no-crc\n", .{});
	try out.interface.flush();
}

fn printDecodeUsage(io: std.Io) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	try out.interface.print("nanorq decode\n", .{});
	try out.interface.flush();
}

fn printNoiseUsage(io: std.Io) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	try out.interface.print("nanorq noise [options]\n", .{});
	try out.interface.print("  --pct <float>\n", .{});
	try out.interface.print("  --shape <random|clustered|normalized>\n", .{});
	try out.interface.print("  --ber <rate>\n", .{});
	try out.interface.print("  --cluster-size <n>\n", .{});
	try out.interface.print("  --cluster-count <n>\n", .{});
	try out.interface.print("  --center <index>\n", .{});
	try out.interface.print("  --sigma <float>\n", .{});
	try out.interface.print("  --seed <n>\n", .{});
	try out.interface.print("  --include-header\n", .{});
	try out.interface.print("  --include-tags\n", .{});
	try out.interface.flush();
}

fn printSimulateUsage(io: std.Io) !void {
	var buf: [4096]u8 = undefined;
	var out = std.Io.File.stdout().writer(io, &buf);
	try out.interface.print("nanorq simulate [options]\n", .{});
	try out.interface.print("  --symbol-size <bytes>\n", .{});
	try out.interface.print("  --align <bytes>\n", .{});
	try out.interface.print("  --overhead-pct <float>\n", .{});
	try out.interface.print("  --repair-count <n>\n", .{});
	try out.interface.print("  --drop-pct <float>\n", .{});
	try out.interface.print("  --source-symbols <n>\n", .{});
	try out.interface.print("  --blocks <n>\n", .{});
	try out.interface.print("  --precalculate\n", .{});
	try out.interface.print("  --crc | --no-crc\n", .{});
	try out.interface.print("  --noise-pct <float>\n", .{});
	try out.interface.print("  --ber <rate>\n", .{});
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
