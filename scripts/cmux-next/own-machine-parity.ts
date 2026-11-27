/**
 * Scenario `own-machine-parity` of the machine-join harness (machine-join-e2e.ts --scenario own-machine-parity).
 *
 * The lane's done-when (remote-machine-parity): "On a second Mac joined by sign-in only: start a chat in a
 * picked folder, see a new dev server's port and open a file, with no terminal line, 3 of 3."
 *
 *   bun scripts/cmux-next/machine-join-e2e.ts --scenario own-machine-parity \
 *     --a-socket PATH --b-socket PATH --b-name NAME --folder DIR_ON_B [--runs 3] [--port 5173] \
 *     [--b-shell "ssh cmux16"] [--report FILE] [--sha SHA]
 *
 * A is the Mac whose app the person uses, B the second Mac, signed in to the same account and nothing else
 * (the sign-in is the person's; this harness never runs a join line). Every step goes through the app
 * socket of A, the same action a click runs (`cmux chat --on`, the ports and file verbs), so a step that
 * needs a terminal cannot pass: the harness types nothing, and any step whose answer sends the person to a
 * terminal (ssh, "in a terminal", a join line) is recorded as a failure with `terminal: true`.
 * `--b-shell` is measurement plumbing only (it starts the dev server and writes the file to open on B, then
 * removes them); it is not a step of the person's flow.
 *
 * Steps per run: join (B listed connected on A), chat (started on B in the picked folder), port (a new
 * dev server's port shows on A), file (a file on B opens through the files view). A step whose product
 * piece has not landed (the CLI says the verb or option is unknown or unsupported, or the machine has no
 * workspace) is "not-built", not a crash. Exit 0 all pass, 1 any fail, 3 none failed but some not built.
 *
 * Counting (remote-ergonomics-scorecard.md): each step is one app action (`calls`), 0 typed, 0 prompts;
 * `terminal` counts terminal steps and must be 0.
 *
 * The verbs for ports and files are set by env (OWP_PORTS_ARGV, OWP_FILE_ARGV, JSON arrays with {name},
 * {port}, {path}) so the harness follows the product pieces as they land without an edit.
 */
export type Status = "pass" | "fail" | "not-built" | "skipped"
export const STEPS = ["join", "chat", "port", "file"] as const
export type StepName = (typeof STEPS)[number]

export interface StepResult {
  step: StepName
  status: Status
  seconds: number
  calls: number
  terminal: boolean
  detail: string
}
export interface RunResult {
  run: number
  steps: StepResult[]
  terminalSteps: number
  pass: boolean
}
export interface Report {
  scenario: "own-machine-parity"
  sha: string
  machine: string
  folder: string
  startedAt: string
  runs: RunResult[]
  summary: { runsPassed: number; runs: number; byStep: Record<StepName, { pass: number; fail: number; notBuilt: number; medianSeconds: number | null }>; terminalSteps: number }
  result: "pass" | "fail" | "not-built"
}
export interface Exec {
  code: number | null
  stdout: string
  stderr: string
}
export interface Deps {
  exec(argv: string[], timeoutMs: number): Promise<Exec>
  now(): number
  sleep(ms: number): Promise<void>
  write(line: string): void
  writeFile(path: string, text: string): void
}
export interface Options {
  aSocket: string
  bSocket: string
  bName: string
  folder: string
  runs: number
  port: number
  bShell: string[]
  report: string
  sha: string
  portsArgv: string[]
  fileArgv: string[]
}

