# Using boltdb-zig

Minimal documentation for using the boltdb-zig library from Zig. The public API lives in `namespace.zig` and is imported as the `boltdb` module.

## Dependency and build

Add the dependency in `build.zig.zon` (path or repo URL). In `build.zig`:

```zig
const boltdbDep = b.dependency("boltdb-zig", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("boltdb", boltdbDep.module("boltdb"));
```

In your code:

```zig
const db = @import("boltdb");
```

## Opening and closing the database

```zig
var database = try db.Database.open(allocator, "mydb.bolt", null, db.defaultOptions);
defer database.close() catch unreachable;
```

- **`Database.open(allocator, path, fileMode, options)`** – Creates or opens the DB file. `fileMode` can be `null`. Use `db.defaultOptions` for default options.
- **`database.close()`** – Closes the DB and releases resources. Call it (e.g. with `defer`) when you are done.

## Transactions

All reads and writes happen inside transactions. Two patterns:

### 1. Managed transactions: `update` and `view`

**Write** – Your function runs in a read-write transaction; on success the transaction is committed, otherwise it is rolled back:

```zig
try database.update(struct {
    fn exec(trans: *db.Transaction) db.Error!void {
        var bucket = try trans.createBucketIfNotExists("my_bucket");
        try bucket.put("key", "value");
    }
}.exec);
```

**Read** – Read-only transaction; you cannot modify data:

```zig
try database.view(struct {
    fn view(trans: *db.Transaction) db.Error!void {
        var bucket = trans.bucket("my_bucket").?;
        const value = bucket.get("key").?;
        // use value (valid only for the lifetime of the transaction)
    }
}.view);
```

Context variants exist: `updateWithContext(ctx, fn)` and `viewWithContext(ctx, fn)`.

### 2. Manual transactions: `begin` / `commit` / `rollback`

To control transaction start and end explicitly:

```zig
// Write
var trans = try database.begin(true);  // true = writable
defer trans.rollback() catch unreachable;
var bucket = try trans.createBucketIfNotExists("user");
try bucket.put("hello", "world");
try trans.commit();  // defer rollback is skipped

// Read
var transRO = try database.begin(false);  // false = read-only
defer transRO.rollback() catch unreachable;
var bucketRO = transRO.bucket("user").?;
const value = bucketRO.get("hello").?;
// use value; then rollback (or commit for writable) when done
```

- **`begin(writable)`** – `true` = read-write, `false` = read-only.
- **`commit()`** – Commits and closes the transaction (writable only).
- **`rollback()`** – Rolls back and closes the transaction.

Important: every transaction opened with `begin` must be closed with `commit` or `rollback` (typically via `defer`).

## Buckets

Buckets are containers of key–value pairs (and optional sub-buckets). Bucket names are strings.

- **`trans.createBucketIfNotExists("name")`** – Creates the bucket if it does not exist; returns the bucket.
- **`trans.createBucket("name")`** – Creates the bucket; errors if it already exists.
- **`trans.bucket("name")`** – Returns the bucket if it exists, otherwise `null`.

On a bucket:

- **`bucket.put(key, value)`** – Writes a key/value pair (both `[]const u8`). Overwrites if the key exists.
- **`bucket.get(key)`** – Returns the value for `key`, or `null` if missing or if the key is a sub-bucket.
- **`bucket.delete(key)`** – Removes the key (writable transaction only).
- **`bucket.cursor()`** – Creates a cursor for iteration (see below).
- **`bucket.bucket("name")`** – Returns a sub-bucket by name, or `null`.
- **`bucket.createBucket("name")`** / **`createBucketIfNotExists("name")`** – Creates a sub-bucket.

Values returned by `get` are valid only for the lifetime of the transaction.

### Listing bucket names

There is no dedicated “list buckets” API. To get the names of top-level buckets, open a read-only transaction, create a cursor from the transaction (root), and iterate; when `keyPair.isBucket()` is true, `keyPair.key.?` is the bucket name:

```zig
try database.view(struct {
    fn view(trans: *db.Transaction) db.Error!void {
        var cursor = trans.cursor();
        defer cursor.deinit();
        var keyPair = cursor.first();
        while (!keyPair.isNotFound()) {
            if (keyPair.isBucket()) {
                // keyPair.key.? is a bucket name
                std.log.info("bucket: {s}", .{keyPair.key.?});
            }
            // else: root-level key-value pair (less common)
            keyPair = cursor.next();
        }
    }
}.view);
```

To list sub-buckets inside a bucket, use a cursor on that bucket (or `bucket.forEach`) and again treat entries with `keyPair.isBucket()` (or `value == null` in forEach) as bucket names.

### Listing all keys

**All keys in one bucket** – Use a cursor on that bucket (or `bucket.forEach`). With a cursor, iterate with `first()` / `next()` and skip bucket entries if you only want key-value pairs:

