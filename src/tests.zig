const std = @import("std");
const nanorq = @import("nanorq.zig");
const core = @import("core/mod.zig");
const rand_tables = @import("core/rand_tables.zig");

fn sampleInput(allocator: std.mem.Allocator, len: usize) ![]u8 {
	const buf = try allocator.alloc(u8, len);
	for (buf, 0..) |*b, i| {
		b.* = @as(u8, @truncate(i));
	}
	return buf;
}

test "encode/decode roundtrip" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const input = try sampleInput(allocator, 2048);
	defer allocator.free(input);

	const params = nanorq.EncodeParams{
		.symbol_size = 64,
		.alignment = 8,
		.precalculate = true,
	};
	const redundancy = nanorq.Redundancy{ .overhead_pct = 20.0 };

	const encoded = try nanorq.encode(allocator, input, params, redundancy);
	defer allocator.free(encoded);

	const decoded = try nanorq.decode(allocator, encoded);
	defer allocator.free(decoded.data);

	try std.testing.expectEqualSlices(u8, input, decoded.data);
}

test "params init selects correct table row" {
	const p0 = core.params.init(10);
	try std.testing.expectEqual(@as(u16, 10), p0.Kprime);
	try std.testing.expectEqual(@as(u16, 254), p0.J);
	try std.testing.expectEqual(@as(u16, 7), p0.S);
	try std.testing.expectEqual(@as(u16, 10), p0.H);
	try std.testing.expectEqual(@as(u16, 17), p0.W);
	try std.testing.expectEqual(@as(u16, 27), p0.L);
	try std.testing.expectEqual(@as(u16, 10), p0.P);
	try std.testing.expectEqual(@as(u16, 0), p0.U);
	try std.testing.expectEqual(@as(u16, 10), p0.B);
	try std.testing.expectEqual(@as(u16, 11), p0.P1);

	const p1 = core.params.init(11);
	try std.testing.expectEqual(@as(u16, 12), p1.Kprime);
	try std.testing.expectEqual(@as(u16, 630), p1.J);
	try std.testing.expectEqual(@as(u16, 7), p1.S);
	try std.testing.expectEqual(@as(u16, 10), p1.H);
	try std.testing.expectEqual(@as(u16, 19), p1.W);
	try std.testing.expectEqual(@as(u16, 29), p1.L);
	try std.testing.expectEqual(@as(u16, 10), p1.P);
	try std.testing.expectEqual(@as(u16, 0), p1.U);
	try std.testing.expectEqual(@as(u16, 12), p1.B);
	try std.testing.expectEqual(@as(u16, 11), p1.P1);
}

test "rndGet deterministic sample" {
	const expected0 = (rand_tables.V0[0] ^ rand_tables.V1[0] ^ rand_tables.V2[0] ^ rand_tables.V3[0]) % 256;
	try std.testing.expectEqual(expected0, core.rand.rndGet(0, 0, 256));

	const y: u32 = 0x01020304;
	const i: u8 = 7;
	const x0: u8 = @truncate(y + i);
	const x1: u8 = @truncate((y >> 8) + i);
	const x2: u8 = @truncate((y >> 16) + i);
	const x3: u8 = @truncate((y >> 24) + i);
	const expected1 = (rand_tables.V0[x0] ^ rand_tables.V1[x1] ^ rand_tables.V2[x2] ^ rand_tables.V3[x3]) % 1000003;
	try std.testing.expectEqual(expected1, core.rand.rndGet(y, i, 1000003));
}

test "tuple values stay within bounds" {
	const p = core.params.init(20);
	const t = core.tuple.genTuple(1234, &p);

	try std.testing.expect(t.d <= p.W - 2);
	try std.testing.expect(t.a >= 1 and t.a < p.W);
	try std.testing.expect(t.b < p.W);
	try std.testing.expect(t.d1 >= 2);
	try std.testing.expect(t.a1 >= 1 and t.a1 < p.P1);
	try std.testing.expect(t.b1 < p.P1);
}

test "gf256 mul/inv basic" {
	const gf256 = core.gf256;
	try std.testing.expectEqual(@as(u8, 0), gf256.mul(0, 5));
	try std.testing.expectEqual(@as(u8, 0), gf256.mul(5, 0));
	try std.testing.expectEqual(@as(u8, 5), gf256.mul(1, 5));

	const a: u8 = 7;
	const inv = gf256.inv(a);
	try std.testing.expect(inv != 0);
	try std.testing.expectEqual(@as(u8, 1), gf256.mul(a, inv));
}

