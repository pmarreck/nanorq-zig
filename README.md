# nanorq
nanorq is a compact, performant Zig implementation of the raptorq fountain code capable of reaching multi-gigabit speeds on a single core.

nanorq provides flexible I/O handling, wrappers are provided for memory buffers, mmap (zero copy) and streams. Additional abstractions can be implemented without interacting with the decoder logic.

# Performance
![](graph.png)

# Use cases
- firmware deployment / software updates
- video streaming
- large data transfers across high latency links

## Zig build
- Enter the dev shell: `nix develop -c <command>`
- Build CLI: `zig build`
- Run CLI: `zig build run -- <encode|decode|noise|simulate> ...`
- Run tests: `zig build test` (or `zig test src/tests.zig`)
- Run bench: `zig build bench -- --help`

## CPU model + SIMD
- Portable CPU model: `zig build -Dcpu-model=baseline` (alias: `-Dcpu=baseline`)
- Host-tuned CPU model: `zig build -Dcpu-model=native` (alias: `-Dcpu=native`)
- SIMD dispatch is selected at runtime (AVX2 vs. 16-byte vectors) and reported by `bench --micro`
- AVX2 runtime dispatch only works if the binary was built with AVX2 enabled (e.g., `-Dcpu=native` on an AVX2 host)

## Legacy
- The `Makefile` targets the legacy C implementation and is not used by the Zig build.

## Zig build
- Portable CPU model: `zig build -Dcpu-model=baseline` (alias: `-Dcpu=baseline`)
- Host-tuned CPU model: `zig build -Dcpu-model=native` (alias: `-Dcpu=native`)
- SIMD dispatch is selected at runtime; AVX2 requires building with AVX2 enabled
