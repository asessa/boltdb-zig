const std = @import("std");
const tests = @import("tests.zig");
const consts = @import("consts.zig");
const DB = @import("db.zig").DB;
const TX = @import("tx.zig").TX;
const Error = @import("error.zig").Error;
const defaultOptions = consts.defaultOptions;

// Run with std.testing.allocator; fails if any allocation is leaked at teardown.
// Zig best practice: use the test allocator so leaks are reported automatically.
test "memory no leak on typical workload" {
    std.testing.log_level = .err;
    var test_ctx = try tests.setup(std.testing.allocator);
    defer tests.teardown(&test_ctx);

    const db = test_ctx.db;
    try db.update(struct {
        fn update(trx: *TX) Error!void {
            const b = try trx.createBucket("test");
            for (0..200) |i| {
                var key_buf: [32]u8 = undefined;
                var val_buf: [64]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "k{d}", .{i}) catch unreachable;
                const val = std.fmt.bufPrint(&val_buf, "value{d}", .{i}) catch unreachable;
                try b.put(consts.KeyPair.init(key, val));
            }
        }
    }.update);

    try db.view(struct {
        fn view(trx: *TX) Error!void {
            const b = trx.getBucket("test").?;
            const v = b.get("k0").?;
            std.testing.expect(std.mem.eql(u8, v, "value0")) catch unreachable;
        }
    }.view);
}

// Second workload: more items to ensure no leak under heavier use.
// Uses the same testing allocator; any leak causes test failure at teardown.
test "memory no leak on larger workload" {
    std.testing.log_level = .err;
    var test_ctx = try tests.setup(std.testing.allocator);
    defer tests.teardown(&test_ctx);

    const db = test_ctx.db;
    try db.update(struct {
        fn update(trx: *TX) Error!void {
            const b = try trx.createBucket("b");
            for (0..500) |i| {
                var key_buf: [24]u8 = undefined;
                var val_buf: [48]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
                const val = std.fmt.bufPrint(&val_buf, "val{d}", .{i}) catch unreachable;
                try b.put(consts.KeyPair.init(key, val));
            }
        }
    }.update);

    try db.view(struct {
        fn view(trx: *TX) Error!void {
            const b = trx.getBucket("b").?;
            std.testing.expect(b.get("key0") != null) catch unreachable;
        }
    }.view);
}
