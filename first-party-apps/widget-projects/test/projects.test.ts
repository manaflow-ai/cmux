import { describe, expect, test } from "bun:test"
import { age, colorOf, displayName, letterOf, machineColor, recent, shortPath, TILE_COLORS, type Project } from "../src/projects.ts"

const p = (name: string, ms: number, overlay: Project["overlay"] = {}, state: Project["state"] = "present"): Project => ({
  path: `/Users/me/code/${name}`,
  name,
  last_used_ms: String(ms),
  overlay,
  state
})

describe("projects", () => {
  test("pinned first in their order, then the most recently used", () => {
    const list = [p("a", 10), p("b", 30), p("c", 20), p("pin2", 1, { pinned: true, order: 2 }), p("pin1", 0, { pinned: true, order: 1 })]
    expect(recent(list, 10).map((x) => x.name)).toEqual(["pin1", "pin2", "b", "c", "a"])
    expect(recent(list, 3).map((x) => x.name)).toEqual(["pin1", "pin2", "b"])
  })

  test("hidden and missing projects are left out", () => {
    const list = [p("hidden", 50, { hidden: true }), p("gone", 40, {}, "missing"), p("here", 1)]
    expect(recent(list, 10).map((x) => x.name)).toEqual(["here"])
  })

  test("the name is the person's rename, else the folder's", () => {
    expect(displayName(p("notes", 1, { rename: "My Notes" }))).toBe("My Notes")
    expect(displayName(p("notes", 1, { rename: "  " }))).toBe("notes")
    expect(displayName({ path: "/srv/app/", name: "", last_used_ms: "0" })).toBe("app")
  })

  test("the tile letter is the first letter or digit", () => {
    expect(letterOf("cmux-next")).toBe("C")
    expect(letterOf(".dotfiles")).toBe("D")
    expect(letterOf("9front")).toBe("9")
    expect(letterOf("ñandú")).toBe("Ñ")
    expect(letterOf("---")).toBe("?")
  })

  test("a project keeps its color, and machines get their own", () => {
    expect(colorOf("/Users/me/code/cmux")).toBe(colorOf("/Users/me/code/cmux"))
    expect(TILE_COLORS).toContain(colorOf("/x") as (typeof TILE_COLORS)[number])
    const colors = new Set(["a", "b", "c", "d", "e", "f", "g", "h"].map((n) => colorOf(`/Users/me/code/${n}`)))
    expect(colors.size).toBeGreaterThan(3)
    expect(machineColor("machine_1", "Mac")).toBe(machineColor("machine_1", "Other name"))
  })

  test("paths read with ~ for home, and ages as Apple's widgets write them", () => {
    expect(shortPath("/Users/me/code/cmux")).toBe("~/code/cmux")
    expect(shortPath("/home/dev/src")).toBe("~/src")
    expect(shortPath("/Users/me")).toBe("~")
    expect(shortPath("/opt/app")).toBe("/opt/app")
    const now = 1_000_000_000
    expect(age(now - 10_000, now)).toBe("now")
    expect(age(now - 5 * 60_000, now)).toBe("5m")
    expect(age(now - 3 * 3_600_000, now)).toBe("3h")
    expect(age(now - 2 * 86_400_000, now)).toBe("2d")
    expect(age(now - 15 * 86_400_000, now)).toBe("2w")
    expect(age(now + 60_000, now)).toBe("now")
  })
})
