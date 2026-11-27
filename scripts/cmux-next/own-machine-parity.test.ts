import { describe, expect, test } from "bun:test"
import { classify, exitCode, machineUp, parseOptions, runScenario, type Deps, type Exec, type Options } from "./own-machine-parity"

const ok = (stdout = ""): Exec => ({ code: 0, stdout, stderr: "" })
const opts = (): Options => {
  const o = parseOptions(["--a-socket", "/tmp/a.sock", "--b-name", "mac-b", "--folder", "/Users/b/proj", "--runs", "3"])
  if (typeof o === "string") throw new Error(o)
  return o
}
function deps(answer: (argv: string[]) => Exec) {
  let t = 0
  const files: Record<string, string> = {}
  const calls: string[][] = []
  const d: Deps = {
    exec: async (argv) => (calls.push(argv), answer(argv)),
    now: () => (t += 100),
    sleep: async () => void (t += 500),
    write: () => undefined,
    writeFile: (p, s) => void (files[p] = s)
  }
  return { d, files, calls }
}
const portOf = (argv: string[]) => /--port|http\.server (\d+)|\('127\.0\.0\.1',(\d+)\)/.exec(argv.join(" "))
const allBuilt = (argv: string[]): Exec => {
  const line = argv.join(" ")
  if (line.includes("mktemp -d ")) return ok("/tmp/owp-1-a1B2c3\n")
  if (line.includes("app machines")) return ok(JSON.stringify([{ name: "mac-b", state: "connected" }]))
  if (line.includes(" chat ")) return ok(JSON.stringify({ session_id: "mac-b/x", cwd: "/Users/b/proj" }))
  if (line.includes("machine ports")) return ok(JSON.stringify({ ports: [5173, 5174, 5175] }))
  if (line.includes("file open")) return ok()
  if (line.includes("tab list")) return ok('[{"title":"hello.txt"}]')
  return ok()
}

describe("own-machine-parity", () => {
  test("3 of 3 with everything built passes, no terminal", async () => {
    const { d, files } = deps(allBuilt)
    const r = await runScenario({ ...opts(), report: "/tmp/r.json" }, d)
    expect(r.result).toBe("pass")
    expect(r.summary.runsPassed).toBe(3)
    expect(r.summary.terminalSteps).toBe(0)
    expect(r.runs[0]!.steps.map((s) => s.step)).toEqual(["join", "chat", "port", "file"])
    expect(JSON.parse(files["/tmp/r.json"]!).summary.byStep.port.pass).toBe(3)
    expect(exitCode(r)).toBe(0)
  })
  test("steps whose piece has not landed report not-built, no crash", async () => {
    const { d } = deps((argv) => {
      const line = argv.join(" ")
      if (line.includes("machine ports") || line.includes("file open")) return { code: 2, stdout: "", stderr: "unknown verb" }
      if (line.includes(" chat ")) return { code: 1, stdout: "", stderr: "workspaces need a link" }
      return allBuilt(argv)
    })
    const r = await runScenario(opts(), d)
    expect(r.result).toBe("not-built")
    expect(r.runs[0]!.steps.map((s) => s.status)).toEqual(["pass", "not-built", "not-built", "not-built"])
    expect(exitCode(r)).toBe(3)
  })
  test("a terminal step is a failure", async () => {
    const { d } = deps((argv) => (argv.join(" ").includes(" chat ") ? { code: 1, stdout: "", stderr: "Run ssh mac-b in a terminal first" } : allBuilt(argv)))
    const r = await runScenario(opts(), d)
    expect(r.result).toBe("fail")
    expect(r.summary.terminalSteps).toBe(3)
    expect(r.runs[0]!.steps[1]).toMatchObject({ status: "fail", terminal: true })
    expect(r.runs[0]!.steps[2]!.status).toBe("skipped")
  })
  test("a failed port step still measures the file step", async () => {
    const { d } = deps((argv) => (argv.join(" ").includes(" ports") ? { code: 1, stdout: "", stderr: "port lookup failed" } : allBuilt(argv)))
    const r = await runScenario({ ...opts(), runs: 1 }, d)
    expect(r.runs[0]!.steps[2]!.status).toBe("fail")
    expect(r.runs[0]!.steps[3]!.status).not.toBe("skipped")
  })
  test("a machine that never connects fails the join and skips the rest", async () => {
    const { d } = deps((argv) => (argv.join(" ").includes("app machines") ? ok("[]") : allBuilt(argv)))
    const r = await runScenario({ ...opts(), runs: 1 }, d)
    expect(r.runs[0]!.steps[0]!.status).toBe("fail")
    expect(r.result).toBe("fail")
  })
  test("a chat in the wrong folder fails", async () => {
    const { d } = deps((argv) => (argv.join(" ").includes(" chat ") ? ok('{"session_id":"s","cwd":"/elsewhere"}') : allBuilt(argv)))
    const r = await runScenario({ ...opts(), runs: 1 }, d)
    expect(r.runs[0]!.steps[1]!.detail).toContain("not /Users/b/proj")
  })
  test("cleanup kills only the run's own server and removes only its files", async () => {
    const { d, calls } = deps(allBuilt)
    await runScenario({ ...opts(), runs: 1 }, d)
    const clean = calls.map((c) => c.join(" ")).find((l) => l.includes("kill $(cat"))!
    expect(clean).toMatch(/\/tmp\/owp-1-/)
    expect(clean).not.toMatch(/\*|pkill|killall/)
  })
  test("classify and machineUp", () => {
    expect(classify({ code: 1, stdout: "", stderr: "Unknown verb file" }).kind).toBe("not-built")
    expect(classify({ code: 0, stdout: "ok", stderr: "" }).kind).toBe("ok")
    expect(machineUp('{"machines":[{"name":"mac-b","state":"disconnected"}]}', "mac-b")).toBe(false)
    expect(machineUp('{"machines":[{"name":"mac-b","state":"connected"}]}', "mac-b")).toBe(true)
    void portOf
  })
  test("options are refused when unsafe", () => {
    expect(parseOptions(["--a-socket", "x", "--b-name", "b", "--folder", "/f"])).toContain("--a-socket")
    expect(parseOptions(["--a-socket", "/a", "--b-name", "b;rm", "--folder", "/f"])).toContain("--b-name")
    expect(parseOptions(["--a-socket", "/a", "--b-name", "b", "--folder", "/f/../x"])).toContain("--folder")
  })
})
