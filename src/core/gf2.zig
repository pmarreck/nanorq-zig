const std = @import("std");

pub const Mat = struct {
	rows: usize,
	cols: usize,
	stride: usize,
	bits: []u32,

	pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Mat {
		const stride = (cols + 31) / 32;
		const bits = try allocator.alloc(u32, stride * rows);
		@memset(bits, 0);
		return Mat{ .rows = rows, .cols = cols, .stride = stride, .bits = bits };
	}

	pub fn deinit(self: *Mat, allocator: std.mem.Allocator) void {
		allocator.free(self.bits);
		self.* = undefined;
	}

	fn rowSlice(self: *Mat, i: usize) []u32 {
		return self.bits[i * self.stride .. (i + 1) * self.stride];
	}

	pub fn rowBits(self: *Mat, i: usize) []u32 {
		return self.rowSlice(i);
	}

	pub fn get(self: *Mat, i: usize, j: usize) u8 {
		if (i >= self.rows or j >= self.cols) return 0;
		const row = self.rowSlice(i);
		const idx = j / 32;
		const bit: u32 = @as(u32, 1) << @intCast(j % 32);
		return if ((row[idx] & bit) != 0) 1 else 0;
	}

	pub fn set(self: *Mat, i: usize, j: usize, b: u8) void {
		if (i >= self.rows or j >= self.cols) return;
		const row = self.rowSlice(i);
		const idx = j / 32;
		const bit: u32 = @as(u32, 1) << @intCast(j % 32);
		if (b != 0) {
			row[idx] |= bit;
		} else {
			row[idx] &= ~bit;
		}
	}

	pub fn xorRow(self: *Mat, i: usize, j: usize) void {
		if (i >= self.rows or j >= self.rows) return;
		const row_i = self.rowSlice(i);
		const row_j = self.rowSlice(j);
		for (row_i, 0..) |*word, idx| {
			word.* ^= row_j[idx];
		}
	}

	pub fn andRow(self: *Mat, i: usize, j: usize) void {
		if (i >= self.rows or j >= self.rows) return;
		const row_i = self.rowSlice(i);
		const row_j = self.rowSlice(j);
		for (row_i, 0..) |*word, idx| {
			word.* &= row_j[idx];
		}
	}

	pub fn swapRow(self: *Mat, i: usize, j: usize) void {
		if (i == j or i >= self.rows or j >= self.rows) return;
		const row_i = self.rowSlice(i);
		const row_j = self.rowSlice(j);
		for (row_i, 0..) |*word, idx| {
			const tmp = word.*;
			word.* = row_j[idx];
			row_j[idx] = tmp;
		}
	}

	pub fn swapCol(self: *Mat, i: usize, j: usize) void {
		if (i == j or i >= self.cols or j >= self.cols) return;
		for (0..self.rows) |row| {
			const a = self.get(row, i);
			const b = self.get(row, j);
			self.set(row, i, b);
			self.set(row, j, a);
		}
	}

	pub fn zeroRow(self: *Mat, i: usize) void {
		if (i >= self.rows) return;
		@memset(self.rowSlice(i), 0);
	}

	pub fn axpy(self: *Mat, row: usize, dst: []u8, beta: u8) void {
		if (row >= self.rows or beta == 0) return;
		const row_s = self.rowSlice(row);
		for (row_s, 0..) |word, wi| {
			var tmp = word;
			while (tmp != 0) {
				const tz: usize = @intCast(@ctz(tmp));
				tmp &= tmp - 1;
				const pos = tz + wi * 32;
				if (pos >= self.cols or pos >= dst.len) continue;
				dst[pos] ^= beta;
			}
		}
	}

	pub fn fill(self: *Mat, row: usize, dst: []u8) void {
		if (row >= self.rows) return;
		const row_s = self.rowSlice(row);
		for (row_s, 0..) |word, wi| {
			var tmp = word;
			while (tmp != 0) {
				const tz: usize = @intCast(@ctz(tmp));
				tmp &= tmp - 1;
				const pos = tz + wi * 32;
				if (pos >= self.cols or pos >= dst.len) continue;
				dst[pos] = 1;
			}
		}
	}

	pub fn nnz(self: *Mat, row: usize, start: usize, end: usize) usize {
		if (row >= self.rows or start > end or end > self.cols) return 0;
		var count: usize = 0;
		for (start..end) |col| {
			count += self.get(row, col);
		}
		return count;
	}
};
