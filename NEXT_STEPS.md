# Next Steps

- Run `zig build -Doptimize=ReleaseFast bench -- --mem-profile --mem-iterations 25 --mem-warmup 5` and inspect growth deltas.
- If memory still spikes, capture which phase grows (encode vs. decode vs. noise) with targeted allocator scopes.
- Decide whether to keep memory profile in bench output or split into a dedicated subcommand.