const NOT_BUILT = /unknown (verb|option|command|action|scope)|unrecognized|unsupported|not supported|no workspace|workspaces need a link|not built|no such (verb|command)|usage:/i
const TERMINAL = /\bin a terminal\b|\bssh [-\w@.]+|cmux (machine add|pair)\b|curl [^|]*\|\s*(ba)?sh|run .* (in|on) the (other|new) machine/i
export const classify = (r: Exec): { kind: "ok" | "not-built" | "terminal" | "error"; text: string } => {
  const text = `${r.stdout}\n${r.stderr}`.trim().replace(/\s+/g, " ").slice(0, 200)
  if (TERMINAL.test(r.stderr) || (r.code !== 0 && TERMINAL.test(r.stdout))) return { kind: "terminal", text }
  if (r.code !== 0 && NOT_BUILT.test(`${r.stdout}\n${r.stderr}`)) return { kind: "not-built", text }
  return r.code === 0 ? { kind: "ok", text } : { kind: "error", text }
}
const fill = (argv: string[], vars: Record<string, string>) => argv.map((a) => a.replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? ""))
const tryJson = (s: string): any => {
  try {
    return JSON.parse(s)
  } catch {
    return null
  }
}
const mentionsPort = (text: string, port: number) => new RegExp(`(^|[^0-9])${port}([^0-9]|$)`).test(text)
/** B listed on A as connected: a row (object) naming it whose state words say it is up. */
export function machineUp(stdout: string, name: string): boolean {
  const rows = (function walk(v: any): any[] {
    if (Array.isArray(v)) return v.flatMap(walk)
    if (v && typeof v === "object") return [v, ...Object.values(v).flatMap(walk)]
    return []
  })(tryJson(stdout))
  return rows.some((r) => !Array.isArray(r) && [r.name, r.label, r.id].includes(name) && /connected|online|running|ready|up/i.test(JSON.stringify([r.state, r.status, r.link, r.connected, r.online])) && !/disconnected|offline|not working/i.test(JSON.stringify([r.state, r.status, r.link])))
}