test "gf2 set/get xor" {
	const gf2 = core.gf2;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var m = try gf2.Mat.init(allocator, 3, 10);
	defer m.deinit(allocator);

	m.set(1, 2, 1);
	m.set(1, 5, 1);
	try std.testing.expectEqual(@as(u8, 1), m.get(1, 2));
	try std.testing.expectEqual(@as(u8, 1), m.get(1, 5));
	try std.testing.expectEqual(@as(u8, 0), m.get(1, 6));

	m.set(0, 2, 1);
	m.xorRow(1, 0);
	try std.testing.expectEqual(@as(u8, 0), m.get(1, 2));
	try std.testing.expectEqual(@as(u8, 1), m.get(1, 5));
}

test "gf2 axpy fill nnz swapcol" {
	const gf2 = core.gf2;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var m = try gf2.Mat.init(allocator, 2, 8);
	defer m.deinit(allocator);

	m.set(0, 1, 1);
	m.set(0, 4, 1);
	m.set(1, 2, 1);

	const dst = try allocator.alloc(u8, 8);
	defer allocator.free(dst);
	@memset(dst, 0);
	m.axpy(0, dst, 5);
	try std.testing.expectEqual(@as(u8, 5), dst[1]);
	try std.testing.expectEqual(@as(u8, 5), dst[4]);
	try std.testing.expectEqual(@as(u8, 0), dst[2]);

	@memset(dst, 0);
	m.fill(1, dst);
	try std.testing.expectEqual(@as(u8, 1), dst[2]);

	try std.testing.expectEqual(@as(usize, 2), m.nnz(0, 0, 8));

	m.swapCol(1, 2);
	try std.testing.expectEqual(@as(u8, 0), m.get(0, 1));
	try std.testing.expectEqual(@as(u8, 1), m.get(0, 2));
}

test "octmat row ops" {
	const octmat = core.octmat;
	const gf256 = core.gf256;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var m = try octmat.Mat.init(allocator, 2, 3);
	defer m.deinit(allocator);

	m.set(0, 0, 5);
	m.set(0, 1, 7);
	m.set(1, 0, 9);
	m.set(1, 1, 4);

	m.addRow(0, 1);
	try std.testing.expectEqual(@as(u8, 5 ^ 9), m.get(0, 0));
	try std.testing.expectEqual(@as(u8, 7 ^ 4), m.get(0, 1));

	m.scalRow(1, 2);
	try std.testing.expectEqual(gf256.mul(9, 2), m.get(1, 0));
	try std.testing.expectEqual(gf256.mul(4, 2), m.get(1, 1));
}

test "spmat transpose and nnz" {
	const spmat = core.spmat;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var s = try spmat.Mat.init(allocator, 3, 4);
	defer s.deinit(allocator);

	try s.push(allocator, 0, 1);
	try s.push(allocator, 0, 3);
	try s.push(allocator, 2, 1);

	try std.testing.expectEqual(@as(usize, 2), s.nnz(0, 0, 4));
	try std.testing.expectEqual(@as(usize, 1), s.nnz(2, 0, 2));

	var t = try s.transpose(allocator);
	defer t.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 2), t.nnz(1, 0, 3));
	try std.testing.expectEqual(@as(usize, 1), t.nnz(3, 0, 3));
}

test "schedule init and push" {
	const sched = core.sched;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var s = try sched.Schedule.init(allocator, 3, 4, 8);
	defer s.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 3), s.rows);
	try std.testing.expectEqual(@as(usize, 4), s.cols);
	try std.testing.expectEqual(@as(i32, 0), s.c[0]);
	try std.testing.expectEqual(@as(i32, 0), s.d[0]);

	try s.push(allocator, 1, 2, 7);
	try std.testing.expectEqual(@as(usize, 1), s.ops.items.len);
}

test "wrkmat axpy and promote" {
	const wrkmat = core.wrkmat;
	const octmat = core.octmat;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var w = try wrkmat.Mat.init(allocator, 2, 4);
	defer w.deinit(allocator);

	var block = try octmat.Mat.init(allocator, 2, 4);
	defer block.deinit(allocator);
	block.set(0, 0, 2);
	block.set(0, 1, 5);

	try w.assignBlock(allocator, &block, 1, 0, 1, 4);
	w.gf2.set(0, 0, 1);
	w.gf2.set(0, 2, 1);

	try w.axpy(1, 0, 3);
	try std.testing.expectEqual(@as(u8, 2 ^ 3), w.get(1, 0));

	try w.axpy(0, 1, 1);
	try std.testing.expect(w.rowtype[0] == 1);
	try std.testing.expectEqual(@as(u8, 0), w.get(0, 0));
}