```zig
try database.view(struct {
    fn view(trans: *db.Transaction) db.Error!void {
        var bucket = trans.bucket("my_bucket") orelse return;
        var cursor = bucket.cursor();
        defer cursor.deinit();
        var keyPair = cursor.first();
        while (!keyPair.isNotFound()) {
            if (!keyPair.isBucket()) {
                std.log.info("key: {s} -> value: {s}", .{ keyPair.key.?, keyPair.value.? });
            }
            keyPair = cursor.next();
        }
    }
}.view);
```

**All keys in the whole database at startup** – Walk the root cursor: for each item, if it’s a bucket (`keyPair.isBucket()`), open the bucket and iterate its keys (and optionally recurse into sub-buckets); otherwise it’s a root-level key-value pair. Example that prints every key (and value) in every top-level bucket:

```zig
try database.view(struct {
    fn view(trans: *db.Transaction) db.Error!void {
        var root_cursor = trans.cursor();
        defer root_cursor.deinit();
        var keyPair = root_cursor.first();
        while (!keyPair.isNotFound()) {
            if (keyPair.isBucket()) {
                var bucket = trans.bucket(keyPair.key.?).?;
                var sub = bucket.cursor();
                defer sub.deinit();
                var kv = sub.first();
                while (!kv.isNotFound()) {
                    if (!kv.isBucket()) {
                        std.log.info("[{s}] {s} = {s}", .{ keyPair.key.?, kv.key.?, kv.value.? });
                    }
                    kv = sub.next();
                }
            }
            keyPair = root_cursor.next();
        }
    }
}.view);
```

For nested buckets, repeat the same pattern: when you see a bucket, open it and iterate its cursor (and recurse if you need keys inside sub-buckets).

## Cursors

Cursors let you iterate over key–value pairs in lexicographic key order. You get one from a transaction (root) or from a bucket:

```zig
var cursor = trans.cursor();        // root: iterates over all root-level buckets and keys
// or
var cursor = bucket.cursor();       // only keys/values (and sub-buckets) in that bucket
defer cursor.deinit();
```

Main methods:

- **`cursor.first()`** – First pair; returns a `KeyPair` (`key`, `value`). If it is a bucket, `value` is `null`.
- **`cursor.next()`** – Next pair.
- **`cursor.last()`** – Last pair.
- **`cursor.prev()`** – Previous pair.
- **`cursor.seek(key)`** – Moves to the given key (or the next one if it does not exist).
- **`cursor.delete()`** – Deletes the current pair (writable transaction only).

On `KeyPair`:

- **`keyPair.isNotFound()`** – `true` when there is no key (e.g. end of iteration).
- **`keyPair.isBucket()`** – `true` when the current item is a bucket (then `value` is `null`).

Forward iteration example:

```zig
var keyPair = cursor.first();
while (!keyPair.isNotFound()) {
    if (keyPair.isBucket()) {
        // keyPair.key.? is the bucket name
    } else {
        // keyPair.key.? and keyPair.value.? are key and value
    }
    keyPair = cursor.next();
}
```

For reverse iteration, start with `cursor.last()` and use `cursor.prev()` in the loop.

Always call `cursor.deinit()` when the cursor is no longer needed (e.g. with `defer`).

## Iterating a bucket with `forEach`

You can also use `forEach` (and `forEachWithContext`) on a bucket instead of a cursor:

```zig
try bucket.forEach(struct {
    fn exec(bt: *db.Bucket, key: []const u8, value: ?[]const u8) db.Error!void {
        if (value == null) {
            // key is a sub-bucket
        } else {
            // key and value are the key-value pair
        }
    }
}.exec);
```

## Open options

`db.defaultOptions` uses sensible defaults. With `db.Options` (or `consts.Options`) you can set for example:

- **`readOnly`** – Open in read-only mode.
- **`initialMmapSize`** – Initial mmap size (to reduce writer blocking with long-lived readers).
- **`pageSize`** – Page size (for testing only, not in production).
- **`noGrowSync`**, **`strictMode`**, **`mmapFlags`** – Advanced options (see `consts.zig`).

## Other useful methods

- **`database.path()`** – Path of the open DB file.
- **`database.sync()`** – Syncs the file to disk.
- **`database.isReadOnly()`** – Whether the DB was opened read-only.
- **`trans.stats()`** – Transaction statistics.
- **`bucket.stats()`** – Bucket statistics.
- **`bucket.nextSequence()`** – Auto-increment counter for the bucket (useful for unique IDs).
- **`bucket.setSequence(v)`** – Sets the sequence value.

## Notes

- Keys and values are byte strings (`[]const u8`); encoding (e.g. UTF-8) is up to your application.
- Data returned by `get` and cursors is valid **only** for the lifetime of the transaction.
- In a writable transaction you can create buckets, `put`, `delete`, and use `cursor.delete()`. In read-only you can only read and iterate.
- For tests and development you can use `std.testing.allocator` and temporary files; in production ensure you call `close()` (and optionally `sync()`) and use transactions consistently (commit/rollback).

For full examples see `example/src/main.zig` and the tests in `src/*_test.zig` (e.g. `ExampleDB_Update`, `ExampleDB_View`, `ExampleCursor`).
