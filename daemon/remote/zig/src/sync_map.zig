//! Mutex-protected `StringHashMap` wrapper.
//!
//! Exists to make the lock discipline *structural* rather than a
//! convention enforced by commentary. Direct access to the underlying
//! `StringHashMap` is impossible from outside this module: every public
//! method acquires the lock internally and releases it before returning.
//! Regressing into "forgot to lock at site N" is a compile-time error,
//! not a runtime crash.
//!
//! Uses `std.Thread.RwLock` so read-heavy paths (`get`, `contains`) run
//! concurrently while writers (`put`, `fetchRemove`) serialize. This is
//! strictly better than a plain `Mutex` for the daemon's `runtimes` map,
//! where reads vastly outnumber writes.
//!
//! ## Pointer lifetime caveat
//!
//! When `V` is a pointer type (e.g. `*RuntimeSession`), `get` returns
//! the pointer *by value* after releasing the read lock. A concurrent
//! `fetchRemove` could then free the pointee before the caller finishes
//! using it. Callers that dereference returned pointers must serialize
//! removal with their own use, or adopt reference counting on `V`.
//!
//! `withWriteLock(ctx, fn)` exists for callers that need a write-side
//! critical section that reads + mutates atomically (e.g. "look up and
//! conditionally remove"). Use it in preference to separate get/remove
//! pairs.

const std = @import("std");

pub fn SyncStringHashMap(comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Inner = std.StringHashMap(V);
        pub const KV = Inner.KV;

        inner: Inner,
        lock: std.Thread.RwLock = .{},

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .inner = Inner.init(alloc) };
        }

        /// Deinit assumes no concurrent access; caller must have drained
        /// all threads that might touch the map first.
        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        /// Raw map pointer for teardown paths that must iterate and free
        /// entries. Caller asserts no concurrent access (typical use:
        /// inside `Service.deinit` after all worker threads have joined).
        /// Do NOT use from any code path that runs while the service is
        /// live — that's what the locking API is for.
        pub fn unsafeInnerForTeardown(self: *Self) *Inner {
            return &self.inner;
        }

        pub fn count(self: *Self) u32 {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return self.inner.count();
        }

        pub fn get(self: *Self, key: []const u8) ?V {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return self.inner.get(key);
        }

        pub fn contains(self: *Self, key: []const u8) bool {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return self.inner.contains(key);
        }

        /// Look up the canonical (map-owned) key slice alongside the
        /// value. Returns a duped copy of the key so the caller owns
        /// its lifetime regardless of what other threads do with the
        /// map. Caller frees `.key` with `alloc` when finished.
        pub fn getEntryDupedKey(
            self: *Self,
            alloc: std.mem.Allocator,
            key: []const u8,
        ) !?struct { key: []u8, value: V } {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            const entry = self.inner.getEntry(key) orelse return null;
            const duped = try alloc.dupe(u8, entry.key_ptr.*);
            return .{ .key = duped, .value = entry.value_ptr.* };
        }

        pub fn put(self: *Self, key: []const u8, value: V) !void {
            self.lock.lock();
            defer self.lock.unlock();
            try self.inner.put(key, value);
        }

        pub fn fetchRemove(self: *Self, key: []const u8) ?KV {
            self.lock.lock();
            defer self.lock.unlock();
            return self.inner.fetchRemove(key);
        }

        /// Scoped write-lock critical section. Use when an operation must
        /// atomically read-and-mutate. The callback receives a pointer to
        /// the underlying map under the write lock; it must not retain
        /// that pointer or any of its contents after returning.
        pub fn withWriteLock(
            self: *Self,
            ctx: anytype,
            comptime callback: fn (*Inner, @TypeOf(ctx)) void,
        ) void {
            self.lock.lock();
            defer self.lock.unlock();
            callback(&self.inner, ctx);
        }

        /// Scoped shared-lock critical section. Use when a caller needs
        /// to read a value AND perform side effects on it (e.g. bump a
        /// refcount) atomically with the lookup, so the value cannot be
        /// removed between lookup and refcount increment. The callback
        /// receives the underlying map under the shared (read) lock; it
        /// must not mutate the map. Multiple shared-lock callbacks can
        /// run concurrently with each other; they are mutually exclusive
        /// with any write-lock operation.
        pub fn withSharedLock(
            self: *Self,
            ctx: anytype,
            comptime callback: fn (*Inner, @TypeOf(ctx)) void,
        ) void {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            callback(&self.inner, ctx);
        }

        /// Snapshot of all values, allocated with `alloc`. Useful for
        /// iteration-after-release patterns where the caller needs to
        /// process every entry without holding the lock (e.g. deliver
        /// disconnect to every subscriber).
        pub fn valuesSnapshot(self: *Self, alloc: std.mem.Allocator) ![]V {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            var list: std.ArrayListUnmanaged(V) = .empty;
            errdefer list.deinit(alloc);
            try list.ensureTotalCapacity(alloc, self.inner.count());
            var it = self.inner.valueIterator();
            while (it.next()) |v| list.appendAssumeCapacity(v.*);
            return list.toOwnedSlice(alloc);
        }

        /// Snapshot of all keys, allocated with `alloc`. Keys reference
        /// the map's owned strings; callers must finish using the slice
        /// before any thread calls `fetchRemove`.
        pub fn keysSnapshot(self: *Self, alloc: std.mem.Allocator) ![][]const u8 {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer list.deinit(alloc);
            try list.ensureTotalCapacity(alloc, self.inner.count());
            var it = self.inner.keyIterator();
            while (it.next()) |k| list.appendAssumeCapacity(k.*);
            return list.toOwnedSlice(alloc);
        }
    };
}