test "wrkmat scal on gf2 row errors" {
	const wrkmat = core.wrkmat;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var w = try wrkmat.Mat.init(allocator, 1, 4);
	defer w.deinit(allocator);

	try std.testing.expectError(wrkmat.Mat.Error.InvalidRowType, w.scal(0, 2));
}

test "wrkmat promote beyond gf256 block errors" {
	const wrkmat = core.wrkmat;
	const octmat = core.octmat;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var w = try wrkmat.Mat.init(allocator, 3, 4);
	defer w.deinit(allocator);

	var block = try octmat.Mat.init(allocator, 1, 4);
	defer block.deinit(allocator);
	block.set(0, 0, 2);

	try w.assignBlock(allocator, &block, 1, 0, 1, 4);
	w.gf2.set(0, 0, 1);

	try std.testing.expectError(wrkmat.Mat.Error.OutOfGF256Rows, w.axpy(0, 1, 3));
}

test "bitmask set clear gaps" {
	const bitmask = core.bitmask;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var bm = bitmask.Mask.init();
	defer bm.deinit(allocator);

	try bm.ensureSize(allocator, 100);
	bm.set(allocator, 2);
	bm.set(allocator, 5);
	try std.testing.expect(bm.check(2));
	try std.testing.expect(!bm.check(3));

	bm.clear(allocator, 2);
	try std.testing.expect(!bm.check(2));

	try std.testing.expectEqual(@as(usize, 1), bm.popcount());
	try std.testing.expectEqual(@as(usize, 7), bm.gaps(8));
}

test "precode invert yields schedule" {
	const precode = core.precode;
	const params = core.params;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const p = params.init(10);
	var A = try precode.matrixGen(allocator, &p, 0);
	defer A.deinit(allocator);

	var S = try precode.matrixInvert(allocator, &p, &A);
	defer S.deinit(allocator);

	try std.testing.expect(S.ops.items.len > 0);
}

test "partition fill basic" {
	const core_nan = core.nanorq_core;
	const p = core_nan.fillPartition(10, 3);
	try std.testing.expectEqual(@as(usize, 4), p.IL);
	try std.testing.expectEqual(@as(usize, 3), p.IS);
	try std.testing.expectEqual(@as(usize, 1), p.JL);
	try std.testing.expectEqual(@as(usize, 2), p.JS);
}

test "nanorq tag packs sbn and esi" {
	const core_nan = core.nanorq_core;
	try std.testing.expectEqual(@as(u32, 0x02123456), core_nan.tag(2, 0x123456));
}

test "counting allocator tracks bytes" {
	const counting = core.counting_allocator;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var counter = counting.CountingAllocator.init(allocator);
	const alloc = counter.allocator();
	const baseline = counter.snapshot().current;

	const buf = try alloc.alloc(u8, 64);
	var stats = counter.snapshot();
	try std.testing.expect(stats.current >= baseline + 64);
	try std.testing.expect(stats.peak >= stats.current);

	alloc.free(buf);
	stats = counter.snapshot();
	try std.testing.expectEqual(baseline, stats.current);
}

test "gen scheme specific defaults" {
	const core_nan = core.nanorq_core;
	const common = core_nan.OtiCommon{ .F = 1000, .T = 10, .Al = 4 };
	const scheme = core_nan.genSchemeSpecific(&common, 0, 0);
	try std.testing.expectEqual(@as(usize, 100), scheme.Kt);
	try std.testing.expectEqual(@as(usize, 15), scheme.Z);
	try std.testing.expectEqual(@as(usize, 1), scheme.N);
}

test "block symbols by source block" {
	const core_nan = core.nanorq_core;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var rq = try core_nan.encoderNew(allocator, 30, 3, 0, 3, 1);
	defer rq.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 4), rq.blockSymbols(0));
	try std.testing.expectEqual(@as(usize, 3), rq.blockSymbols(1));
	try std.testing.expectEqual(@as(usize, 3), rq.blockSymbols(2));
}

