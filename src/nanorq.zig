const std = @import("std");
const core = @import("core/nanorq_core.zig");

// 0.16: std.time.nanoTimestamp() is gone. Use Io.Timestamp via the
// single-threaded global Io (timestamp ops work fine from any thread; this
// avoids plumbing `io: std.Io` through the pure-library public API).
inline fn nsNow() i128 {
	const io = std.Io.Threaded.global_single_threaded.io();
	return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

pub const EncodeParams = struct {
	symbol_size: u16,
	alignment: u8 = 8,
	source_symbols: ?u16 = null,
	blocks: ?u16 = null,
	precalculate: bool = false,
	crc: bool = false,
};

pub const Redundancy = struct {
	overhead_pct: ?f64 = null,
	repair_symbols: ?u32 = null,
	drop_pct: ?f64 = null,
};

pub const NoiseShape = enum {
	random,
	clustered,
	normalized,
};

pub const NoiseParams = struct {
	pct: f64,
	shape: NoiseShape,
	ber: ?f64 = null,
	cluster_size: usize = 64,
	cluster_count: ?usize = null,
	center: ?usize = null,
	sigma: ?f64 = null,
	seed: u64 = 1,
	include_header: bool = false,
	symbol_bytes_only: bool = true,
};

pub const NoiseResult = struct {
	data: []u8,
	changed_count: usize,
	mean_index: f64,
};

const NoisePlan = struct {
	offsets: []usize,
	mean_index: f64,
};

pub const DecodeStats = struct {
	blocks: usize,
	missing: usize,
	repair: usize,
};

pub const DecodeResult = struct {
	data: []u8,
	stats: DecodeStats,
};

pub const SimResult = struct {
	trials: usize,
	successes: usize,
	success_rate: f64,
	avg_encode_mbps: f64,
	avg_decode_mbps: f64,
	avg_total_mbps: f64,
};

const header_magic = "NRQ1";
const header_version: u8 = 1;
const header_size = 24;
const flag_crc32: u8 = 0x01;

const Header = struct {
	version: u8,
	flags: u8,
	oti_common: u64,
	oti_scheme: u32,
	symbol_size: u32,
};

pub fn encode(allocator: std.mem.Allocator, input: []const u8, params: EncodeParams, redundancy: Redundancy) ![]u8 {
	if (params.symbol_size == 0) return error.InvalidSymbolSize;
	if (input.len > core.max_transfer) return error.InputTooLarge;

	var rq = try encoderNew(allocator, input.len, params);
	defer rq.deinit(allocator);

	if (params.precalculate) try rq.precalculate(allocator);

	const blocks = rq.blocks();
	const symbol_size = rq.common.T;
	const record_overhead: usize = if (params.crc) 8 else 4;

	var total_symbols: usize = 0;
	for (0..blocks) |sbn| {
		const k = rq.blockSymbols(sbn);
		total_symbols += k + computeRepair(k, redundancy);
	}

	var out = std.ArrayList(u8).empty;
	errdefer out.deinit(allocator);
	try out.ensureTotalCapacity(allocator, header_size + total_symbols * (record_overhead + symbol_size));
	try writeHeader(&out, allocator, &rq, if (params.crc) flag_crc32 else 0);

	const symbol_buf = try allocator.alloc(u8, symbol_size);
	defer allocator.free(symbol_buf);

	for (0..blocks) |sbn_usize| {
		const sbn = sbn_usize;
		const k = rq.blockSymbols(sbn);
		const repair = computeRepair(k, redundancy);

		for (0..k) |esi_usize| {
			const esi = @as(u32, @intCast(esi_usize));
			const written = try core.encodeSymbol(&rq, allocator, sbn, esi, input, symbol_buf);
			if (written != symbol_size) return error.EncodeFailed;

			const tag = core.tag(@intCast(sbn), esi);
			try appendU32(&out, allocator, tag);
			if (params.crc) {
				const crc = std.hash.Crc32.hash(symbol_buf);
				try appendU32(&out, allocator, crc);
			}
			try out.appendSlice(allocator, symbol_buf);
		}

		if (repair > 0) {
			try core.generateSymbols(&rq, allocator, sbn, input);
			for (k..k + repair) |esi_usize| {
				const esi = @as(u32, @intCast(esi_usize));
				const written = try core.encodeSymbol(&rq, allocator, sbn, esi, input, symbol_buf);
				if (written != symbol_size) return error.EncodeFailed;

				const tag = core.tag(@intCast(sbn), esi);
				try appendU32(&out, allocator, tag);
				if (params.crc) {
					const crc = std.hash.Crc32.hash(symbol_buf);
					try appendU32(&out, allocator, crc);
				}
				try out.appendSlice(allocator, symbol_buf);
			}
		}
	}

	return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) !DecodeResult {
	const header = try parseHeader(encoded);
	var rq = try core.decoderNew(allocator, header.oti_common, header.oti_scheme);
	defer rq.deinit(allocator);

	const symbol_size = rq.common.T;
	if (header.symbol_size != 0 and header.symbol_size != symbol_size) return error.SymbolSizeMismatch;

	const transfer_len = rq.common.F;
	const output = try allocator.alloc(u8, transfer_len);
	errdefer allocator.free(output);
	@memset(output, 0);

	const offset_start: usize = header_size;
	const has_crc = (header.flags & flag_crc32) != 0;
	const record_overhead: usize = if (has_crc) 8 else 4;
	if (encoded.len < offset_start) return error.TruncatedInput;

	var offset: usize = offset_start;
	while (offset + record_overhead + symbol_size <= encoded.len) {
		const tag = readU32(encoded[offset .. offset + 4]);
		offset += 4;
		var expected_crc: ?u32 = null;
		if (has_crc) {
			expected_crc = readU32(encoded[offset .. offset + 4]);
			offset += 4;
		}
		const symbol = encoded[offset .. offset + symbol_size];
		offset += symbol_size;
		if (has_crc) {
			const actual_crc = std.hash.Crc32.hash(symbol);
			if (actual_crc != expected_crc.?) continue;
		}
		const rc = try core.decoderAddSymbol(&rq, allocator, symbol, tag, output);
		if (rc == .err) return error.DecodeAddSymbolFailed;
	}

	const blocks = rq.blocks();
	var stats = DecodeStats{ .blocks = blocks, .missing = 0, .repair = 0 };
	for (0..blocks) |sbn_usize| {
		const sbn = sbn_usize;
		stats.missing += try core.numMissing(&rq, allocator, sbn);
		stats.repair += try core.numRepair(&rq, allocator, sbn);
		if (!try core.repairBlock(&rq, allocator, sbn, output)) return error.RepairFailed;
	}

	return DecodeResult{ .data = output, .stats = stats };
}

pub fn applyNoise(allocator: std.mem.Allocator, data: []const u8, params: NoiseParams) !NoiseResult {
	if (params.ber != null) return error.InvalidNoiseParams;
	if (params.pct < 0.0) return error.InvalidNoisePct;
	if (params.pct == 0.0) {
		return NoiseResult{ .data = try allocator.dupe(u8, data), .changed_count = 0, .mean_index = 0.0 };
	}

	const out = try allocator.dupe(u8, data);
	const plan = try computeNoisePlan(allocator, out, params);
	defer allocator.free(plan.offsets);

	var prng = std.Random.DefaultPrng.init(params.seed);
	var rng = prng.random();

	for (plan.offsets) |offset| {
		applyByteNoise(out, offset, &rng);
	}

	return NoiseResult{ .data = out, .changed_count = plan.offsets.len, .mean_index = plan.mean_index };
}

pub fn simulate(allocator: std.mem.Allocator, input: []const u8, params: EncodeParams, redundancy: Redundancy, noise: NoiseParams, trials: usize) !SimResult {
	if (trials == 0) return error.InvalidTrials;

	var successes: usize = 0;
	var encode_time_ns: u64 = 0;
	var decode_time_ns: u64 = 0;

	var trial: usize = 0;
	while (trial < trials) : (trial += 1) {
		const encoded = try timeEncode(allocator, input, params, redundancy, &encode_time_ns);
		defer allocator.free(encoded);

		var noise_params = noise;
		noise_params.seed = noise.seed + @as(u64, @intCast(trial));

		var noisy_data = blk: {
			if (noise_params.ber) |ber| {
				const dropped = try dropSymbolsFromBER(allocator, encoded, ber, noise_params.seed);
				break :blk dropped;
			}
			const noisy = try applyNoise(allocator, encoded, noise_params);
			break :blk noisy.data;
		};
		defer allocator.free(noisy_data);

		if (redundancy.drop_pct) |drop_pct| {
			if (drop_pct > 0.0) {
				const dropped = try dropSymbols(allocator, noisy_data, drop_pct, noise_params.seed ^ 0x9e3779b97f4a7c15);
				allocator.free(noisy_data);
				noisy_data = dropped;
			}
		}

		const decode_start = nsNow();
		const decoded = decode(allocator, noisy_data) catch {
			decode_time_ns += @as(u64, @intCast(nsNow() - decode_start));
			continue;
		};
		decode_time_ns += @as(u64, @intCast(nsNow() - decode_start));
		defer allocator.free(decoded.data);

		if (std.mem.eql(u8, input, decoded.data)) successes += 1;
	}

	const input_mb = @as(f64, @floatFromInt(input.len)) / (1024.0 * 1024.0);
	const encode_secs = @as(f64, @floatFromInt(encode_time_ns)) / 1_000_000_000.0;
	const decode_secs = @as(f64, @floatFromInt(decode_time_ns)) / 1_000_000_000.0;
	const avg_encode_mbps = input_mb * @as(f64, @floatFromInt(trials)) / encode_secs;
	const avg_decode_mbps = input_mb * @as(f64, @floatFromInt(trials)) / decode_secs;
	const avg_total_mbps = input_mb * @as(f64, @floatFromInt(trials)) / (encode_secs + decode_secs);

	return SimResult{
		.trials = trials,
		.successes = successes,
		.success_rate = @as(f64, @floatFromInt(successes)) / @as(f64, @floatFromInt(trials)),
		.avg_encode_mbps = avg_encode_mbps,
		.avg_decode_mbps = avg_decode_mbps,
		.avg_total_mbps = avg_total_mbps,
	};
}

fn timeEncode(allocator: std.mem.Allocator, input: []const u8, params: EncodeParams, redundancy: Redundancy, timer_accum: *u64) ![]u8 {
	const start = nsNow();
	const encoded = try encode(allocator, input, params, redundancy);
	const elapsed = nsNow() - start;
	timer_accum.* += @as(u64, @intCast(elapsed));
	return encoded;
}

fn timeDecode(allocator: std.mem.Allocator, encoded: []const u8, timer_accum: *u64) !DecodeResult {
	const start = nsNow();
	const decoded = try decode(allocator, encoded);
	const elapsed = nsNow() - start;
	timer_accum.* += @as(u64, @intCast(elapsed));
	return decoded;
}

fn dropSymbols(allocator: std.mem.Allocator, encoded: []const u8, drop_pct: f64, seed: u64) ![]u8 {
	if (drop_pct <= 0.0) return allocator.dupe(u8, encoded);

	const header = try parseHeader(encoded);
	const symbol_size = @as(usize, header.symbol_size);
	const has_crc = (header.flags & flag_crc32) != 0;
	const record_size: usize = symbol_size + (if (has_crc) @as(usize, 8) else 4);
	var prng = std.Random.DefaultPrng.init(seed);
	var rng = prng.random();

	var out = std.ArrayList(u8).empty;
	errdefer out.deinit(allocator);
	try out.ensureTotalCapacity(allocator, encoded.len);
	try out.appendSlice(allocator, encoded[0..header_size]);

	var offset: usize = header_size;
	while (offset + record_size <= encoded.len) {
		const take = rng.float(f64) * 100.0 >= drop_pct;
		const record = encoded[offset .. offset + record_size];
		if (take) try out.appendSlice(allocator, record);
		offset += record_size;
	}

	return out.toOwnedSlice(allocator);
}

pub fn symbolDropPctFromBER(ber: f64, symbol_bytes: usize) !f64 {
	if (ber < 0.0 or ber > 1.0) return error.InvalidBer;
	if (ber == 0.0 or symbol_bytes == 0) return 0.0;
	if (ber == 1.0) return 100.0;
	const bits = @as(f64, @floatFromInt(symbol_bytes * 8));
	const keep_prob = std.math.pow(f64, 1.0 - ber, bits);
	const drop_prob = 1.0 - keep_prob;
	return drop_prob * 100.0;
}

fn dropSymbolsFromBER(allocator: std.mem.Allocator, encoded: []const u8, ber: f64, seed: u64) ![]u8 {
	const header = try parseHeader(encoded);
	if (header.symbol_size == 0) return error.InvalidSymbolSize;
	const drop_pct = try symbolDropPctFromBER(ber, header.symbol_size);
	return dropSymbols(allocator, encoded, drop_pct, seed);
}

pub fn applyBerErasures(allocator: std.mem.Allocator, encoded: []const u8, ber: f64, seed: u64) ![]u8 {
	return dropSymbolsFromBER(allocator, encoded, ber, seed);
}

fn encoderNew(allocator: std.mem.Allocator, len: usize, params: EncodeParams) !core.Nanorq {
	if (params.source_symbols != null or params.blocks != null) {
		const k = params.source_symbols orelse 0;
		const z = params.blocks orelse 0;
		return core.encoderNew(allocator, len, params.symbol_size, k, z, params.alignment);
	}
	return core.encoderNew(allocator, len, params.symbol_size, 0, 0, params.alignment);
}

fn computeRepair(k: usize, redundancy: Redundancy) usize {
	var repair: usize = 0;
	if (redundancy.repair_symbols) |count| {
		repair = @max(repair, @as(usize, count));
	}
	if (redundancy.overhead_pct) |pct| {
		const extra = @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(k)) * pct / 100.0)));
		repair = @max(repair, extra);
	}
	return repair;
}

