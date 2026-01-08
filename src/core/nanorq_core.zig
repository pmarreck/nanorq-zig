const std = @import("std");
const table2 = @import("table2.zig");
const params_mod = @import("params.zig");
const precode = @import("precode.zig");
const octmat = @import("octmat.zig");
const bitmask = @import("bitmask.zig");
const tuple = @import("tuple.zig");
const rand = @import("rand.zig");
const spmat = @import("spmat.zig");
const sched = @import("sched.zig");

pub const max_transfer: usize = 946270874880;

pub const OtiCommon = struct {
	F: usize,
	T: usize,
	Al: usize,
};

pub const OtiScheme = struct {
	Z: usize,
	N: usize,
	Kt: usize,
};

const SourceBlock = struct {
	sbloc: usize,
	part_tot: usize,
	part: Partition,
};

pub const Partition = struct {
	IL: usize,
	IS: usize,
	JL: usize,
	JS: usize,
};

pub fn tag(sbn: u8, esi: u32) u32 {
	return (@as(u32, sbn) << 24) | (esi & 0x00ffffff);
}

fn divCeil(a: usize, b: usize) usize {
	return (a / b) + @as(usize, if (a % b != 0) 1 else 0);
}

fn divFloor(a: usize, b: usize) usize {
	return a / b;
}

pub fn fillPartition(I: usize, J: usize) Partition {
	if (J == 0) return Partition{ .IL = 0, .IS = 0, .JL = 0, .JS = 0 };
	var p = Partition{
		.IL = divCeil(I, J),
		.IS = divFloor(I, J),
		.JL = I - divFloor(I, J) * J,
		.JS = 0,
	};
	p.JS = J - p.JL;
	if (p.JL == 0) p.IL = 0;
	return p;
}

pub fn genSchemeSpecific(common: *const OtiCommon, K: usize, Z: usize) OtiScheme {
	var Kn = K;
	var scheme = OtiScheme{ .Z = 0, .N = 0, .Kt = divCeil(common.F, common.T) };

	var z = Z;
	if (K == 0) {
		Kn = scheme.Kt;
		if (z == 0) {
			z = 16;
			while (divCeil(scheme.Kt, z) > table2.K_max) {
				z += 1;
			}
		}
	}
	if (z > 0 and K == 0) {
		Kn = divCeil(scheme.Kt, z);
	}
	scheme.Z = divCeil(scheme.Kt, Kn);
	scheme.N = 1;
	return scheme;
}

pub const Nanorq = struct {
	common: OtiCommon,
	scheme: OtiScheme,
	src_part: Partition,
	sub_part: Partition,
	P: params_mod.Params,
	encoders: []?*BlockEncoder,
	S: ?sched.Schedule,

	pub fn deinit(self: *Nanorq, allocator: std.mem.Allocator) void {
		for (self.encoders) |maybe| {
			if (maybe) |enc| {
				enc.deinit(allocator);
				allocator.destroy(enc);
			}
		}
		if (self.S) |*s| {
			s.deinit(allocator);
		}
		allocator.free(self.encoders);
		self.* = undefined;
	}

	pub fn blockSymbols(self: *Nanorq, sbn: usize) usize {
		if (sbn < self.src_part.JL) return self.src_part.IL;
		if (sbn - self.src_part.JL < self.src_part.JS) return self.src_part.IS;
		return 0;
	}

	pub fn blocks(self: *Nanorq) usize {
		return self.src_part.JL + self.src_part.JS;
	}

	fn getBlockEncoder(self: *Nanorq, allocator: std.mem.Allocator, sbn: usize) !*BlockEncoder {
		if (sbn >= self.blocks() or sbn >= table2.Z_max) return error.InvalidBlock;
		if (self.encoders[sbn]) |enc| return enc;
		const K = self.blockSymbols(sbn);
		const rows = self.P.L;
		const enc = try allocator.create(BlockEncoder);
		enc.* = try BlockEncoder.init(allocator, @intCast(K), rows, self.common.T);
		self.encoders[sbn] = enc;
		return enc;
	}

	pub fn precalculate(self: *Nanorq, allocator: std.mem.Allocator) !void {
		var A = try precode.matrixGen(allocator, &self.P, 0);
		defer A.deinit(allocator);
		const S = try precode.matrixInvert(allocator, &self.P, &A);
		self.S = S;
	}
};

pub const RepairSym = struct {
	esi: u32,
	row: octmat.Mat,
};