test "decoder accepts high repair ESI" {
	const core_nan = core.nanorq_core;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	var enc = try core_nan.encoderNew(allocator, 100, 10, 0, 0, 1);
	defer enc.deinit(allocator);
	const common = core_nan.otiCommon(&enc);
	const scheme = core_nan.otiSchemeSpecific(&enc);

	var dec = try core_nan.decoderNew(allocator, common, scheme);
	defer dec.deinit(allocator);

	const esi: u32 = @as(u32, dec.P.Kprime) * 2 + 5;
	const symbol = try allocator.alloc(u8, dec.common.T);
	defer allocator.free(symbol);
	@memset(symbol, 0);
	const output = try allocator.alloc(u8, dec.common.F);
	defer allocator.free(output);
	@memset(output, 0);

	const res = try core_nan.decoderAddSymbol(&dec, allocator, symbol, core_nan.tag(0, esi), output);
	try std.testing.expectEqual(core_nan.SymResult.added, res);
}

test "repair-only decode with high ESIs" {
	const core_nan = core.nanorq_core;
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const k: usize = 10;
	const t: usize = 8;
	const len = k * t;

	const input = try allocator.alloc(u8, len);
	defer allocator.free(input);
	for (input, 0..) |*b, i| b.* = @as(u8, @truncate(i));

	var enc = try core_nan.encoderNew(allocator, len, t, @intCast(k), 0, 1);
	defer enc.deinit(allocator);
	const common = core_nan.otiCommon(&enc);
	const scheme = core_nan.otiSchemeSpecific(&enc);

	const symbol = try allocator.alloc(u8, t);
	defer allocator.free(symbol);

	const start = @as(u32, @intCast(enc.P.Kprime)) * 2 + 1;
	const max_count: usize = k * 6;
	var success = false;
	var count: usize = k;
	while (count <= max_count and !success) : (count += 1) {
		var dec = try core_nan.decoderNew(allocator, common, scheme);
		defer dec.deinit(allocator);

		const output = try allocator.alloc(u8, len);
		defer allocator.free(output);
		@memset(output, 0);

		for (0..count) |idx| {
			const esi = start + @as(u32, @intCast(idx));
			_ = try core_nan.encodeSymbol(&enc, allocator, 0, esi, input, symbol);
			const res = try core_nan.decoderAddSymbol(&dec, allocator, symbol, core_nan.tag(0, esi), output);
			try std.testing.expect(res != core_nan.SymResult.err);
		}

		const repaired = try core_nan.repairBlock(&dec, allocator, 0, output);
		if (repaired and std.mem.eql(u8, input, output)) {
			success = true;
		}
	}
	try std.testing.expect(success);
}

test "noise random changes exact count" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const data = try sampleInput(allocator, 100);
	defer allocator.free(data);

	const params = nanorq.NoiseParams{
		.pct = 10.0,
		.shape = .random,
		.seed = 1234,
	};

	const result = try nanorq.applyNoise(allocator, data, params);
	defer allocator.free(result.data);

	try std.testing.expectEqual(@as(usize, 10), result.changed_count);
}

test "noise clustered changes exact count" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const data = try sampleInput(allocator, 100);
	defer allocator.free(data);

	const params = nanorq.NoiseParams{
		.pct = 12.0,
		.shape = .clustered,
		.cluster_size = 4,
		.seed = 99,
	};

	const result = try nanorq.applyNoise(allocator, data, params);
	defer allocator.free(result.data);

	try std.testing.expectEqual(@as(usize, 12), result.changed_count);
}

test "noise normalized clusters near center" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const data = try sampleInput(allocator, 200);
	defer allocator.free(data);

	const params = nanorq.NoiseParams{
		.pct = 10.0,
		.shape = .normalized,
		.center = 100,
		.sigma = 8.0,
		.seed = 42,
	};

	const result = try nanorq.applyNoise(allocator, data, params);
	defer allocator.free(result.data);

	try std.testing.expectEqual(@as(usize, 20), result.changed_count);
	try std.testing.expect(result.mean_index > 90.0);
	try std.testing.expect(result.mean_index < 110.0);
}

test "simulate reports deterministic success rate for zero noise" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const input = try sampleInput(allocator, 4096);
	defer allocator.free(input);

	const params = nanorq.EncodeParams{
		.symbol_size = 128,
		.alignment = 8,
	};
	const redundancy = nanorq.Redundancy{ .repair_symbols = 10 };
	const noise = nanorq.NoiseParams{
		.pct = 0.0,
		.shape = .random,
		.seed = 1,
	};

	const result = try nanorq.simulate(allocator, input, params, redundancy, noise, 5);
	try std.testing.expectEqual(@as(usize, 5), result.trials);
	try std.testing.expectEqual(@as(usize, 5), result.successes);
}

