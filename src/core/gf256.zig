const tables = @import("oct_tables.zig");

pub fn add(a: u8, b: u8) u8 {
	return a ^ b;
}

pub fn mul(a: u8, b: u8) u8 {
	if (a == 0 or b == 0) return 0;
	const la: u16 = tables.OCT_LOG[a];
	const lb: u16 = tables.OCT_LOG[b];
	const idx: usize = @intCast(la + lb);
	return tables.OCT_EXP[idx];
}

pub fn inv(a: u8) u8 {
	return tables.OCT_INV[a];
}

pub fn div(a: u8, b: u8) u8 {
	if (a == 0) return 0;
	if (b == 0) return 0;
	const la: i16 = @intCast(tables.OCT_LOG[a]);
	const lb: i16 = @intCast(tables.OCT_LOG[b]);
	var diff: i16 = la - lb;
	if (diff < 0) diff += 255;
	return tables.OCT_EXP[@intCast(diff)];
}
