const std = @import("std");
const table = @import("table2.zig");
const tuple = @import("tuple.zig");
const types = @import("types.zig");
pub const Params = types.Params;

fn isPrime(n: u16) bool {
	if (n <= 1) return false;
	if (n <= 3) return true;
	if (n % 2 == 0 or n % 3 == 0) return false;

	var i: u16 = 5;
	while (@as(u32, i) * @as(u32, i) <= n) : (i += 6) {
		if (n % i == 0 or n % (i + 2) == 0) return false;
	}
	return true;
}

pub fn init(k: u16) Params {
	var p = Params{
		.Kprime = 0,
		.S = 0,
		.H = 0,
		.W = 0,
		.L = 0,
		.P = 0,
		.P1 = 0,
		.U = 0,
		.B = 0,
		.J = 0,
	};

	var i: usize = 0;
	while (i < table.K_padded.len) : (i += 1) {
		if (k <= table.K_padded[i]) {
			p.Kprime = table.K_padded[i];
			p.J = table.J_K_padded[i];
			p.S = table.S_H_W[i][0];
			p.H = table.S_H_W[i][1];
			p.W = table.S_H_W[i][2];
			break;
		}
	}

	p.L = p.Kprime + p.S + p.H;
	p.P = p.L - p.W;
	p.U = p.P - p.H;
	p.B = p.W - p.S;
	p.P1 = p.P;
	while (!isPrime(p.P1)) {
		p.P1 += 1;
	}

	return p;
}

pub fn setIdxs(allocator: std.mem.Allocator, x: u32, p: *const Params, dst: *std.ArrayList(u32)) !void {
	const t = tuple.genTuple(x, p);

	try dst.append(allocator, t.b);
	var j: u32 = 1;
	var b = t.b;
	while (j < t.d) : (j += 1) {
		b = (b + t.a) % p.W;
		try dst.append(allocator, b);
	}
	var b1 = t.b1;
	while (b1 >= p.P) {
		b1 = (b1 + t.a1) % p.P1;
	}
	try dst.append(allocator, p.W + b1);

	j = 1;
	while (j < t.d1) : (j += 1) {
		b1 = (b1 + t.a1) % p.P1;
		while (b1 >= p.P) {
			b1 = (b1 + t.a1) % p.P1;
		}
		try dst.append(allocator, p.W + b1);
	}
}
