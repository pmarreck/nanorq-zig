# Plan

## Goal
Rewrite nanorq core in Zig (no C in the hot path), preserving CLI/bench/report features and adding correctness-focused noise handling, while keeping memory growth bounded and avoiding temp files.

## Done Criteria
- Zig build defaults to Zig core (C core optional/reference only).
- Zig core implements encode/decode with parity + repair, matching existing CLI behavior.
- Tests cover core math (rand/tuple/params), encoder/decoder, noise shapes, and recovery simulation.
- Bench/report suites use Zig core and report throughput + resilience stats.
- Memory use is bounded by input size + configured redundancy (no unbounded max_esi blowups).
- No temp files or disk-backed intermediates in CLI/bench/tests.

## Behaviors + Curiosity Pokes
- [x] Core RNG/tuple/params ported with deterministic tests
	- Curiosity: Are any tables or modulus ranges off-by-one when ported?
- [x] Matrix + precode port (GF(2)/GF(256) ops) with small deterministic tests
	- Curiosity: Mixed GF rows—can we avoid implicit row promotion bugs?
- [x] Encoder/decoder ported with small end-to-end vectors
	- Curiosity: Can encode+decode be wrong in the same way and still pass?
- [x] Noise shaping uses exact indices (normalized/clustered/random) without touching headers/tags by default
	- Curiosity: Are we biasing toward or against edge symbols?
- [x] Bench/report uses Zig core and stays memory-stable under large trials
	- Curiosity: Are we accidentally retaining all trial buffers?
