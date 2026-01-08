const tables = @import("rand_tables.zig");

pub fn rndGet(y: u32, i: u8, m: u32) u32 {
	const x0: u8 = @truncate(y + i);
	const x1: u8 = @truncate((y >> 8) + i);
	const x2: u8 = @truncate((y >> 16) + i);
	const x3: u8 = @truncate((y >> 24) + i);

	const v = tables.V0[x0] ^ tables.V1[x1] ^ tables.V2[x2] ^ tables.V3[x3];
	return v % m;
}
