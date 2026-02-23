// Standalone script to dump the first meta page of a Bolt DB file and run
// validation steps. Run from repo root: zig run scripts/debug_meta.zig -- database.db
const std = @import("std");

const Magic: u32 = 0xED0CDAED;
const Version: u32 = 2;

// Meta layout (after 16-byte page header): magic, version, pageSize, flags,
// root(u64), sequence(u64), freelist(u64), pgid(u64), txid(u64), checksum(u64)
const META_OFF = 16;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        std.debug.print("Usage: zig run scripts/debug_meta.zig -- <path_to_db>\n", .{});
        std.process.exit(1);
    }
    const path = args[1];

    const file = std.fs.cwd().openFile(path, .{}) catch |e| {
        std.debug.print("open failed: {}\n", .{e});
        std.process.exit(1);
    };
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = try file.readAll(buf[0..]);
    std.debug.print("read {} bytes from {s}\n\n", .{ n, path });

    // Dump first 128 bytes
    std.debug.print("First 128 bytes (hex):\n", .{});
    var i: usize = 0;
    while (i < 128 and i < n) : (i += 16) {
        const len = @min(16, n - i);
        std.debug.print("{x:0>4}: ", .{i});
        for (buf[i .. i + len]) |b| std.debug.print("{x:0>2} ", .{b});
        std.debug.print("\n", .{});
    }

    if (n < META_OFF + 8) {
        std.debug.print("\nfile too short to read meta (need at least {} bytes)\n", .{META_OFF + 8});
        return;
    }

    const meta = buf[META_OFF..];
    const magic = std.mem.readInt(u32, meta[0..4], .little);
    const version = std.mem.readInt(u32, meta[4..8], .little);
    const page_size = std.mem.readInt(u32, meta[8..12], .little);
    const checksum = if (meta.len >= 64) std.mem.readInt(u64, meta[56..64], .little) else 0;

    std.debug.print("\nMeta (at file offset {}):\n", .{META_OFF});
    std.debug.print("  magic     = 0x{x:0>8}  (expected 0x{x:0>8})  {s}\n", .{
        magic,
        Magic,
        if (magic == Magic) "OK" else "FAIL -> Invalid",
    });
    std.debug.print("  version   = {}         (expected {})         {s}\n", .{
        version,
        Version,
        if (version == Version) "OK" else "FAIL -> VersionMismatch",
    });
    std.debug.print("  pageSize  = {}\n", .{page_size});
    std.debug.print("  checksum  = 0x{x:0>16}\n", .{checksum});

    if (magic != Magic) {
        std.debug.print("\n=> Validation would return Invalid (magic mismatch).\n", .{});
    } else if (version != Version) {
        std.debug.print("\n=> Validation would return VersionMismatch.\n", .{});
    } else {
        std.debug.print("\n=> Magic and version OK. Checksum is not verified by this script (see docs/DEBUG_META.md).\n", .{});
    }

    // Second meta page (page 1) at offset 4096 + 16
    const page1_off: usize = 4096 + META_OFF;
    if (n >= page1_off + 8) {
        const meta1 = buf[page1_off..];
        const magic1 = std.mem.readInt(u32, meta1[0..4], .little);
        const version1 = std.mem.readInt(u32, meta1[4..8], .little);
        std.debug.print("\nMeta page 1 (at file offset {}):\n", .{page1_off});
        std.debug.print("  magic   = 0x{x:0>8}  (expected 0x{x:0>8})  {s}\n", .{
            magic1,
            Magic,
            if (magic1 == Magic) "OK" else "FAIL -> Invalid",
        });
        std.debug.print("  version = {}         (expected {})         {s}\n", .{
            version1,
            Version,
            if (version1 == Version) "OK" else "FAIL -> VersionMismatch",
        });
    }
}
