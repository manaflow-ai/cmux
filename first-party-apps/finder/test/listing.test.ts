import { describe, expect, test } from "bun:test"
import { compareEntries, DEFAULT_SORT, type Entry, naturalCompare } from "../src/model/entries.ts"
import { type Batch, canLoadMore, displayTotal, initialListing, type ListingState, reduceListing, revisionCompare, visibleEntries, type WatchEvent } from "../src/model/listing.ts"

const f = (name: string, size = 1, mtime = 1): Entry => ({ name, kind: "file", size, mtime })
const d = (name: string): Entry => ({ name, kind: "dir", size: null, mtime: 1 })
const K = "conn_a|root_a|"
const names = (s: ListingState) => visibleEntries(s).map((e) => e.name)
const open = () => reduceListing(initialListing(), { type: "open", key: K })
const batch = (s: ListingState, entries: Entry[], cursor: string | null, extra: Partial<Batch> = {}) =>
  reduceListing(s, { type: "batch", key: K, batch: { listing: "lst_1", entries, cursor, total: 6, revision: "100", ...extra } })
const watch = (s: ListingState, event: WatchEvent) => reduceListing(s, { type: "watch", key: K, event })

describe("ordering", () => {
  test("natural, case-insensitive names", () => {
    expect(["file10", "File2", "file1"].sort(naturalCompare)).toEqual(["file1", "File2", "file10"])
  })
  test("folders first, name tiebreak, descending sizes", () => {
    const list = [f("b", 5), d("z"), f("a", 5), f("c", 9)]
    expect(list.slice().sort(compareEntries(DEFAULT_SORT)).map((e) => e.name)).toEqual(["z", "a", "b", "c"])
    expect(list.slice().sort(compareEntries({ key: "size", dir: "desc", dirsFirst: true })).map((e) => e.name)).toEqual(["z", "c", "b", "a"])
  })
  test("revisions compare as unbounded integers", () => {
    expect(revisionCompare("99", "100")).toBe(-1)
    expect(revisionCompare("12345678901234567890", "12345678901234567889")).toBe(1)
    expect(revisionCompare("007", "7")).toBe(0)
  })
})

describe("cursor batches", () => {
  test("batches append in owner order; the last one completes", () => {
    let s = batch(open(), [f("a"), f("b"), f("c")], "cur_1")
    expect(s.status).toBe("partial")
    expect(canLoadMore(s)).toBe(true)
    s = batch(s, [f("d"), f("e"), f("f")], null)
    expect(s.status).toBe("complete")
    expect(names(s)).toEqual(["a", "b", "c", "d", "e", "f"])
  })

  test("a repeated batch does not duplicate rows", () => {
    let s = batch(open(), [f("a"), f("b")], "cur_1")
    s = batch(s, [f("b"), f("c")], null)
    expect(names(s)).toEqual(["a", "b", "c"])
  })

  test("batches of another location or another listing are dropped", () => {
    let s = batch(open(), [f("a")], "cur_1")
    const other = reduceListing(s, { type: "batch", key: "conn_a|root_a|elsewhere", batch: { listing: "lst_1", entries: [f("x")], cursor: null, total: 1, revision: "1" } })
    expect(other).toBe(s)
    s = batch(s, [f("y")], null, { listing: "lst_old" })
    expect(names(s)).toEqual(["a"])
  })

  test("cursor.expired and overflow mark the listing stale; other errors keep rows", () => {
    let s = batch(open(), [f("a")], "cur_1")
    expect(reduceListing(s, { type: "error", key: K, error: { code: "cursor.expired", message: "" } }).status).toBe("stale")
    const err = reduceListing(s, { type: "error", key: K, error: { code: "host.unreachable", message: "gone" } })
    expect(err.status).toBe("error")
    expect(names(err)).toEqual(["a"])
    expect(watch(s, { kind: "overflow", revision: "101" }).status).toBe("stale")
  })

  test("relist keeps rows until the new first batch lands", () => {
    let s = batch(open(), [f("a"), f("b")], null)
    s = reduceListing(s, { type: "open", key: K, keepRows: true })
    expect(s.status).toBe("loading")
    expect(names(s)).toEqual(["a", "b"])
    s = batch(s, [f("b"), f("c")], null, { listing: "lst_2", revision: "200" })
    expect(names(s)).toEqual(["b", "c"])
  })
})

