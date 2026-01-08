const std = @import("std");
const params_mod = @import("params.zig");
const rand = @import("rand.zig");
const sched = @import("sched.zig");
const spmat = @import("spmat.zig");
const wrkmat = @import("wrkmat.zig");
const octmat = @import("octmat.zig");
const oct_tables = @import("oct_tables.zig");

fn applyPermute(D: *octmat.Mat, perm: []i32) void {
	for (0..perm.len) |i| {
		var at: i32 = @intCast(i);
		const mark: i32 = -1;
		while (perm[@intCast(at)] >= 0) {
			D.swapRow(@intCast(i), @intCast(perm[@intCast(at)]));
			const tmp = perm[@intCast(at)];
			perm[@intCast(at)] = mark;
			at = tmp;
		}
	}
}

fn applyOp(D: *octmat.Mat, S: *sched.Schedule, idx: usize) void {
	const op = S.ops.items[idx];
	if (op.beta != 0) {
		D.axpy(op.i, op.j, op.beta);
	} else {
		D.scalRow(op.i, @intCast(op.j));
	}
}

fn applySchedule(D: *octmat.Mat, S: *sched.Schedule) void {
	for (0..S.marks[1]) |i| {
		applyOp(D, S, i);
	}
	var i: i32 = @intCast(S.marks[0]);
	while (i >= 0) : (i -= 1) {
		applyOp(D, S, @intCast(i));
	}
	for (S.marks[1]..S.ops.items.len) |j| {
		applyOp(D, S, j);
	}
	for (0..S.marks[0] + 1) |j| {
		applyOp(D, S, j);
	}
}

fn makeIdentity(A: *spmat.Mat, allocator: std.mem.Allocator, dim: usize, m: usize, n: usize) !void {
	for (0..dim) |diag| {
		try A.push(allocator, m + diag, @intCast(n + diag));
	}
}

fn makeLDPC1(A: *spmat.Mat, allocator: std.mem.Allocator, S: usize, B: usize) !void {
	for (0..B) |col| {
		const submtx = col / S;
		const b1 = col % S;
		const b2 = (col + submtx + 1) % S;
		const b3 = (col + 2 * (submtx + 1)) % S;
		try A.push(allocator, b1, @intCast(col));
		try A.push(allocator, b2, @intCast(col));
		try A.push(allocator, b3, @intCast(col));
	}
}

fn makeLDPC2(A: *spmat.Mat, allocator: std.mem.Allocator, W: usize, S: usize, P: usize) !void {
	for (0..S) |idx| {
		const b1 = idx % P;
		const b2 = (idx + 1) % P;
		try A.push(allocator, idx, @intCast(W + b1));
		try A.push(allocator, idx, @intCast(W + b2));
	}
}

fn makeHDPC(allocator: std.mem.Allocator, p: *const params_mod.Params) !octmat.Mat {
	const m = p.H;
	const n = p.Kprime + p.S;
	var hdpc = try octmat.Mat.init(allocator, m, n);

	for (0..m) |row| {
		hdpc.set(row, n - 1, oct_tables.OCT_EXP[row]);
	}

	var col: i32 = @intCast(n - 2);
	while (col >= 0) : (col -= 1) {
		for (0..m) |row| {
			const prev = hdpc.get(row, @intCast(col + 1));
			if (prev == 0) {
				hdpc.set(row, @intCast(col), 0);
			} else {
				const idx = oct_tables.OCT_LOG[prev] + 1;
				hdpc.set(row, @intCast(col), oct_tables.OCT_EXP[idx]);
			}
		}
		const b1 = rand.rndGet(@intCast(col + 1), 6, @intCast(m));
		const b2 = (b1 + rand.rndGet(@intCast(col + 1), 7, @intCast(m - 1)) + 1) % @as(u32, @intCast(m));
		hdpc.set(b1, @intCast(col), hdpc.get(b1, @intCast(col)) ^ 1);
		hdpc.set(b2, @intCast(col), hdpc.get(b2, @intCast(col)) ^ 1);
	}

	return hdpc;
}

fn makeGEnc(A: *spmat.Mat, allocator: std.mem.Allocator, p: *const params_mod.Params) !void {
	var row: usize = p.S + p.H;
	while (row < p.L) : (row += 1) {
		try params_mod.setIdxs(allocator, @intCast(row - p.S - p.H), p, &A.idxs[row]);
	}
}

