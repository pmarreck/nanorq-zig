# Bug: build.zig incompatible with Zig 0.15.2

## Summary

`nix build` (and `zig build`) fail because `build.zig` calls `b.markInvalidUserInput()` which is no longer public in Zig 0.15.2.

## Error

```
build.zig:14:5: error: 'markInvalidUserInput' is not marked 'pub'
   b.markInvalidUserInput();
```

## Fix

Remove or replace the `b.markInvalidUserInput()` call in `build.zig:14`. This function was made private in Zig 0.15.x. The typical replacement is to simply delete the call — it was used to mark invalid user input for build options, but the build system now handles this automatically.

## Discovered

2026-04-13 while applying the unified Zig + Nix build pattern across all projects.