pub const BlockEncoder = struct {
	K: u16,
	loaded: bool,
	inverted: bool,
	D: octmat.Mat,
	repair_bin: std.ArrayList(RepairSym),
	repair_mask: bitmask.Mask,

	pub fn init(allocator: std.mem.Allocator, K: u16, rows: usize, cols: usize) !BlockEncoder {
		const d = try octmat.Mat.init(allocator, rows, cols);
		var mask = bitmask.Mask.init();
		try mask.ensureSize(allocator, K);
		return BlockEncoder{
			.K = K,
			.loaded = false,
			.inverted = false,
			.D = d,
			.repair_bin = std.ArrayList(RepairSym).empty,
			.repair_mask = mask,
		};
	}

	pub fn deinit(self: *BlockEncoder, allocator: std.mem.Allocator) void {
		self.D.deinit(allocator);
		for (self.repair_bin.items) |*sym| {
			sym.row.deinit(allocator);
		}
		self.repair_bin.deinit(allocator);
		self.repair_mask.deinit(allocator);
		self.* = undefined;
	}

	pub fn reset(self: *BlockEncoder, allocator: std.mem.Allocator) void {
		self.loaded = false;
		self.inverted = false;
		self.D.zeroRow(0);
		@memset(self.D.data, 0);
		for (self.repair_bin.items) |*sym| {
			sym.row.deinit(allocator);
		}
		self.repair_bin.clearRetainingCapacity();
		self.repair_mask.reset();
	}

	pub fn ensureRows(self: *BlockEncoder, allocator: std.mem.Allocator, rows: usize) !void {
		if (self.D.rows >= rows) return;
		var new_mat = try octmat.Mat.init(allocator, rows, self.D.cols);
		const old_len = self.D.rows * self.D.cols_al;
		@memcpy(new_mat.data[0..old_len], self.D.data[0..old_len]);
		self.D.deinit(allocator);
		self.D = new_mat;
	}
};

pub fn encoderNew(allocator: std.mem.Allocator, len: usize, T_in: usize, K: usize, Z: usize, Al_in: usize) !Nanorq {
	if (len > max_transfer) return error.InputTooLarge;

	const alignments = [_]usize{ 1, 2, 4, 8 };
	var Al = Al_in;
	for (alignments, 0..) |_, idx| {
		const rev = alignments[alignments.len - 1 - idx];
		if (Al >= rev) {
			Al = rev;
			break;
		}
	}
	if (Al == 0) Al = 1;

	var T = T_in;
	if (T < Al) {
		T = Al;
	} else {
		T -= T % Al;
	}

	while (divCeil(len, T) > @as(usize, table2.Z_max) * @as(usize, table2.K_max)) {
		T *= Al;
	}

	var common = OtiCommon{ .F = len, .T = T, .Al = Al };
	const scheme = genSchemeSpecific(&common, K, Z);

	if (scheme.Z == 0 or scheme.N == 0 or scheme.Z > table2.Z_max or divCeil(scheme.Kt, scheme.Z) > table2.K_max) {
		return error.InvalidScheme;
	}

	const src_part = fillPartition(scheme.Kt, scheme.Z);
	const sub_part = fillPartition(common.T / common.Al, scheme.N);
	const k0 = if (src_part.JL > 0) src_part.IL else src_part.IS;
	const P = params_mod.init(@intCast(k0));
	const encoders = try allocator.alloc(?*BlockEncoder, table2.Z_max);
	@memset(encoders, null);

	return Nanorq{
		.common = common,
		.scheme = scheme,
		.src_part = src_part,
		.sub_part = sub_part,
		.P = P,
		.encoders = encoders,
		.S = null,
	};
}

pub fn decoderNew(allocator: std.mem.Allocator, common: u64, scheme: u32) !Nanorq {
	const F = @as(usize, common >> 24);
	const T = @as(usize, (common & 0xffff) + 1);
	if (F > max_transfer) return error.InputTooLarge;

	var rq = Nanorq{
		.common = .{ .F = F, .T = T, .Al = 0 },
		.scheme = .{ .Z = 0, .N = 0, .Kt = 0 },
		.src_part = .{ .IL = 0, .IS = 0, .JL = 0, .JS = 0 },
		.sub_part = .{ .IL = 0, .IS = 0, .JL = 0, .JS = 0 },
		.P = undefined,
		.encoders = try allocator.alloc(?*BlockEncoder, table2.Z_max),
		.S = null,
	};
	@memset(rq.encoders, null);

	rq.scheme.Z = @as(usize, (scheme >> 24) & 0xff) + 1;
	rq.scheme.N = @as(usize, (scheme >> 8) & 0xffff) + 1;
	rq.common.Al = @as(usize, scheme & 0xff);
	rq.scheme.Kt = divCeil(rq.common.F, rq.common.T);

	if (rq.scheme.Z == 0) rq.scheme.Z = table2.Z_max;
	if (rq.scheme.N == 0) rq.scheme.N = 1;

	if (rq.common.T < rq.common.Al or (rq.common.T % rq.common.Al != 0) or divCeil(divCeil(rq.common.F, rq.common.T), rq.scheme.Z) > table2.K_max) {
		rq.deinit(allocator);
		return error.InvalidScheme;
	}

	rq.src_part = fillPartition(rq.scheme.Kt, rq.scheme.Z);
	rq.sub_part = fillPartition(rq.common.T / rq.common.Al, rq.scheme.N);
	const k0 = if (rq.src_part.JL > 0) rq.src_part.IL else rq.src_part.IS;
	rq.P = params_mod.init(@intCast(k0));

	return rq;
}