pub fn matrixGen(allocator: std.mem.Allocator, p: *const params_mod.Params, overhead: usize) !spmat.Mat {
	var A = try spmat.Mat.init(allocator, p.L + overhead, p.L);
	try makeLDPC1(&A, allocator, p.S, p.B);
	try makeIdentity(&A, allocator, p.S, 0, p.B);
	try makeLDPC2(&A, allocator, p.W, p.S, p.P);
	try makeGEnc(&A, allocator, p);
	return A;
}

fn matrixSort(p: *const params_mod.Params, A: *spmat.Mat, S: *sched.Schedule) void {
	for (0..A.rows) |row| {
		S.d[row] = @intCast((row + p.S + p.H) % A.rows);
	}
	for (0..A.rows) |i| {
		S.di[@intCast(S.d[i])] = @intCast(i);
	}
	for (0..A.rows) |row| {
		const drow: usize = @intCast(S.d[row]);
		var nnz = A.nnz(drow, 0, A.cols - p.P);
		if (nnz == 0) nnz = A.cols;
		S.nz[drow] = @intCast(nnz);
	}
}

fn popList(list: *std.ArrayList(u32)) ?u32 {
	if (list.items.len == 0) return null;
	const idx = list.items.len - 1;
	const val = list.items[idx];
	list.items.len -= 1;
	return val;
}

fn matrixChoose(V0: usize, Vrows: usize, Srows: usize, Vcols: usize, S: *sched.Schedule, NZT: *spmat.Mat) usize {
	_ = Vcols;
	var chosen: usize = Vrows;
	var b: usize = 1;
	while (b < 3) : (b += 1) {
		while (NZT.idxs[b].items.len > 0) {
			const maybe = popList(&NZT.idxs[b]) orelse break;
			chosen = maybe;
			if (@as(usize, @intCast(S.di[chosen])) >= V0 and S.nz[chosen] == b) {
				return @intCast(S.di[chosen]);
			}
		}
	}
	return Srows;
}

fn rowNzAt(A: *spmat.Mat, row: usize, s: usize, e: usize, S: *sched.Schedule, at: *[2]i32) usize {
	var r: usize = 0;
	at.* = .{ @intCast(e), @intCast(e) };
	const rs = &A.idxs[@intCast(S.d[row])];
	for (rs.items) |col| {
		if (r >= S.nz[@intCast(S.d[row])]) break;
		const mapped = @as(usize, @intCast(S.ci[col]));
		if (mapped >= s and mapped < e) {
			at[r] = @intCast(mapped);
			r += 1;
		}
	}
	if (at[0] > at[1]) {
		const tmp = at[0];
		at[0] = at[1];
		at[1] = tmp;
	}
	return r;
}

fn swapCols(A: *spmat.Mat, V0: usize, Vcols: usize, S: *sched.Schedule) usize {
	const Vlast = V0 + Vcols - 1;
	var ones: [2]i32 = .{ 0, 0 };
	const r = rowNzAt(A, V0, V0, V0 + Vcols, S, &ones);
	if (@as(usize, @intCast(ones[0])) != V0) {
		std.mem.swap(i32, &S.c[V0], &S.c[@intCast(ones[0])]);
		std.mem.swap(i32, &S.ci[@intCast(S.c[V0])], &S.ci[@intCast(S.c[@intCast(ones[0])])]);
	}
	if (r == 2 and @as(usize, @intCast(ones[1])) != Vlast) {
		std.mem.swap(i32, &S.c[Vlast], &S.c[@intCast(ones[1])]);
		std.mem.swap(i32, &S.ci[@intCast(S.c[Vlast])], &S.ci[@intCast(S.c[@intCast(ones[1])])]);
	}
	return r;
}

fn updateNnz(AT: *spmat.Mat, V0: usize, Vcols: usize, r: usize, S: *sched.Schedule, NZT: *spmat.Mat, allocator: std.mem.Allocator) !void {
	var cs = &AT.idxs[@intCast(S.c[V0])];
	for (cs.items) |row| {
		const nz = S.nz[row] - 1;
		S.nz[row] = nz;
		if (nz > 0 and nz < 3) {
			try NZT.push(allocator, nz, row);
		}
	}
	var col: usize = 0;
	while (col < r - 1) : (col += 1) {
		cs = &AT.idxs[@intCast(S.c[V0 + Vcols - col - 1])];
		for (cs.items) |row| {
			const nz = S.nz[row] - 1;
			S.nz[row] = nz;
			if (nz > 0 and nz < 3) {
				try NZT.push(allocator, nz, row);
			}
		}
	}
}