describe("watch events", () => {
  test("events at or before the snapshot revision are already in it", () => {
    const s = batch(open(), [f("a")], null)
    expect(watch(s, { kind: "created", revision: "100", entry: f("b") })).toBe(s)
    expect(watch(s, { kind: "deleted", revision: "99", name: "a" })).toBe(s)
  })

  test("an event that beats the first batch is replayed against its revision", () => {
    let s = open()
    s = watch(s, { kind: "created", revision: "101", entry: f("new") })
    s = watch(s, { kind: "deleted", revision: "90", name: "a" })
    s = batch(s, [f("a"), f("b")], null)
    expect(names(s)).toEqual(["a", "b", "new"])
  })

  test("the overlay wins over a later batch with the same name", () => {
    let s = batch(open(), [f("a"), f("b")], "cur_1")
    s = watch(s, { kind: "deleted", revision: "101", name: "d" })
    s = watch(s, { kind: "modified", revision: "102", entry: f("c", 99) })
    s = batch(s, [f("c", 1), f("d"), f("e")], null)
    expect(names(s)).toEqual(["a", "b", "c", "e"])
    expect(visibleEntries(s).find((e) => e.name === "c")!.size).toBe(99)
  })

  test("a file created past the loaded window appears when loading reaches it", () => {
    let s = batch(open(), [f("a"), f("b")], "cur_1")
    s = watch(s, { kind: "created", revision: "101", entry: f("m") })
    s = watch(s, { kind: "created", revision: "102", entry: f("aa") })
    expect(names(s)).toEqual(["a", "aa", "b"])
    s = batch(s, [f("c"), f("z")], null)
    expect(names(s)).toEqual(["a", "aa", "b", "c", "m", "z"])
  })

  test("rename, duplicate events and totals", () => {
    let s = batch(open(), [f("a"), f("b")], "cur_1", { total: 10 })
    s = watch(s, { kind: "renamed", revision: "101", from: "a", entry: f("a2") })
    expect(names(s)).toEqual(["a2", "b"])
    s = watch(s, { kind: "created", revision: "102", entry: f("c") })
    s = watch(s, { kind: "created", revision: "102", entry: f("c") })
    s = watch(s, { kind: "deleted", revision: "103", name: "b" })
    expect(displayTotal(s)).toBe(10)
    s = watch(s, { kind: "created", revision: "104", entry: f("aaa") })
    expect(displayTotal(s)).toBe(11)
  })

  test("a complete listing folds events straight into its rows", () => {
    let s = batch(open(), [f("a"), f("b")], null, { total: 2 })
    s = watch(s, { kind: "created", revision: "101", entry: d("dir") })
    expect(s.overlay).toEqual({})
    expect(names(s)).toEqual(["dir", "a", "b"])
    expect(displayTotal(s)).toBe(3)
  })
})

describe("sort and filter", () => {
  test("a complete listing re-sorts locally; a partial one goes back to the owner", () => {
    const complete = batch(open(), [f("a", 1), f("b", 3)], null)
    const sorted = reduceListing(complete, { type: "sort", sort: { key: "size", dir: "desc", dirsFirst: true } })
    expect(sorted.status).toBe("complete")
    expect(names(sorted)).toEqual(["b", "a"])
    const partial = batch(open(), [f("a")], "cur_1")
    expect(reduceListing(partial, { type: "sort", sort: { key: "size", dir: "desc", dirsFirst: true } }).status).toBe("stale")
  })

  test("hidden files and the query filter apply to overlay rows too", () => {
    let s = batch(open(), [f("alpha"), f(".env"), f("beta")], null)
    expect(names(s)).toEqual(["alpha", "beta"])
    s = reduceListing(s, { type: "filter", filter: { query: "ph", hidden: false } })
    s = watch(s, { kind: "created", revision: "101", entry: f("graph") })
    expect(names(s)).toEqual(["alpha", "graph"])
  })
})