pub const SymResult = enum {
	added,
	ignored,
	duplicate,
	err,
};

pub fn decoderAddSymbol(rq: *Nanorq, allocator: std.mem.Allocator, data: []const u8, tag_val: u32, output: []u8) !SymResult {
	const sbn: usize = (tag_val >> 24) & 0xff;
	const esi: u32 = tag_val & 0x00ffffff;

	const dec = try rq.getBlockEncoder(allocator, sbn);
	if (dec.repair_mask.gaps(dec.K) == 0) return .ignored;
	if (dec.repair_mask.check(esi)) return .duplicate;

	if (esi < dec.K) {
		@memcpy(dec.D.rowSlice(rq.P.S + rq.P.H + @as(usize, esi))[0..dec.D.cols], data[0..dec.D.cols]);
		_ = transferEsi(rq, sbn, esi, dec.K, output, @constCast(data), true);
	} else {
		var rs = RepairSym{
			.esi = esi,
			.row = try octmat.Mat.init(allocator, 1, dec.D.cols),
		};
		@memcpy(rs.row.rowSlice(0)[0..dec.D.cols], data[0..dec.D.cols]);
		try dec.repair_bin.append(allocator, rs);
	}
	dec.repair_mask.set(allocator, esi);
	return .added;
}

pub fn numMissing(rq: *Nanorq, allocator: std.mem.Allocator, sbn: usize) !usize {
	const dec = try rq.getBlockEncoder(allocator, sbn);
	return dec.repair_mask.gaps(dec.K);
}

pub fn numRepair(rq: *Nanorq, allocator: std.mem.Allocator, sbn: usize) !usize {
	const dec = try rq.getBlockEncoder(allocator, sbn);
	return dec.repair_bin.items.len;
}

fn patchPrecodeMatrix(allocator: std.mem.Allocator, P: *const params_mod.Params, A: *spmat.Mat, K: u16, num_gaps: usize, mask: *bitmask.Mask, repair_bin: *std.ArrayList(RepairSym)) !void {
	const padding = P.Kprime - K;
	var rep_idx: usize = 0;
	var gaps_left = num_gaps;
	var gap: usize = 0;
	while (gap < P.L and gaps_left > 0) : (gap += 1) {
		if (mask.check(gap)) continue;
		const row = gap + P.H + P.S;
		const esi = repair_bin.items[rep_idx].esi + padding;
		rep_idx += 1;
		A.clearRow(row);
		try params_mod.setIdxs(allocator, esi, P, &A.idxs[row]);
		gaps_left -= 1;
	}
	var row: usize = P.L;
	while (row < A.rows) : (row += 1) {
		const esi = repair_bin.items[rep_idx].esi + padding;
		rep_idx += 1;
		A.clearRow(row);
		try params_mod.setIdxs(allocator, esi, P, &A.idxs[row]);
	}
}

fn fillSymbolMatrixGaps(P: *const params_mod.Params, D: *octmat.Mat, K: u16, repair_mask: *bitmask.Mask, repair_bin: *std.ArrayList(RepairSym)) void {
	var rep_idx: usize = 0;
	const skip = P.S + P.H;
	const num_repair = repair_bin.items.len;
	var gap: usize = 0;
	while (gap < K and rep_idx < num_repair) : (gap += 1) {
		if (repair_mask.check(gap)) continue;
		const row = skip + gap;
		const rs = repair_bin.items[rep_idx];
		rep_idx += 1;
		@memcpy(D.rowSlice(row)[0..D.cols], rs.row.rowSliceConst(0)[0..D.cols]);
	}
	var row: usize = P.L;
	while (rep_idx < num_repair) : (row += 1) {
		const rs = repair_bin.items[rep_idx];
		rep_idx += 1;
		@memcpy(D.rowSlice(row)[0..D.cols], rs.row.rowSliceConst(0)[0..D.cols]);
	}
}