export async function runOnce(o: Options, d: Deps, run: number): Promise<RunResult> {
  const cmux = (sock: string, ...a: string[]) => ["cmux", "--app-socket", sock, ...a]
  const results: StepResult[] = []
  const token = `owp-${run}-${d.now().toString(36)}`
  // B's own folder for this run, made by mktemp -d there: a name guessed in /tmp could already be another
  // account's FIFO or link.
  let dir = ""
  const ownDir = async (): Promise<string | null> => {
    if (dir) return null
    const m = await bsh(`mktemp -d "\${TMPDIR:-/tmp}/owp-${run}-XXXXXX"`)
    const made = m.stdout.trim()
    if (m.code !== 0 || !made.startsWith("/")) return `could not make a folder on B: ${classify(m).text}`
    dir = made
    return null
  }
  const port = o.port + run - 1
  let broken = false
  const step = async (name: StepName, body: (calls: () => number) => Promise<{ status: Status; detail: string; terminal?: boolean }>) => {
    if (broken) return void results.push({ step: name, status: "skipped", seconds: 0, calls: 0, terminal: false, detail: "an earlier step failed" })
    const t0 = d.now()
    let n = 0
    let r: { status: Status; detail: string; terminal?: boolean }
    try {
      r = await body(() => ++n)
    } catch (e) {
      r = { status: "fail", detail: `harness error: ${e instanceof Error ? e.message : "error"}` }
    }
    const terminal = r.terminal === true
    const status: Status = terminal ? "fail" : r.status
    if (status === "fail") broken = true
    const seconds = Math.round(((d.now() - t0) / 1000) * 1000) / 1000
    results.push({ step: name, status, seconds, calls: n, terminal, detail: terminal ? `terminal needed: ${r.detail}` : r.detail })
    d.write(`run ${run} ${name}: ${status} ${seconds}s ${r.detail}`)
  }
  const bsh = async (script: string) => (o.bShell.length ? d.exec([...o.bShell, script], 30_000) : d.exec(["sh", "-c", script], 30_000))
  try {
    await step("join", async (c) => {
      const deadline = d.now() + 60_000
      for (;;) {
        c()
        const m = await d.exec(cmux(o.aSocket, "app", "machines", "--json", "--no-refresh"), 15_000)
        if (m.code === 0 && machineUp(m.stdout, o.bName)) return { status: "pass", detail: `${o.bName} connected on A` }
        if (d.now() > deadline) return { status: "fail", detail: `${o.bName} not connected on A in 60 s: ${classify(m).text}` }
        await d.sleep(1_000)
      }
    })
    await step("chat", async (c) => {
      c()
      const r = await d.exec(cmux(o.aSocket, "chat", "--on", o.bName, "--cwd", o.folder, "--json", "--prompt", "Reply with the word ok."), 120_000)
      const k = classify(r)
      if (k.kind === "not-built") return { status: "not-built", detail: k.text }
      if (k.kind === "terminal") return { status: "fail", detail: k.text, terminal: true }
      if (k.kind !== "ok") return { status: "fail", detail: k.text }
      const j = tryJson(r.stdout)
      const cwd = j?.cwd ?? j?.folder
      if (typeof cwd === "string" && cwd !== o.folder) return { status: "fail", detail: `chat started in ${cwd}, not ${o.folder}` }
      return j?.session_id ? { status: "pass", detail: `session ${String(j.session_id).replace(/[^\w/.:-]/g, "").slice(0, 64)}` } : { status: "fail", detail: "no session_id in the answer" }
    })
    await step("port", async (c) => {
      const no = await ownDir()
      if (no) return { status: "fail", detail: no }
      const s = await bsh(`cd ${dir} && (nohup python3 -m http.server ${port} --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > ${dir}/pid)`)
      if (s.code !== 0) return { status: "fail", detail: `could not start the dev server on B: ${classify(s).text}` }
      const t0 = d.now()
      // Time from the server listening to its port on A.
      for (;;) {
        const l = await bsh(`python3 -c "import socket;socket.create_connection(('127.0.0.1',${port}),1)"`)
        if (l.code === 0 || d.now() - t0 > 10_000) break
        await d.sleep(200)
      }
      const t1 = d.now()
      for (;;) {
        c()
        const r = await d.exec(cmux(o.aSocket, ...fill(o.portsArgv, { name: o.bName, port: String(port) })), 15_000)
        const k = classify(r)
        if (k.kind === "not-built") return { status: "not-built", detail: k.text }
        if (k.kind === "terminal") return { status: "fail", detail: k.text, terminal: true }
        if (k.kind === "ok" && mentionsPort(r.stdout, port)) return { status: "pass", detail: `port ${port} shown on A after ${Math.round((d.now() - t1) / 100) / 10} s` }
        if (d.now() - t1 > 20_000) return { status: "fail", detail: `port ${port} not shown on A in 20 s: ${k.text}` }
        await d.sleep(500)
      }
    })
    await step("file", async (c) => {
      const no = await ownDir()
      if (no) return { status: "fail", detail: no }
      const file = `${dir}/hello.txt`
      const w = await bsh(`echo ${token} > ${file}`)
      if (w.code !== 0) return { status: "fail", detail: `could not write the file on B: ${classify(w).text}` }
      c()
      const r = await d.exec(cmux(o.aSocket, ...fill(o.fileArgv, { name: o.bName, path: file })), 30_000)
      const k = classify(r)
      if (k.kind === "not-built") return { status: "not-built", detail: k.text }
      if (k.kind === "terminal") return { status: "fail", detail: k.text, terminal: true }
      if (k.kind !== "ok") return { status: "fail", detail: k.text }
      c()
      const tabs = await d.exec(cmux(o.aSocket, "tab", "list", "--json"), 15_000)
      return tabs.code === 0 && tabs.stdout.includes("hello.txt") ? { status: "pass", detail: "hello.txt open on A" } : { status: "fail", detail: "the open succeeded but no tab shows hello.txt" }
    })
  } finally {
    // Only what this run made: its server (by its own pid file) and its own directory.
    if (dir) await bsh(`[ -f ${dir}/pid ] && kill $(cat ${dir}/pid) 2>/dev/null; rm -f ${dir}/pid ${dir}/hello.txt; rmdir ${dir} 2>/dev/null; true`)
  }
  const terminalSteps = results.filter((r) => r.terminal).length
  return { run, steps: results, terminalSteps, pass: terminalSteps === 0 && results.every((r) => r.status === "pass") }
}

