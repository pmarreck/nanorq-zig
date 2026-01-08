const std = @import("std");

const idx_bits: usize = 32;

pub const Mask = struct {
	words: std.ArrayList(u32),

	pub fn init() Mask {
		return Mask{ .words = std.ArrayList(u32).empty };
	}

	pub fn deinit(self: *Mask, allocator: std.mem.Allocator) void {
		self.words.deinit(allocator);
		self.* = undefined;
	}

	pub fn ensureSize(self: *Mask, allocator: std.mem.Allocator, size: usize) !void {
		const max_idx = (size / idx_bits) + 1;
		while (self.words.items.len < max_idx) {
			try self.words.append(allocator, 0);
		}
	}

	fn ensureIndex(self: *Mask, allocator: std.mem.Allocator, id: usize) !void {
		const idx = id / idx_bits;
		while (self.words.items.len <= idx) {
			try self.words.append(allocator, 0);
		}
	}

	pub fn set(self: *Mask, allocator: std.mem.Allocator, id: usize) void {
		self.ensureIndex(allocator, id) catch return;
		const idx = id / idx_bits;
		const mask: u32 = @as(u32, 1) << @intCast(id % idx_bits);
		self.words.items[idx] |= mask;
	}

	pub fn clear(self: *Mask, allocator: std.mem.Allocator, id: usize) void {
		self.ensureIndex(allocator, id) catch return;
		const idx = id / idx_bits;
		const mask: u32 = @as(u32, 1) << @intCast(id % idx_bits);
		self.words.items[idx] &= ~mask;
	}

	pub fn check(self: *Mask, id: usize) bool {
		const idx = id / idx_bits;
		if (idx >= self.words.items.len) return false;
		const mask: u32 = @as(u32, 1) << @intCast(id % idx_bits);
		return (self.words.items[idx] & mask) != 0;
	}

	pub fn popcount(self: *Mask) usize {
		var count: usize = 0;
		for (self.words.items) |word| {
			count += @popCount(word);
		}
		return count;
	}

	pub fn gaps(self: *Mask, until: usize) usize {
		var count: usize = 0;
		const until_idx = @min((until / idx_bits), self.words.items.len);
		for (0..until_idx) |idx| {
			count += @popCount(~self.words.items[idx]);
		}
		if (until % idx_bits != 0) {
			const mask: u32 = (@as(u32, 1) << @intCast(until % idx_bits)) - 1;
			const idx = until_idx;
			if (idx < self.words.items.len) {
				const target = self.words.items[idx] | ~mask;
				count += @popCount(~target);
			} else {
				count += @popCount(~mask);
			}
		}
		return count;
	}

	pub fn reset(self: *Mask) void {
		@memset(self.words.items, 0);
	}
};