fn decodeRepairRows(allocator: std.mem.Allocator, P: *const params_mod.Params, D: *octmat.Mat, K: u16, num_gaps: usize, repair_mask: *bitmask.Mask) !octmat.Mat {
	var M = try octmat.Mat.init(allocator, num_gaps, D.cols);
	var gap: usize = 0;
	var row: usize = 0;
	var gaps_left = num_gaps;
	while (gap < K and gaps_left > 0) : (gap += 1) {
		if (repair_mask.check(gap)) continue;
		decodeRow(P, D, @intCast(gap), M.rowSlice(row));
		row += 1;
		gaps_left -= 1;
	}
	return M;
}

fn writeRepairRows(rq: *Nanorq, sbn: usize, K: u16, output: []u8, M: *octmat.Mat, repair_mask: *bitmask.Mask, allocator: std.mem.Allocator) void {
	var row: usize = 0;
	var miss_row: usize = 0;
	while (row < K and miss_row < M.rows) : (row += 1) {
		if (repair_mask.check(row)) continue;
		_ = transferEsi(rq, sbn, @intCast(row), K, output, M.rowSlice(miss_row), true);
		repair_mask.set(allocator, row);
		miss_row += 1;
	}
}

pub fn repairBlock(rq: *Nanorq, allocator: std.mem.Allocator, sbn: usize, output: []u8) !bool {
	const dec = try rq.getBlockEncoder(allocator, sbn);
	const num_repair = dec.repair_bin.items.len;
	const num_gaps = dec.repair_mask.gaps(dec.K);
	if (num_gaps == 0) return true;
	if (num_repair < num_gaps) return false;
	const overhead = num_repair - num_gaps;
	try dec.ensureRows(allocator, rq.P.L + overhead);

	fillSymbolMatrixGaps(&rq.P, &dec.D, dec.K, &dec.repair_mask, &dec.repair_bin);
	var A = try precode.matrixGen(allocator, &rq.P, overhead);
	defer A.deinit(allocator);
	try patchPrecodeMatrix(allocator, &rq.P, &A, dec.K, num_gaps, &dec.repair_mask, &dec.repair_bin);

	var S = try precode.matrixInvert(allocator, &rq.P, &A);
	defer S.deinit(allocator);
	try precode.matrixIntermediate(allocator, &rq.P, &dec.D, &S);
	var M = try decodeRepairRows(allocator, &rq.P, &dec.D, dec.K, num_gaps, &dec.repair_mask);
	defer M.deinit(allocator);
	writeRepairRows(rq, sbn, dec.K, output, &M, &dec.repair_mask, allocator);

	return dec.repair_mask.gaps(dec.K) == 0;
}

pub fn otiCommon(rq: *Nanorq) u64 {
	var ret: u64 = 0;
	ret |= @as(u64, rq.common.F) << 24;
	ret |= (@as(u64, rq.common.T - 1) & 0xffff);
	return ret;
}

pub fn otiSchemeSpecific(rq: *Nanorq) u32 {
	var ret: u32 = 0;
	ret |= @as(u32, @intCast(rq.scheme.Z - 1)) << 24;
	ret |= @as(u32, @intCast(rq.scheme.N - 1)) << 8;
	ret |= @as(u32, @intCast(rq.common.Al & 0xff));
	return ret;
}

fn getSourceBlock(rq: *Nanorq, sbn: usize, symbol_size: usize) SourceBlock {
	const part_tot = rq.sub_part.IL * rq.sub_part.JL;
	var sbloc: usize = 0;
	if (sbn < rq.src_part.JL) {
		sbloc = sbn * rq.src_part.IL * symbol_size;
	} else if (sbn - rq.src_part.JL < rq.src_part.JS) {
		sbloc = (rq.src_part.IL * rq.src_part.JL) * symbol_size + (sbn - rq.src_part.JL) * rq.src_part.IS * symbol_size;
	}
	return .{ .sbloc = sbloc, .part_tot = part_tot, .part = rq.sub_part };
}

fn getSymbolOffset(blk: *const SourceBlock, pos: usize, K: usize, esi: u32) usize {
	if (pos < blk.part_tot) {
		const sub_blk_id = pos / blk.part.IL;
		return blk.sbloc + sub_blk_id * K * blk.part.IL + @as(usize, esi) * blk.part.IL + pos % blk.part.IL;
	}
	const pos_part2 = pos - blk.part_tot;
	const sub_blk_id = pos_part2 / blk.part.IS;
	return blk.sbloc + (blk.part_tot * K) + sub_blk_id * K * blk.part.IS + @as(usize, esi) * blk.part.IS + pos_part2 % blk.part.IS;
}

