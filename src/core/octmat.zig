const std = @import("std");
const builtin = @import("builtin");
const gf256 = @import("gf256.zig");

const has_avx2 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

pub fn simdBytes() usize {
	return if (has_avx2) 32 else 16;
}

fn vecLen(comptime VecT: type) usize {
	return @sizeOf(VecT);
}

fn loadVec(comptime VecT: type, ptr: [*]const u8) VecT {
	return @as(*align(1) const VecT, @ptrCast(ptr)).*;
}

fn storeVec(comptime VecT: type, ptr: [*]u8, v: VecT) void {
	@as(*align(1) VecT, @ptrCast(ptr)).* = v;
}

fn addRowVec(comptime VecT: type, dst: []u8, src: []u8) void {
	const len = vecLen(VecT);
	var i: usize = 0;
	while (i + len <= dst.len) : (i += len) {
		const a = loadVec(VecT, dst.ptr + i);
		const b = loadVec(VecT, src.ptr + i);
		storeVec(VecT, dst.ptr + i, a ^ b);
	}
	while (i < dst.len) : (i += 1) {
		dst[i] ^= src[i];
	}
}

fn axpyVec(comptime VecT: type, dst: []u8, src: []u8, beta: u8) void {
	const len = vecLen(VecT);
	var i: usize = 0;
	while (i + len <= dst.len) : (i += len) {
		const src_vec = loadVec(VecT, src.ptr + i);
		const dst_vec = loadVec(VecT, dst.ptr + i);
		storeVec(VecT, dst.ptr + i, dst_vec ^ gf256.mulVecConst(VecT, src_vec, beta));
	}
	while (i < dst.len) : (i += 1) {
		dst[i] ^= gf256.mul(src[i], beta);
	}
}

fn scalVec(comptime VecT: type, row: []u8, beta: u8) void {
	const len = vecLen(VecT);
	var i: usize = 0;
	while (i + len <= row.len) : (i += len) {
		const src_vec = loadVec(VecT, row.ptr + i);
		storeVec(VecT, row.ptr + i, gf256.mulVecConst(VecT, src_vec, beta));
	}
	while (i < row.len) : (i += 1) {
		row[i] = gf256.mul(row[i], beta);
	}
}

pub const align_bytes: usize = 16;

pub fn alignedCols(cols: usize) usize {
	return ((cols + align_bytes - 1) / align_bytes) * align_bytes;
}

pub const Mat = struct {
	rows: usize,
	cols: usize,
	cols_al: usize,
	data: []u8,

	pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Mat {
		const cols_al = alignedCols(cols);
		const data = try allocator.alloc(u8, rows * cols_al);
		@memset(data, 0);
		return Mat{ .rows = rows, .cols = cols, .cols_al = cols_al, .data = data };
	}

	pub fn deinit(self: *Mat, allocator: std.mem.Allocator) void {
		allocator.free(self.data);
		self.* = undefined;
	}

	pub fn resize(self: *Mat, allocator: std.mem.Allocator, rows: usize, cols: usize) !void {
		self.deinit(allocator);
		self.* = try Mat.init(allocator, rows, cols);
	}

	pub fn copyFrom(self: *Mat, allocator: std.mem.Allocator, other: *const Mat) !void {
		if (self.data.len != other.data.len) {
			self.deinit(allocator);
			self.* = try Mat.init(allocator, other.rows, other.cols);
		} else {
			self.rows = other.rows;
			self.cols = other.cols;
			self.cols_al = other.cols_al;
		}
		@memcpy(self.data, other.data);
	}

	pub fn rowSlice(self: *Mat, row: usize) []u8 {
		return self.data[row * self.cols_al .. (row + 1) * self.cols_al];
	}

	pub fn rowSliceConst(self: *const Mat, row: usize) []const u8 {
		return self.data[row * self.cols_al .. (row + 1) * self.cols_al];
	}

	pub fn get(self: *Mat, row: usize, col: usize) u8 {
		if (row >= self.rows or col >= self.cols) return 0;
		return self.rowSlice(row)[col];
	}

	pub fn set(self: *Mat, row: usize, col: usize, val: u8) void {
		if (row >= self.rows or col >= self.cols) return;
		self.rowSlice(row)[col] = val;
	}

	pub fn swapRow(self: *Mat, i: usize, j: usize) void {
		if (i == j or i >= self.rows or j >= self.rows) return;
		const row_i = self.rowSlice(i);
		const row_j = self.rowSlice(j);
		for (row_i, 0..) |*v, idx| {
			const tmp = v.*;
			v.* = row_j[idx];
			row_j[idx] = tmp;
		}
	}

	pub fn swapCol(self: *Mat, i: usize, j: usize) void {
		if (i == j or i >= self.cols or j >= self.cols) return;
		for (0..self.rows) |row| {
			const row_slice = self.rowSlice(row);
			const tmp = row_slice[i];
			row_slice[i] = row_slice[j];
			row_slice[j] = tmp;
		}
	}

	pub fn addRow(self: *Mat, dst: usize, src: usize) void {
		if (dst >= self.rows or src >= self.rows) return;
		const row_d = self.rowSlice(dst);
		const row_s = self.rowSlice(src);
		if (has_avx2) {
			addRowVec(gf256.Vec32, row_d, row_s);
		} else {
			addRowVec(gf256.Vec16, row_d, row_s);
		}
	}

	pub fn axpy(self: *Mat, dst: usize, src: usize, beta: u8) void {
		if (dst >= self.rows or src >= self.rows) return;
		if (beta == 0) return;
		if (beta == 1) return self.addRow(dst, src);
		const row_d = self.rowSlice(dst);
		const row_s = self.rowSlice(src);
		if (has_avx2) {
			axpyVec(gf256.Vec32, row_d, row_s, beta);
		} else {
			axpyVec(gf256.Vec16, row_d, row_s, beta);
		}
	}

	pub fn scalRow(self: *Mat, row: usize, beta: u8) void {
		if (row >= self.rows) return;
		if (beta < 2) return;
		const row_s = self.rowSlice(row);
		if (has_avx2) {
			scalVec(gf256.Vec32, row_s, beta);
		} else {
			scalVec(gf256.Vec16, row_s, beta);
		}
	}

	pub fn zeroRow(self: *Mat, row: usize) void {
		if (row >= self.rows) return;
		const row_s = self.rowSlice(row);
		@memset(row_s[0..self.cols], 0);
	}

	pub fn nnz(self: *Mat, row: usize, start: usize, end: usize) usize {
		if (row >= self.rows or start > end or end > self.cols) return 0;
		const row_s = self.rowSlice(row);
		var count: usize = 0;
		for (start..end) |idx| {
			if (row_s[idx] != 0) count += 1;
		}
		return count;
	}

	pub fn axpyB32(self: *Mat, row: usize, bits: []const u32, beta: u8) void {
		if (row >= self.rows or beta == 0) return;
		const row_s = self.rowSlice(row);
		var idx: usize = 0;
		for (bits, 0..) |word, wi| {
			var tmp = word;
			while (tmp != 0) {
				const tz = @ctz(tmp);
				tmp &= (tmp - 1);
				const pos = tz + wi * 32;
				if (pos >= self.cols) break;
				row_s[pos] ^= beta;
			}
			idx += 32;
		}
	}
};