test "simulate succeeds with zero noise and no redundancy (crc on)" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const input = try sampleInput(allocator, 64 * 1024);
	defer allocator.free(input);

	const params = nanorq.EncodeParams{
		.symbol_size = 1280,
		.alignment = 8,
		.crc = true,
	};
	const redundancy = nanorq.Redundancy{};
	const noise = nanorq.NoiseParams{
		.pct = 0.0,
		.shape = .random,
		.seed = 1,
	};

	const result = try nanorq.simulate(allocator, input, params, redundancy, noise, 2);
	try std.testing.expectEqual(@as(usize, 2), result.successes);
}

test "encode/decode roundtrip mixed block sizes" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const len = 17 * 64;
	const input = try allocator.alloc(u8, len);
	defer allocator.free(input);
	for (input, 0..) |*b, i| b.* = @as(u8, @truncate(i));

	const params = nanorq.EncodeParams{
		.symbol_size = 64,
		.alignment = 8,
	};
	const redundancy = nanorq.Redundancy{};

	const encoded = try nanorq.encode(allocator, input, params, redundancy);
	defer allocator.free(encoded);

	const decoded = try nanorq.decode(allocator, encoded);
	defer allocator.free(decoded.data);

	try std.testing.expectEqualSlices(u8, input, decoded.data);
}

test "encode/decode roundtrip single block override" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const len = 17 * 64;
	const input = try allocator.alloc(u8, len);
	defer allocator.free(input);
	for (input, 0..) |*b, i| b.* = @as(u8, @truncate(i));

	const params = nanorq.EncodeParams{
		.symbol_size = 64,
		.alignment = 8,
		.source_symbols = 17,
		.blocks = 1,
	};
	const redundancy = nanorq.Redundancy{};

	const encoded = try nanorq.encode(allocator, input, params, redundancy);
	defer allocator.free(encoded);

	const decoded = try nanorq.decode(allocator, encoded);
	defer allocator.free(decoded.data);

	try std.testing.expectEqualSlices(u8, input, decoded.data);
}

test "crc drops corrupted symbols" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const input = try sampleInput(allocator, 512);
	defer allocator.free(input);

	const params = nanorq.EncodeParams{
		.symbol_size = 64,
		.alignment = 8,
		.crc = true,
	};
	const redundancy = nanorq.Redundancy{ .overhead_pct = 0.0 };

	const encoded = try nanorq.encode(allocator, input, params, redundancy);
	defer allocator.free(encoded);

	var corrupted = try allocator.dupe(u8, encoded);
	defer allocator.free(corrupted);

	const record_overhead: usize = 8;
	const symbol_offset = 24 + record_overhead;
	corrupted[symbol_offset] ^= 0xff;

	try std.testing.expectError(error.RepairFailed, nanorq.decode(allocator, corrupted));
}

test "encode/decode roundtrip large random with crc" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const len = 1 * 1024 * 1024;
	const input = try allocator.alloc(u8, len);
	defer allocator.free(input);
	var prng = std.Random.DefaultPrng.init(1234);
	var rng = prng.random();
	for (input) |*b| b.* = rng.int(u8);

	const params = nanorq.EncodeParams{
		.symbol_size = 1280,
		.alignment = 8,
		.crc = true,
	};
	const redundancy = nanorq.Redundancy{};

	const encoded = try nanorq.encode(allocator, input, params, redundancy);
	defer allocator.free(encoded);

	const decoded = try nanorq.decode(allocator, encoded);
	defer allocator.free(decoded.data);

	try std.testing.expectEqualSlices(u8, input, decoded.data);
}

test "simulate succeeds for large input with zero noise" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const len = 1 * 1024 * 1024;
	const input = try allocator.alloc(u8, len);
	defer allocator.free(input);
	var prng = std.Random.DefaultPrng.init(1);
	var rng = prng.random();
	for (input) |*b| b.* = rng.int(u8);

	const params = nanorq.EncodeParams{
		.symbol_size = 1280,
		.alignment = 8,
		.crc = true,
	};
	const redundancy = nanorq.Redundancy{};
	const noise = nanorq.NoiseParams{
		.pct = 0.0,
		.shape = .random,
		.seed = 1,
	};

	const result = try nanorq.simulate(allocator, input, params, redundancy, noise, 2);
	try std.testing.expectEqual(@as(usize, 2), result.successes);
}
