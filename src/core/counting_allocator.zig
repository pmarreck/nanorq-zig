const std = @import("std");

pub const CountingAllocator = struct {
	child: std.mem.Allocator,
	stats: Stats,

	pub const Stats = struct {
		current: usize = 0,
		peak: usize = 0,
		total_allocated: usize = 0,
		total_freed: usize = 0,
		allocs: usize = 0,
		frees: usize = 0,
		resizes: usize = 0,
		remaps: usize = 0,
	};

	pub fn init(child: std.mem.Allocator) CountingAllocator {
		return .{
			.child = child,
			.stats = .{},
		};
	}

	pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
		return .{
			.ptr = self,
			.vtable = &vtable,
		};
	}

	pub fn snapshot(self: *CountingAllocator) Stats {
		return self.stats;
	}

	fn updatePeak(self: *CountingAllocator) void {
		if (self.stats.current > self.stats.peak) self.stats.peak = self.stats.current;
	}

	fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
		const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
		const ptr = self.child.rawAlloc(len, alignment, ret_addr);
		if (ptr != null) {
			self.stats.allocs += 1;
			self.stats.current += len;
			self.stats.total_allocated += len;
			self.updatePeak();
		}
		return ptr;
	}

	fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
		const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
		const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
		if (ok) {
			self.stats.resizes += 1;
			if (new_len > memory.len) {
				const delta = new_len - memory.len;
				self.stats.current += delta;
				self.stats.total_allocated += delta;
			} else if (memory.len > new_len) {
				const delta = memory.len - new_len;
				self.stats.current -= delta;
				self.stats.total_freed += delta;
			}
			self.updatePeak();
		}
		return ok;
	}

	fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
		const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
		const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr);
		if (ptr != null) {
			self.stats.remaps += 1;
			if (new_len > memory.len) {
				const delta = new_len - memory.len;
				self.stats.current += delta;
				self.stats.total_allocated += delta;
			} else if (memory.len > new_len) {
				const delta = memory.len - new_len;
				self.stats.current -= delta;
				self.stats.total_freed += delta;
			}
			self.updatePeak();
		}
		return ptr;
	}

	fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
		const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
		self.child.rawFree(memory, alignment, ret_addr);
		self.stats.frees += 1;
		if (memory.len > 0) {
			self.stats.current -= memory.len;
			self.stats.total_freed += memory.len;
		}
	}

	const vtable = std.mem.Allocator.VTable{
		.alloc = alloc,
		.resize = resize,
		.remap = remap,
		.free = free,
	};
};
