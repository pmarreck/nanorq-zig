const std = @import("std");

pub const Op = struct {
	beta: u8,
	i: u32,
	j: u32,
};

pub const Schedule = struct {
	rows: usize,
	cols: usize,
	c: []i32,
	d: []i32,
	ci: []i32,
	di: []i32,
	nz: []u32,
	ops: std.ArrayList(Op),
	i: usize,
	u: usize,
	marks: [2]usize,

	pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize, estimated_ops: usize) !Schedule {
		const c = try allocator.alloc(i32, cols);
		const ci = try allocator.alloc(i32, cols);
		const d = try allocator.alloc(i32, rows);
		const di = try allocator.alloc(i32, rows);
		const nz = try allocator.alloc(u32, rows);
		for (0..cols) |j| {
			c[j] = @intCast(j);
			ci[j] = @intCast(j);
		}
		for (0..rows) |r| {
			d[r] = @intCast(r);
			di[r] = @intCast(r);
			nz[r] = 0;
		}
		var ops = std.ArrayList(Op).empty;
		try ops.ensureTotalCapacity(allocator, estimated_ops);
		return Schedule{
			.rows = rows,
			.cols = cols,
			.c = c,
			.d = d,
			.ci = ci,
			.di = di,
			.nz = nz,
			.ops = ops,
			.i = 0,
			.u = 0,
			.marks = .{ 0, 0 },
		};
	}

	pub fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
		allocator.free(self.c);
		allocator.free(self.d);
		allocator.free(self.ci);
		allocator.free(self.di);
		allocator.free(self.nz);
		self.ops.deinit(allocator);
		self.* = undefined;
	}

	pub fn push(self: *Schedule, allocator: std.mem.Allocator, i: u32, j: u32, beta: u8) !void {
		try self.ops.append(allocator, Op{ .i = i, .j = j, .beta = beta });
	}
};