fn transferEsi(rq: *Nanorq, sbn: usize, esi: u32, K: usize, data: []u8, buf: []u8, out: bool) usize {
	var transfer: usize = 0;
	var col: usize = 0;
	const symbol_size = rq.common.T / rq.common.Al;
	const blk = getSourceBlock(rq, sbn, symbol_size);
	var i: usize = 0;
	while (i < symbol_size) {
		const offset = getSymbolOffset(&blk, i, K, esi) * rq.common.Al;
		const sublen = if (i < blk.part_tot) blk.part.IL else blk.part.IS;
		var stride = sublen * rq.common.Al;
		i += sublen;

		if (offset >= rq.common.F) continue;
		if (offset + stride > rq.common.F) {
			stride = rq.common.F - offset;
		}
		if (out) {
			@memcpy(data[offset .. offset + stride], buf[col .. col + stride]);
		} else {
			@memcpy(buf[col .. col + stride], data[offset .. offset + stride]);
		}
		col += stride;
		transfer += stride;
	}
	return transfer;
}

fn loadSymbolMatrix(rq: *Nanorq, allocator: std.mem.Allocator, sbn: usize, input: []const u8) !void {
	const enc = try rq.getBlockEncoder(allocator, sbn);
	const k = enc.K;
	var esi: u32 = 0;
	var row: usize = rq.P.S + rq.P.H;
	while (esi < k) : (esi += 1) {
		_ = transferEsi(rq, sbn, esi, k, @constCast(input), enc.D.rowSlice(row), false);
		row += 1;
	}
	enc.loaded = true;
}

fn applyRow(D: *octmat.Mat, row: usize, out: []u8) void {
	const src = D.rowSlice(row);
	for (0..out.len) |i| {
		out[i] ^= src[i];
	}
}

fn decodeRow(P: *const params_mod.Params, D: *octmat.Mat, row: u32, out: []u8) void {
	@memset(out, 0);
	var t = tuple.genTuple(row, P);
	applyRow(D, t.b, out);
	var j: u32 = 1;
	while (j < t.d) : (j += 1) {
		t.b = (t.b + t.a) % P.W;
		applyRow(D, t.b, out);
	}
	while (t.b1 >= P.P) {
		t.b1 = (t.b1 + t.a1) % P.P1;
	}
	applyRow(D, P.W + t.b1, out);
	j = 1;
	while (j < t.d1) : (j += 1) {
		t.b1 = (t.b1 + t.a1) % P.P1;
		while (t.b1 >= P.P) {
			t.b1 = (t.b1 + t.a1) % P.P1;
		}
		applyRow(D, P.W + t.b1, out);
	}
}

pub fn generateSymbols(rq: *Nanorq, allocator: std.mem.Allocator, sbn: usize, input: []const u8) !void {
	const enc = try rq.getBlockEncoder(allocator, sbn);
	if (enc.inverted) return;
	if (!enc.loaded) try loadSymbolMatrix(rq, allocator, sbn, input);

	if (rq.S) |*S| {
		try precode.matrixIntermediate(allocator, &rq.P, &enc.D, S);
	} else {
		var A = try precode.matrixGen(allocator, &rq.P, 0);
		defer A.deinit(allocator);
		var S = try precode.matrixInvert(allocator, &rq.P, &A);
		defer S.deinit(allocator);
		try precode.matrixIntermediate(allocator, &rq.P, &enc.D, &S);
	}
	enc.inverted = true;
}

pub fn encodeSymbol(rq: *Nanorq, allocator: std.mem.Allocator, sbn: usize, esi: u32, input: []const u8, out: []u8) !usize {
	const enc = try rq.getBlockEncoder(allocator, sbn);
	if (esi < enc.K) {
		if (enc.inverted) {
			decodeRow(&rq.P, &enc.D, esi, out);
			return enc.D.cols;
		}
		if (!enc.loaded) try loadSymbolMatrix(rq, allocator, sbn, input);
		@memcpy(out[0..enc.D.cols], enc.D.rowSlice(rq.P.S + rq.P.H + @as(usize, esi)));
		return enc.D.cols;
	}
	if (esi > 0x00ffffff) return error.InvalidEsi;
	if (!enc.inverted) try generateSymbols(rq, allocator, sbn, input);
	const isi: u32 = esi + @as(u32, rq.P.Kprime - enc.K);
	decodeRow(&rq.P, &enc.D, isi, out);
	return enc.D.cols;
}