fn matrixPrecond(allocator: std.mem.Allocator, p: *const params_mod.Params, A: *spmat.Mat, AT: *spmat.Mat, S: *sched.Schedule) !void {
	var i: usize = 0;
	var u: usize = p.P;
	const rows = A.rows;
	const Srows = A.rows - p.H;
	const cols = A.cols;

	var NZT = try spmat.Mat.init(allocator, 3, rows);
	defer NZT.deinit(allocator);
	for (0..Srows) |row| {
		const drow: usize = @intCast(S.d[row]);
		if (S.nz[drow] < 3) {
			try NZT.push(allocator, S.nz[drow], @intCast(drow));
		}
	}
	while (i + u < p.L) {
		const Vrows = rows - i;
		const Vcols = cols - i - u;
		const V0 = i;
		const chosen = matrixChoose(V0, Vrows, Srows, Vcols, S, &NZT);
		if (chosen >= Srows) break;
		if (V0 != chosen) {
			std.mem.swap(i32, &S.d[V0], &S.d[chosen]);
			std.mem.swap(i32, &S.di[@intCast(S.d[V0])], &S.di[@intCast(S.d[chosen])]);
		}
		const r = swapCols(A, V0, Vcols, S);
		try updateNnz(AT, V0, Vcols, r, S, &NZT, allocator);
		i += 1;
		u += r - 1;
	}
	S.i = i;
	S.u = p.L - i;
}

fn fwdGE(U: *wrkmat.Mat, S: *sched.Schedule, AT: *spmat.Mat, s: usize, e: usize, allocator: std.mem.Allocator) !void {
	for (0..S.i) |row| {
		const mv = if (s < row) row else s;
		const cs = &AT.idxs[@intCast(S.c[row])];
		for (cs.items) |tmp| {
			const h = @as(usize, @intCast(S.di[tmp]));
			if (h > mv and h < e) {
				U.axpy(tmp, @intCast(S.d[row]), 1);
				try S.push(allocator, tmp, @intCast(S.d[row]), 1);
			}
		}
	}
}

fn fillU(U: *wrkmat.Mat, A: *spmat.Mat, S: *sched.Schedule) void {
	for (0..A.rows) |i| {
		const rs = &A.idxs[i];
		for (rs.items) |col| {
			const mapped = @as(usize, @intCast(S.ci[col]));
			if (mapped >= S.i) {
				U.set(i, mapped - S.i, 1);
			}
		}
	}
}

fn fillHDPC(allocator: std.mem.Allocator, p: *const params_mod.Params, U: *wrkmat.Mat, S: *sched.Schedule) !void {
	var hdpc = try makeHDPC(allocator, p);
	defer hdpc.deinit(allocator);
	var ul = try octmat.Mat.init(allocator, 2 * p.H, S.u);
	defer ul.deinit(allocator);

	for (0..p.H) |row| {
		for (0..(ul.cols - p.H)) |col| {
			const idx: usize = @intCast(S.c[hdpc.cols - (S.u - p.H) + col]);
			ul.set(row, col, hdpc.get(row, idx));
		}
		ul.set(row, row + (ul.cols - p.H), 1);
	}
	try U.assignBlock(allocator, &ul, p.S, 0, p.H, S.u);

	for (0..S.i) |row| {
		for (0..p.H) |h| {
			const beta = hdpc.get(h, @intCast(S.c[row]));
			if (beta != 0) {
				const target = @as(usize, @intCast(S.d[U.rows - p.H + h]));
				const source = @as(usize, @intCast(S.d[row]));
				U.axpy(target, source, beta);
				try S.push(allocator, @intCast(target), @intCast(source), beta);
			}
		}
	}
}

fn makeU(allocator: std.mem.Allocator, p: *const params_mod.Params, A: *spmat.Mat, AT: *spmat.Mat, S: *sched.Schedule) !wrkmat.Mat {
	var U = try wrkmat.Mat.init(allocator, A.rows, S.u);
	fillU(&U, A, S);
	try fwdGE(&U, S, AT, 0, S.i, allocator);
	S.marks[0] = if (S.ops.items.len == 0) 0 else S.ops.items.len - 1;
	const start = if (S.i == 0) 0 else S.i - 1;
	try fwdGE(&U, S, AT, start, A.rows - p.H, allocator);
	return U;
}

fn solveGF2(p: *const params_mod.Params, U: *wrkmat.Mat, S: *sched.Schedule, allocator: std.mem.Allocator) !usize {
	var row: usize = S.i;
	const rows = U.rows - p.H;
	while (row < p.L) : (row += 1) {
		const col = row - S.i;
		var nzrow: usize = row;
		while (nzrow < rows) : (nzrow += 1) {
			if (U.get(@intCast(S.d[nzrow]), col) != 0) break;
		}
		if (nzrow == rows) break;
		if (row != nzrow) {
			std.mem.swap(i32, &S.d[row], &S.d[nzrow]);
			std.mem.swap(i32, &S.di[@intCast(S.d[row])], &S.di[@intCast(S.d[nzrow])]);
		}
		var del_row = row + 1;
		while (del_row < rows) : (del_row += 1) {
			if (U.get(@intCast(S.d[del_row]), col) == 0) continue;
			U.axpy(@intCast(S.d[del_row]), @intCast(S.d[row]), 1);
			try S.push(allocator, @intCast(S.d[del_row]), @intCast(S.d[row]), 1);
		}
	}
	return row;
}