fn writeHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, rq: *core.Nanorq, flags: u8) !void {
	try out.appendSlice(allocator, header_magic);
	try out.append(allocator, header_version);
	try out.append(allocator, flags);
	try out.appendSlice(allocator, &[_]u8{ 0, 0 });
	try appendU64(out, allocator, core.otiCommon(rq));
	try appendU32(out, allocator, core.otiSchemeSpecific(rq));
	try appendU32(out, allocator, @as(u32, @intCast(rq.common.T)));
}

fn parseHeader(encoded: []const u8) !Header {
	if (encoded.len < header_size) return error.TruncatedInput;
	if (!std.mem.eql(u8, encoded[0..4], header_magic)) return error.BadMagic;
	const version = encoded[4];
	if (version != header_version) return error.UnsupportedVersion;
	const flags = encoded[5];
	const oti_common = readU64(encoded[8..16]);
	const oti_scheme = readU32(encoded[16..20]);
	const symbol_size = readU32(encoded[20..24]);
	return Header{
		.version = version,
		.flags = flags,
		.oti_common = oti_common,
		.oti_scheme = oti_scheme,
		.symbol_size = symbol_size,
	};
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
	var buf: [4]u8 = undefined;
	std.mem.writeInt(u32, &buf, value, .little);
	try out.appendSlice(allocator, &buf);
}

