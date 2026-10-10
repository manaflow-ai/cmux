import { describe, expect, test } from "bun:test"
import { basename, collapseCrumbs, crumbs, displayPath, isHandle, join, locationKey, normalizeRel, parent, PathError, sameLocation, shellQuote, validName } from "../src/model/handles.ts"

describe("handles", () => {
  test("recognizes handles by kind", () => {
    expect(isHandle("root", "root_home01")).toBe(true)
    expect(isHandle("conn", "root_home01")).toBe(false)
    expect(isHandle("root", "root_")).toBe(false)
    expect(isHandle("root", "/Users/someone")).toBe(false)
    expect(isHandle("cred", 42)).toBe(false)
  })
})

describe("root-relative paths", () => {
  test("normalizes slashes and dots", () => {
    expect(normalizeRel("/a//b/./c/")).toBe("a/b/c")
    expect(normalizeRel("")).toBe("")
  })

  test("refuses .. instead of resolving it", () => {
    expect(() => normalizeRel("a/../../etc")).toThrow(PathError)
    expect(() => join("a", "..")).toThrow(PathError)
    expect(() => join("a", "b/c")).toThrow(PathError)
  })

  test("join, parent and basename stay inside the root", () => {
    expect(join("", "src")).toBe("src")
    expect(join("src", "app")).toBe("src/app")
    expect(parent("src/app")).toBe("src")
    expect(parent("src")).toBe("")
    expect(parent("")).toBeNull()
    expect(basename("src/app/main.ts")).toBe("main.ts")
  })

  test("valid names", () => {
    expect(validName("report (1).pdf")).toBe(true)
    for (const bad of ["", ".", "..", "a/b", "a\u0000b", "x".repeat(256)]) expect(validName(bad)).toBe(false)
  })

  test("path bar crumbs and collapse", () => {
    expect(crumbs("Home", "src/app/lib")).toEqual([
      { label: "Home", path: "" },
      { label: "src", path: "src" },
      { label: "app", path: "src/app" },
      { label: "lib", path: "src/app/lib" }
    ])
    const long = crumbs("Home", "a/b/c/d/e")
    expect(collapseCrumbs(long, 2).map((c) => c?.label ?? null)).toEqual(["Home", null, "d", "e"])
    expect(collapseCrumbs(crumbs("Home", "a"), 3)).toHaveLength(2)
  })

  test("display path uses the owner's root display", () => {
    expect(displayPath("~", "")).toBe("~")
    expect(displayPath("~/src", "app/x.ts")).toBe("~/src/app/x.ts")
    expect(displayPath("build-box:/", "srv")).toBe("build-box:/srv")
  })

  test("location identity ignores slash noise", () => {
    const a = { conn: "conn_a1", root: "root_r1", path: "src/" }
    const b = { conn: "conn_a1", root: "root_r1", path: "/src" }
    expect(sameLocation(a, b)).toBe(true)
    expect(locationKey(a)).toBe(locationKey(b))
    expect(sameLocation(a, { ...b, conn: "conn_b1" })).toBe(false)
  })
})

describe("shell quoting", () => {
  test("plain paths stay plain; others are single-quoted", () => {
    expect(shellQuote("/srv/app/main.ts")).toBe("/srv/app/main.ts")
    expect(shellQuote("/tmp/My Files/a.txt")).toBe("'/tmp/My Files/a.txt'")
    expect(shellQuote("/tmp/it's")).toBe("'/tmp/it'\\''s'")
    expect(shellQuote("~/x")).toBe("'~/x'")
    expect(shellQuote("$(rm -rf /)")).toBe("'$(rm -rf /)'")
    expect(shellQuote("")).toBe("''")
  })
})
