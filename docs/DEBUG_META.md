# Debug: meta page invalid (Invalid)

When opening a DB file, if you see **"the meta page is invalid"** and then `error.Invalid`, validation failed at the **magic** check. This doc explains the checks, how to inspect the file, and how boltdb-zig compares to Go bbolt (see `vendor/bbolt`).

---

## 1. Why is the meta page considered invalid?

Validation runs in `src/db.zig` in `Meta.validate()` (and during `open` → `mmap`). The order of checks is:

| Order | Check | Error if fail |
|-------|--------|----------------|
| 1 | `magic == 0xED0CDAED` | **Invalid** |
| 2 | `version == 2` | VersionMismatch |
| 3 | `checksum == 0` **or** `checksum == sum64()` | CheckSum |

So **Invalid** means: the 4 bytes at the **meta magic** position (see layout below) are not `0xED0CDAED`. Common causes:

- File is not a Bolt DB (wrong format, or corrupt).
- File was written with a different page size and we're reading the wrong “page” (unlikely if you use default page size and the file has standard 4K pages).
- First 4K of the file are not the first meta page (e.g. custom header, truncation).

---

## 2. Layout (must match bbolt)

- **Page header:** first 16 bytes of each page: `id` (8), `flags` (2), `count` (2), `overflow` (4).
- **Meta** starts at byte **16** of page 0 (right after the page header). Layout (same as `vendor/bbolt/internal/common/meta.go`):

| Offset (in page) | Field    | Type  | Notes                    |
|------------------|----------|-------|--------------------------|
| 0                | magic    | u32   | Must be `0xED0CDAED`     |
| 4                | version  | u32   | Must be `2`              |
| 8                | pageSize | u32   | e.g. 4096                |
| 12               | flags    | u32   |                          |
| 16               | root     | u64   | root bucket page id      |
| 24               | sequence | u64   |                          |
| 32               | freelist | u64   |                          |
| 40               | pgid     | u64   | high water mark          |
| 48               | txid     | u64   |                          |
| 56               | checksum | u64   | see Checksum below       |

So in the **file**, for page size 4096, the magic is at **file offset 16**.

---

## 3. Checksum: boltdb-zig vs bbolt (Go)

- **bbolt (Go)** `internal/common/meta.go`: uses **FNV-1a 64-bit** (`hash/fnv`, `Sum64()` over the meta bytes before `checksum`).
- **boltdb-zig** `src/db.zig` `Meta.sum64()`: uses **CRC32** and then casts to `u64`.

So the **on-disk checksum** written by Go will not match what Zig computes. For a Go-created DB you can still get **Invalid** (magic) or **VersionMismatch** (version) first; if magic and version pass, Zig would then fail with **CheckSum** when the stored checksum is non-zero. Fixing compatibility would require implementing FNV-1a 64 in Zig for meta checksum (and using it in both read and write).

---

## 4. How to debug the file locally

### Option A: Script Zig (no build) – dump first page and magic/version

Run from repo root (pass the DB path as first argument):

```bash
zig run scripts/debug_meta.zig -- database.db
```

This prints the first 128 bytes in hex and the magic/version at meta offset 16.

### Option B: Open with bbolt and print meta

From the repo root, with `vendor/bbolt` present:

```bash
cd vendor/bbolt
go run ./cmd/bbolt/main.go info /path/to/database.db
```

Or write a small Go program that opens the file with `bbolt.Open()` and prints `db.Meta()` (or use `internal/guts_cli.GetActiveMetaPage`). That shows what bbolt thinks the meta is; you can compare with what the Zig script reads.

### Option C: Hex dump first 4K

```bash
xxd -l 4096 database.db
```

Check bytes at offset 0x10–0x13: they should be `ed 0c da ed` (little-endian `0xED0CDAED`). If not, the file is not a valid Bolt meta page at that position (or not Bolt at all).

---

## 5. Recovery / best practices

- If validation fails (Invalid / VersionMismatch / CheckSum), the file should be treated as **not openable** by this library in its current form.
- **Safe approach:** catch `db.Error.Invalid` (and other open errors), rename the existing file (e.g. to `database.db.bak`), and create a new DB; document this for users.
- **Data recovery:** if the file might be a valid Bolt DB from another implementation (e.g. bbolt), try opening it with that implementation first; if it opens, re-export data and re-import into a boltdb-zig-created DB if needed.

---

## 6. Reference: vendor/bbolt

- **Meta struct:** `vendor/bbolt/internal/common/meta.go`
- **Page header / Meta():** `vendor/bbolt/internal/common/page.go` (`PageHeaderSize`, `p.Meta()`)
- **Constants:** `vendor/bbolt/internal/common/types.go` (`Magic`, `Version`)
- **Validation:** `meta.Validate()` in `meta.go` (magic, version, checksum)
- **Checksum:** `meta.Sum64()` uses `fnv.New64a()` (FNV-1a 64-bit)