fn appendU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
	var buf: [8]u8 = undefined;
	std.mem.writeInt(u64, &buf, value, .little);
	try out.appendSlice(allocator, &buf);
}

fn readU32(bytes: []const u8) u32 {
	return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU64(bytes: []const u8) u64 {
	return std.mem.readInt(u64, bytes[0..8], .little);
}

fn noiseStartOffset(data: []const u8, params: NoiseParams) usize {
	if (params.include_header) return 0;
	if (data.len < header_size) return 0;
	if (!std.mem.eql(u8, data[0..4], header_magic)) return 0;
	return header_size;
}

fn computeNoisePlan(allocator: std.mem.Allocator, data: []const u8, params: NoiseParams) !NoisePlan {
	const start = noiseStartOffset(data, params);
	if (start >= data.len) {
		return NoisePlan{ .offsets = try allocator.alloc(usize, 0), .mean_index = 0.0 };
	}

	var has_layout = false;
	var record_overhead: usize = 4;
	var symbol_size: usize = 0;
	if (!params.include_header and data.len >= header_size and std.mem.eql(u8, data[0..4], header_magic)) {
		const header = parseHeader(data) catch null;
		if (header) |h| {
			has_layout = true;
			symbol_size = @as(usize, h.symbol_size);
			if ((h.flags & flag_crc32) != 0) record_overhead = 8;
		}
	}

	const symbol_only = params.symbol_bytes_only and has_layout and !params.include_header and symbol_size > 0;
	var base_len: usize = 0;
	if (symbol_only) {
		const record_size = record_overhead + symbol_size;
		const payload = data.len - header_size;
		const records = payload / record_size;
		base_len = records * symbol_size;
	} else {
		base_len = data.len - start;
	}

	if (base_len == 0) {
		return NoisePlan{ .offsets = try allocator.alloc(usize, 0), .mean_index = 0.0 };
	}

	var target = @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(base_len)) * params.pct / 100.0)));
	if (target > base_len) target = base_len;
	if (target == 0) {
		return NoisePlan{ .offsets = try allocator.alloc(usize, 0), .mean_index = 0.0 };
	}

	var used = try allocator.alloc(bool, base_len);
	defer allocator.free(used);
	@memset(used, false);

	var offsets = try allocator.alloc(usize, target);
	var prng = std.Random.DefaultPrng.init(params.seed);
	var rng = prng.random();

	var changed: usize = 0;
	var sum_index: u64 = 0;

	const cluster_size = if (params.cluster_size == 0) 1 else params.cluster_size;
	const cluster_count = params.cluster_count orelse @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(target)) / @as(f64, @floatFromInt(cluster_size)))));

	switch (params.shape) {
		.random => {
			while (changed < target) {
				const idx = rng.intRangeLessThan(usize, 0, base_len);
				if (used[idx]) continue;
				used[idx] = true;

				const actual = if (symbol_only)
					(header_size + (idx / symbol_size) * (record_overhead + symbol_size) + record_overhead + (idx % symbol_size))
				else
					(start + idx);

				offsets[changed] = actual;
				sum_index += actual;
				changed += 1;
			}
		},
		.clustered => {
			var clusters_done: usize = 0;
			while (changed < target and clusters_done < cluster_count) : (clusters_done += 1) {
				const start_idx = rng.intRangeLessThan(usize, 0, base_len);
				var j: usize = 0;
				while (j < cluster_size and changed < target) : (j += 1) {
					const idx = start_idx + j;
					if (idx >= base_len) break;
					if (used[idx]) continue;
					used[idx] = true;

					const actual = if (symbol_only)
						(header_size + (idx / symbol_size) * (record_overhead + symbol_size) + record_overhead + (idx % symbol_size))
					else
						(start + idx);

					offsets[changed] = actual;
					sum_index += actual;
					changed += 1;
				}
			}
			while (changed < target) {
				const idx = rng.intRangeLessThan(usize, 0, base_len);
				if (used[idx]) continue;
				used[idx] = true;

				const actual = if (symbol_only)
					(header_size + (idx / symbol_size) * (record_overhead + symbol_size) + record_overhead + (idx % symbol_size))
				else
					(start + idx);

				offsets[changed] = actual;
				sum_index += actual;
				changed += 1;
			}
		},
		.normalized => {
			const center = params.center orelse (base_len / 2);
			const sigma = params.sigma orelse (@as(f64, @floatFromInt(base_len)) / 6.0);
			while (changed < target) {
				const idx = sampleNormalIndex(&rng, @min(center, base_len - 1), sigma, base_len);
				if (used[idx]) continue;
				used[idx] = true;

				const actual = if (symbol_only)
					(header_size + (idx / symbol_size) * (record_overhead + symbol_size) + record_overhead + (idx % symbol_size))
				else
					(start + idx);

				offsets[changed] = actual;
				sum_index += actual;
				changed += 1;
			}
		},
	}

	const mean = if (changed == 0) 0.0 else @as(f64, @floatFromInt(sum_index)) / @as(f64, @floatFromInt(changed));
	return NoisePlan{ .offsets = offsets, .mean_index = mean };
}

fn applyByteNoise(buf: []u8, index: usize, rng: *std.Random) void {
	const orig = buf[index];
	var next = orig;
	while (next == orig) {
		next = rng.int(u8);
	}
	buf[index] = next;
}

fn sampleNormalIndex(rng: *std.Random, center: usize, sigma: f64, span: usize) usize {
	const mean = @as(f64, @floatFromInt(center));
	var idx: usize = center;
	while (true) {
		const u1_val = @max(rng.float(f64), 1e-12);
		const u2_val = rng.float(f64);
		const z0 = std.math.sqrt(-2.0 * std.math.log(f64, std.math.e, u1_val)) * std.math.cos(2.0 * std.math.pi * u2_val);
		const value = mean + z0 * sigma;
		if (value < 0.0) continue;
		const pos = @as(usize, @intFromFloat(@round(value)));
		if (pos < span) {
			idx = pos;
			break;
		}
	}
	return idx;
}