const median = (xs: number[]) => (xs.length ? [...xs].sort((a, b) => a - b)[Math.floor((xs.length - 1) / 2)]! : null)

export function summarize(o: Options, runs: RunResult[], startedAt: string): Report {
  const byStep = {} as Report["summary"]["byStep"]
  for (const s of STEPS) {
    const rs = runs.flatMap((r) => r.steps.filter((x) => x.step === s))
    byStep[s] = {
      pass: rs.filter((x) => x.status === "pass").length,
      fail: rs.filter((x) => x.status === "fail" || x.status === "skipped").length,
      notBuilt: rs.filter((x) => x.status === "not-built").length,
      medianSeconds: median(rs.filter((x) => x.status === "pass").map((x) => x.seconds))
    }
  }
  const failed = runs.some((r) => r.steps.some((x) => x.status === "fail") || r.terminalSteps > 0)
  const notBuilt = runs.some((r) => r.steps.some((x) => x.status === "not-built"))
  return {
    scenario: "own-machine-parity",
    sha: o.sha,
    machine: o.bName,
    folder: o.folder,
    startedAt,
    runs,
    summary: { runsPassed: runs.filter((r) => r.pass).length, runs: runs.length, byStep, terminalSteps: runs.reduce((n, r) => n + r.terminalSteps, 0) },
    result: failed ? "fail" : notBuilt ? "not-built" : "pass"
  }
}

export function parseOptions(argv: string[], env: Record<string, string | undefined> = {}): Options | string {
  const v = (f: string) => {
    const i = argv.indexOf(f)
    return i >= 0 && i + 1 < argv.length ? argv[i + 1]! : ""
  }
  const arr = (raw: string | undefined, dflt: string[]) => {
    const j = raw ? tryJson(raw) : null
    return Array.isArray(j) && j.every((x) => typeof x === "string") ? (j as string[]) : dflt
  }
  const o: Options = {
    aSocket: v("--a-socket"),
    bSocket: v("--b-socket"),
    bName: v("--b-name"),
    folder: v("--folder"),
    runs: v("--runs") ? Number(v("--runs")) : 3,
    port: v("--port") ? Number(v("--port")) : 5173,
    bShell: v("--b-shell").split(/\s+/).filter(Boolean),
    report: v("--report"),
    sha: v("--sha") || "unknown",
    portsArgv: arr(env.OWP_PORTS_ARGV, ["machine", "ports", "--machine", "{name}", "--json"]),
    fileArgv: arr(env.OWP_FILE_ARGV, ["file", "open", "--machine", "{name}", "--path", "{path}"])
  }
  if (!o.aSocket.startsWith("/")) return "--a-socket must be an absolute path"
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(o.bName)) return "--b-name must be the machine's plain name"
  if (!o.folder.startsWith("/") || o.folder.includes("..")) return "--folder must be an absolute folder on B"
  if (!Number.isInteger(o.runs) || o.runs < 1 || o.runs > 10) return "--runs must be 1 to 10"
  if (!Number.isInteger(o.port) || o.port < 1024 || o.port > 65000) return "--port must be 1024 to 65000"
  if (o.report && !o.report.startsWith("/")) return "--report must be an absolute path"
  return o
}

export async function runScenario(o: Options, d: Deps): Promise<Report> {
  const startedAt = new Date(d.now()).toISOString()
  const runs: RunResult[] = []
  for (let i = 1; i <= o.runs; i++) runs.push(await runOnce(o, d, i))
  const report = summarize(o, runs, startedAt)
  const text = JSON.stringify(report, null, 2)
  if (o.report) d.writeFile(o.report, text)
  d.write(text)
  return report
}

export const exitCode = (r: Report) => (r.result === "pass" ? 0 : r.result === "fail" ? 1 : 3)