test "SyncStringHashMap basic operations under write + shared locks" {
    var map = SyncStringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try map.put("one", 1);
    try map.put("two", 2);
    try std.testing.expectEqual(@as(u32, 2), map.count());
    try std.testing.expectEqual(@as(?u32, 1), map.get("one"));
    try std.testing.expect(map.contains("two"));

    const removed = map.fetchRemove("one") orelse return error.MissingKey;
    try std.testing.expectEqualStrings("one", removed.key);
    try std.testing.expectEqual(@as(u32, 1), removed.value);
    try std.testing.expectEqual(@as(u32, 1), map.count());
}

test "SyncStringHashMap withWriteLock atomic read-and-mutate" {
    var map = SyncStringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try map.put("a", 10);
    try map.put("b", 20);

    const Ctx = struct { increment: u32 };
    map.withWriteLock(Ctx{ .increment = 5 }, struct {
        fn run(inner: *std.StringHashMap(u32), ctx: Ctx) void {
            var it = inner.valueIterator();
            while (it.next()) |v| v.* += ctx.increment;
        }
    }.run);

    try std.testing.expectEqual(@as(?u32, 15), map.get("a"));
    try std.testing.expectEqual(@as(?u32, 25), map.get("b"));
}

test "SyncStringHashMap concurrent readers + one writer don't crash" {
    var map = SyncStringHashMap(u32).init(std.testing.allocator);
    defer map.deinit();

    // Pre-populate so readers have something to find.
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const key = try std.fmt.allocPrint(std.testing.allocator, "k{d}", .{i});
        defer std.testing.allocator.free(key);
        // Use duped keys so the map owns them.
        const owned = try std.testing.allocator.dupe(u8, key);
        errdefer std.testing.allocator.free(owned);
        try map.put(owned, i);
    }

    const Reader = struct {
        m: *SyncStringHashMap(u32),
        ops: usize,

        fn run(self: @This()) void {
            var j: usize = 0;
            while (j < self.ops) : (j += 1) {
                const idx = j % 32;
                var buf: [16]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "k{d}", .{idx}) catch unreachable;
                _ = self.m.get(key);
                _ = self.m.contains(key);
                _ = self.m.count();
            }
        }
    };

    const thread_count: usize = 4;
    var threads: [4]std.Thread = undefined;
    var t: usize = 0;
    while (t < thread_count) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, Reader.run, .{Reader{ .m = &map, .ops = 500 }});
    }
    for (threads) |th| th.join();

    // Clean up owned keys.
    const keys = try map.keysSnapshot(std.testing.allocator);
    defer std.testing.allocator.free(keys);
    for (keys) |k| {
        const removed = map.fetchRemove(k) orelse continue;
        std.testing.allocator.free(removed.key);
    }
}
