const tables = @import("oct_tables.zig");

pub const Vec = @Vector(16, u8);

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

fn xtimeVec(v: Vec) Vec {
	const shift = @as(Vec, @splat(@as(u8, 1)));
	const carry = v >> @as(Vec, @splat(@as(u8, 7)));
	const shifted = v << shift;
	const mask = carry * @as(Vec, @splat(@as(u8, 0x1d)));
	return shifted ^ mask;
}

pub fn mulVecConst(v: Vec, b: u8) Vec {
	if (b == 0) return @splat(@as(u8, 0));
	if (b == 1) return v;
	var res: Vec = @splat(@as(u8, 0));
	var cur = v;
	var beta = b;
	while (beta != 0) : (beta >>= 1) {
		if ((beta & 1) != 0) {
			res ^= cur;
		}
		cur = xtimeVec(cur);
	}
	return res;
}
