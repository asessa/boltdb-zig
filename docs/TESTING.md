# Testing in boltdb-zig

## Running tests

- **All tests:** `zig test src/root.zig` (or `zig build test` if the build is wired to use `root.zig`)
- **Single test:** `zig test src/root.zig --test-filter "memory"`

## Zig testing best practices (as applied here)

1. **Use `std.testing.allocator` for tests that allocate**
   - The test allocator tracks allocations and **reports leaks** when the test ends. If anything is still allocated, the test fails.
   - Use it for DB, buckets, and any heap-allocated state so that leaks are caught automatically.

2. **Assert with `std.testing.expect` / `expectEqual`**
   - Prefer `try std.testing.expect(condition)` and `try std.testing.expectEqual(expected, actual)`.
   - Note: `expectEqual(expected, actual)` in Zig is (expected, actual); put the expected value first.
   - Inside callbacks that must return a different error set (e.g. DB’s `Error`), use `std.testing.expect(...) catch unreachable` so the callback’s return type stays correct.

3. **Test layout**
   - Tests live in `*_test.zig` files and are pulled in via `src/root.zig` with `_ = @import("memory_test.zig");` etc.
   - Use `tests.setup(std.testing.allocator)` and `defer tests.teardown(&test_ctx)` so the DB and temp file are cleaned up and the test allocator can check for leaks.

4. **Memory and allocation**
   - **Leak checks:** Run a workload (e.g. open DB, create bucket, put items, close) under `std.testing.allocator` and teardown; leaks will fail the test.
   - **“Cost too much”:** Indirectly covered by leak tests (leaks would grow without bound). For an explicit allocation cap you could add a counting/failing allocator or run tests under a memory limit (e.g. `ulimit`).

5. **Logging in tests**
   - Set `std.testing.log_level = .err` (or `.warn`) at the start of a test to reduce noise from the library.

6. **Debug: print meta pages**
   - By default, opening a DB in tests does **not** print the meta table (to keep output clean and tests faster). To print meta pages on every open, set the env var `ZIG_DEBUG_BOLT_META=1` when running tests.

7. **Temporary files**
   - Use `tests.createTmpFile()` and `tmp_file.path(allocator)` for a temp DB path; close the file and pass the path to `DB.open`. Teardown deletes the file.

## Memory tests

- **`memory no leak on typical workload`** – Open DB, create bucket, put 200 items, read back; teardown. Fails if any allocation is leaked.
- **`memory no leak on larger workload`** – Same pattern with 500 items to stress a bit more; ensures no leak under heavier use.

Both rely on Zig’s test allocator to detect leaks, which is the recommended way to keep allocation cost under control in Zig tests.
