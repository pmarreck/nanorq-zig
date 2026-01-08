const std = @import("std");
const gf2 = @import("gf2.zig");
const octmat = @import("octmat.zig");

pub const Mat = struct {
	gf2: gf2.Mat,
	gf256: ?octmat.Mat,
	rows: usize,
	cols: usize,
	blkidx: usize,
	rowmap: []usize,
	rowtype: []u8,

	pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Mat {
		const gf2m = try gf2.Mat.init(allocator, rows, cols);
		const rowmap = try allocator.alloc(usize, rows);
		const rowtype = try allocator.alloc(u8, rows);
		for (0..rows) |i| {
			rowmap[i] = 0;
			rowtype[i] = 0;
		}
		return Mat{
			.gf2 = gf2m,
			.gf256 = null,
			.rows = rows,
			.cols = cols,
			.blkidx = 0,
			.rowmap = rowmap,
			.rowtype = rowtype,
		};
	}

	pub fn deinit(self: *Mat, allocator: std.mem.Allocator) void {
		self.gf2.deinit(allocator);
		if (self.gf256) |*m| {
			m.deinit(allocator);
		}
		allocator.free(self.rowmap);
		allocator.free(self.rowtype);
		self.* = undefined;
	}

	pub fn assignBlock(self: *Mat, allocator: std.mem.Allocator, block: *octmat.Mat, i: usize, j: usize, m: usize, n: usize) !void {
		_ = j;
		_ = n;
		if (self.gf256) |*existing| {
			existing.deinit(allocator);
		}
		var new_block = try octmat.Mat.init(allocator, block.rows, block.cols);
		try new_block.copyFrom(allocator, block);
		self.gf256 = new_block;

		for (i..i + m) |row| {
			self.rowtype[row] = 1;
			self.rowmap[row] = row - i;
		}
		self.blkidx = m;
	}

	pub fn get(self: *Mat, i: usize, j: usize) u8 {
		if (self.rowtype[i] == 1) {
			return self.gf256.?.get(self.rowmap[i], j);
		}
		return self.gf2.get(i, j);
	}

	pub fn set(self: *Mat, i: usize, j: usize, b: u8) void {
		if (self.rowtype[i] == 1) {
			self.gf256.?.set(self.rowmap[i], j, b);
			return;
		}
		if (b <= 1) {
			self.gf2.set(i, j, b);
		}
	}

	pub fn axpy(self: *Mat, i: usize, j: usize, beta: u8) void {
		if (self.rowtype[i] == self.rowtype[j]) {
			if (self.rowtype[i] == 1) {
				self.gf256.?.axpy(self.rowmap[i], self.rowmap[j], beta);
				self.gf2.xorRow(i, j);
			} else {
				self.gf2.xorRow(i, j);
			}
			return;
		}

		if (self.rowtype[i] == 1) {
			const bits = self.gf2.rowBits(j);
			self.gf256.?.axpyB32(self.rowmap[i], bits, beta);
			return;
		}

		if (self.gf256) |*gf256m| {
			if (self.blkidx >= gf256m.rows) return;
			const row_target = self.blkidx;
			self.blkidx += 1;
			self.gf2.fill(i, gf256m.rowSlice(row_target));
			self.rowtype[i] = 1;
			self.rowmap[i] = row_target;
			gf256m.axpy(self.rowmap[i], self.rowmap[j], beta);
		}
	}

	pub fn scal(self: *Mat, i: usize, beta: u8) void {
		if (self.rowtype[i] == 1) {
			self.gf256.?.scalRow(self.rowmap[i], beta);
		}
	}
};
