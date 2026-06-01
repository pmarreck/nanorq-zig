//! Shared CLI argument-parsing helpers used by both the `nanorq` CLI
//! (src/cli.zig) and the benchmark/report tool (src/bench.zig). These
//! evolved as byte-identical copies in both files; centralizing them here
//! keeps the two front-ends in sync.

const std = @import("std");
const nanorq = @import("nanorq.zig");

pub const Formats = struct {
	text: bool,
	csv: bool,
	json: bool,
};

pub fn parseFormats(args: []const []const u8, idx: usize) !Formats {
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

pub fn parseShape(args: []const []const u8, idx: usize) !nanorq.NoiseShape {
	const value = args[idx];
	if (std.mem.eql(u8, value, "random")) return .random;
	if (std.mem.eql(u8, value, "clustered")) return .clustered;
	if (std.mem.eql(u8, value, "normalized")) return .normalized;
	return error.InvalidNoiseShape;
}

pub fn parseU16(args: []const []const u8, idx: usize) !u16 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(u16, args[idx], 10);
}

pub fn parseU8(args: []const []const u8, idx: usize) !u8 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(u8, args[idx], 10);
}

pub fn parseU32(args: []const []const u8, idx: usize) !u32 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(u32, args[idx], 10);
}

pub fn parseU64(args: []const []const u8, idx: usize) !u64 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(u64, args[idx], 10);
}

pub fn parseUsize(args: []const []const u8, idx: usize) !usize {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseInt(usize, args[idx], 10);
}

pub fn parseF64(args: []const []const u8, idx: usize) !f64 {
	if (idx >= args.len) return error.MissingValue;
	return std.fmt.parseFloat(f64, args[idx]);
}
