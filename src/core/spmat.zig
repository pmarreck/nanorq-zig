const std = @import("std");

pub const Mat = struct {
	rows: usize,
	cols: usize,
	idxs: []std.ArrayList(u32),

	pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Mat {
		const idxs = try allocator.alloc(std.ArrayList(u32), rows);
		for (idxs) |*list| {
			list.* = std.ArrayList(u32).empty;
			try list.ensureTotalCapacity(allocator, 10);
		}
		return Mat{ .rows = rows, .cols = cols, .idxs = idxs };
	}

	pub fn deinit(self: *Mat, allocator: std.mem.Allocator) void {
		for (self.idxs) |*list| {
			list.deinit(allocator);
		}
		allocator.free(self.idxs);
		self.* = undefined;
	}

	pub fn clearRow(self: *Mat, row: usize) void {
		if (row >= self.rows) return;
		self.idxs[row].clearRetainingCapacity();
	}

	pub fn push(self: *Mat, allocator: std.mem.Allocator, row: usize, col: u32) !void {
		if (row >= self.rows) return;
		try self.idxs[row].append(allocator, col);
	}

	pub fn transpose(self: *Mat, allocator: std.mem.Allocator) !Mat {
		var t = try Mat.init(allocator, self.cols, self.rows);
		for (self.idxs, 0..) |list, r| {
			for (list.items) |c| {
				try t.push(allocator, c, @intCast(r));
			}
		}
		return t;
	}

	pub fn nnz(self: *Mat, row: usize, start: usize, end: usize) usize {
		if (row >= self.rows or start > end or end > self.cols) return 0;
		var count: usize = 0;
		for (self.idxs[row].items) |col| {
			if (col >= start and col < end) count += 1;
		}
		return count;
	}
};