fn solveGF256(p: *const params_mod.Params, U: *wrkmat.Mat, S: *sched.Schedule, allocator: std.mem.Allocator) !usize {
	var row: usize = S.i;
	const rows = U.rows;
	while (row < p.L) : (row += 1) {
		const col = row - S.i;
		var nzrow: usize = row;
		var beta: u8 = 0;
		while (nzrow < rows) : (nzrow += 1) {
			beta = U.get(@intCast(S.d[nzrow]), col);
			if (beta != 0) break;
		}
		if (nzrow == rows) break;
		if (row != nzrow) {
			std.mem.swap(i32, &S.d[row], &S.d[nzrow]);
			std.mem.swap(i32, &S.di[@intCast(S.d[row])], &S.di[@intCast(S.d[nzrow])]);
		}
		if (beta > 1) {
			const inv = oct_tables.OCT_INV[beta];
			U.scal(@intCast(S.d[row]), inv);
			try S.push(allocator, @intCast(S.d[row]), inv, 0);
		}
		var del_row = row + 1;
		while (del_row < rows) : (del_row += 1) {
			beta = U.get(@intCast(S.d[del_row]), col);
			if (beta == 0) continue;
			U.axpy(@intCast(S.d[del_row]), @intCast(S.d[row]), beta);
			try S.push(allocator, @intCast(S.d[del_row]), @intCast(S.d[row]), beta);
		}
	}
	return row;
}

fn backsolve(p: *const params_mod.Params, AT: *spmat.Mat, U: *wrkmat.Mat, S: *sched.Schedule, allocator: std.mem.Allocator) !void {
	var row: i32 = @intCast(p.L - 1);
	while (row >= @as(i32, @intCast(S.i))) : (row -= 1) {
		const cs = &AT.idxs[@intCast(S.c[@intCast(row)])];
		for (cs.items) |del_row_raw| {
			const del_row = @as(usize, @intCast(S.di[del_row_raw]));
			if (del_row < S.i) {
				try S.push(allocator, @intCast(S.d[del_row]), @intCast(S.d[@intCast(row)]), 1);
			}
		}
		for (S.i..@intCast(row)) |del_row| {
			const beta = U.get(@intCast(S.d[del_row]), @intCast(@as(usize, @intCast(row)) - S.i));
			if (beta == 0) continue;
			try S.push(allocator, @intCast(S.d[del_row]), @intCast(S.d[@intCast(row)]), beta);
		}
	}
}

pub fn matrixInvert(allocator: std.mem.Allocator, p: *const params_mod.Params, A: *spmat.Mat) !sched.Schedule {
	var S = try sched.Schedule.init(allocator, A.rows, A.cols, 3 * p.L);
	errdefer S.deinit(allocator);

	matrixSort(p, A, &S);
	var AT = try A.transpose(allocator);
	defer AT.deinit(allocator);

	try matrixPrecond(allocator, p, A, &AT, &S);

	var U = try makeU(allocator, p, A, &AT, &S);
	defer U.deinit(allocator);

	var rank: usize = 0;
	if (A.rows - p.H >= p.L) {
		rank = try solveGF2(p, &U, &S, allocator);
	}
	if (rank < p.L) {
		try fillHDPC(allocator, p, &U, &S);
		rank = try solveGF256(p, &U, &S, allocator);
		if (rank < p.L) return error.RankDeficient;
	}
	S.marks[1] = if (S.ops.items.len == 0) 0 else S.ops.items.len - 1;
	try backsolve(p, &AT, &U, &S, allocator);

	return S;
}

pub fn matrixIntermediate(allocator: std.mem.Allocator, p: *const params_mod.Params, D: *octmat.Mat, S: *sched.Schedule) !void {
	_ = p;
	applySchedule(D, S);
	const rm = try allocator.alloc(i32, S.rows);
	const cm = try allocator.alloc(i32, S.cols);
	defer allocator.free(rm);
	defer allocator.free(cm);
	@memcpy(rm, S.di);
	@memcpy(cm, S.c);
	applyPermute(D, rm);
	applyPermute(D, cm);
}
