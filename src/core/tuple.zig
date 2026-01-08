const rand = @import("rand.zig");
const tables = @import("tuple_tables.zig");
const types = @import("types.zig");

pub const Tuple = struct {
	d: u32,
	a: u32,
	b: u32,
	d1: u32,
	a1: u32,
	b1: u32,
};

fn deg(v: u32, w: u16) u32 {
	var d: usize = 0;
	while (d < tables.degree_dist.len) : (d += 1) {
		if (v < tables.degree_dist[d]) {
			const w_minus = if (w > 2) w - 2 else 0;
			return @min(@as(u32, @intCast(d)), @as(u32, w_minus));
		}
	}
	return 0;
}

pub fn genTuple(x: u32, p: *const types.Params) Tuple {
	var ret = Tuple{
		.d = 0,
		.a = 0,
		.b = 0,
		.d1 = 0,
		.a1 = 0,
		.b1 = 0,
	};

	var a: usize = 53591 + @as(usize, p.J) * 997;
	if (a % 2 == 0) a += 1;
	const b1: usize = 10267 * (@as(usize, p.J) + 1);
	const y: u32 = @intCast(b1 + @as(usize, x) * a);
	const v = rand.rndGet(y, 0, 1 << 20);
	ret.d = deg(v, p.W);
	ret.a = 1 + rand.rndGet(y, 1, p.W - 1);
	ret.b = rand.rndGet(y, 2, p.W);
	if (ret.d < 4) {
		ret.d1 = 2 + rand.rndGet(x, 3, 2);
	} else {
		ret.d1 = 2;
	}
	ret.a1 = 1 + rand.rndGet(x, 4, p.P1 - 1);
	ret.b1 = rand.rndGet(x, 5, p.P1);

	return ret;
}
