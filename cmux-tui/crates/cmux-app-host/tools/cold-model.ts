// The cold-model design test (plans/cmux-next/extensions/DESIGN.md section 12): a small model that
// has never seen cmux writes a widget from the design skill page alone, and the design check must
// find nothing wrong with what it drew.
//
//   bun cmux-tui/crates/cmux-app-host/tools/cold-model.ts [--model claude-haiku-5-5] [--task NAME]... [--out DIR]
//
// For each task it:
//   1. writes a folder from the `cmux ext new --kind widget` template (a manifest with sizes small and medium);
//   2. asks the model, through `claude -p --bare` with no tools, no CLAUDE.md and the page
//      skills/cmux-customization/references/extension-design.md as its whole system prompt, for src/main.ts;
//   3. builds it with the packer `cmux ext dev` uses and mounts it at each size in the fake host,
//      the real runtime under bun, and writes what it drew to preview/scenes.json, the file
//      `cmux ext shot --record` writes ({"cmux.widget/1 small": {ops}, ...});
//   4. when CMUX_BIN names a cmux built from this tree, runs `cmux ext design --listing DIR --json`
//      on it and prints the verdict.
//
// --out (default cmux-tui/crates/cmux-tui/src/cli/ext/cold_model) keeps each run's folder. The Rust
// test cli::ext::publish_tests::cold_model_widgets_pass_the_design_check runs registry review's
// check on every folder there, so a run that is kept is a run CI checks again. The model sees
// only the page and the task: nothing else in the prompt names a helper.
import { spawnSync } from "node:child_process"
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { FakeHost, type Op } from "../js/test/fake-host.ts"
import { pack } from "./pack.ts"

const root = join(import.meta.dir, "../../../..")
const page = join(root, "skills/cmux-customization/references/extension-design.md")
const template = join(root, "cmux-tui/crates/cmux-tui/src/cli/ext/templates/widget")
const sdk = join(root, "cmux-tui/crates/cmux-extension-sdk/typescript/src/index.ts")
const SIZES = ["small", "medium"] as const
/** The clock every scene is drawn at: 2026-11-16 09:41 local time. */
const AT = new Date(2026, 10, 16, 9, 41, 0).getTime()

/** The widgets asked for: each a name and a request in a person's words, none naming a helper. */
export const TASKS: Record<string, string> = {
  "pomodoro": "A pomodoro timer widget: the minutes left in the current 25-minute focus block (use sample data: 17 minutes left, block 2 of 4), and in the medium size the blocks done today.",
  "build-status": "A CI build status widget: whether the last build of the main branch passed or failed (sample: failed, 12 minutes ago, 3 tests failing), and in the medium size the last three builds with their result and time.",
  "weather": "A weather widget for one city (sample: Lisbon, 21 degrees, sunny, high 24 low 15), and in the medium size the next four hours with their temperatures.",
  "next-meeting": "A calendar widget: the next meeting today (sample: Design review at 14:00, in 25 minutes, room 4B), and in the medium size the rest of today's meetings with their times.",
  "todo": "A to-do widget: how many tasks are left today (sample: 5 left of 8; one is overdue), and in the medium size the next three tasks, the overdue one marked.",
}

const SYSTEM = (skill: string) =>
  `You write cmux extensions. This page is everything you know about drawing one; follow it exactly.\n\n${skill}`

const PROMPT = (task: string) =>
  [
    `Write src/main.ts for a cmux widget. ${task}`,
    `The manifest (cmux-app.json) already implements "cmux.widget/1" with export "renderWidget" and sizes small and medium.`,
    `Import only from "cmux-extension-sdk". Reply with the whole file in one \`\`\`ts code block and nothing else.`,
  ].join("\n")

function args() {
  const argv = process.argv.slice(2)
  const tasks: string[] = []
  let model = "claude-haiku-5-5"
  let out = join(root, "cmux-tui/crates/cmux-tui/src/cli/ext/cold_model")
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === "--model") model = argv[++i]!
    else if (a === "--task") tasks.push(argv[++i]!)
    else if (a === "--out") out = argv[++i]!
    else throw new Error(`unknown argument ${a}`)
  }
  for (const t of tasks) if (!TASKS[t]) throw new Error(`no task ${t}; one of ${Object.keys(TASKS).join(", ")}`)
  return { model, out, tasks: tasks.length ? tasks : Object.keys(TASKS) }
}

/** The template folder with its placeholders filled. */
function scaffold(dir: string, name: string) {
  // The template's dist/ is its own build; the run writes the model's.
  cpSync(template, dir, { recursive: true, filter: (src) => !src.startsWith(join(template, "dist")) })
  const walk = (d: string) => {
    for (const entry of readdirSync(d)) {
      const p = join(d, entry)
      if (statSync(p).isDirectory()) walk(p)
      else writeFileSync(p, readFileSync(p, "utf8").replaceAll("{{NAME}}", name).replaceAll("{{TITLE}}", name))
    }
  }
  walk(dir)
  const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
  manifest.files = ["dist/", "preview/"]
  writeFileSync(join(dir, "cmux-app.json"), `${JSON.stringify(manifest, null, 2)}\n`)
}

/** The model's src/main.ts: the one ts block of its reply. */
function ask(model: string, task: string): string {
  const scratch = mkdtempSync(join(tmpdir(), "cold-model-"))
  try {
    const run = spawnSync(
      "claude",
      ["-p", "--bare", "--model", model, "--tools", "", "--no-session-persistence", "--system-prompt", SYSTEM(readFileSync(page, "utf8")), PROMPT(task)],
      { cwd: scratch, encoding: "utf8", timeout: 300_000, maxBuffer: 16 << 20 }
    )
    if (run.status !== 0) throw new Error(`claude exited ${run.status}: ${run.stderr || run.stdout}`)
    const block = /```(?:ts|typescript)\n([\s\S]*?)```/.exec(run.stdout)
    if (!block) throw new Error(`the reply has no ts block:\n${run.stdout}`)
    return block[1]!
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

/** The ops that draw a mount's tree in one batch: what `cmux ext shot --record` keeps. */
function snapshot(host: FakeHost, mount: string): Op[] {
  const tree = host.tree(mount)
  const ids: string[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    ids.push(id)
    n.children.forEach(walk)
  }
  walk(tree.root)
  const ops: Op[] = ids.map((id) => {
    const n = tree.nodes.get(id)!
    const props = Object.fromEntries(Object.entries(n.props).filter(([k]) => !k.startsWith("on") && k !== "menu"))
    return { op: "create", id, type: n.type, props }
  })
  for (const id of ids) if (tree.nodes.get(id)!.children.length) ops.push({ op: "children", id, children: tree.nodes.get(id)!.children })
  ops.push({ op: "root", id: tree.root })
  return ops
}

/** Each size's scene, keyed as `cmux ext shot --record` keys a widget's. */
export async function render(dir: string): Promise<Record<string, { ops: Op[] }>> {
  const built = await pack(dir, { sdk })
  mkdirSync(join(dir, "dist"), { recursive: true })
  writeFileSync(join(dir, "dist/main.js"), built)
  const scenes: Record<string, { ops: Op[] }> = {}
  for (const size of SIZES) {
    const host = new FakeHost(built, { app: { id: "local/cold", version: "0.1.0" }, settings: {}, apiVersion: "1.0.0" })
    // One fixed clock, so a widget that reads now() once at mount records the same scene on every run.
    host.eval(`Date.now = () => ${AT}`)
    const error = host.mount("m", "renderWidget", { surface: "widget", place: "newtab", size, instance: "w1", settings: {}, refresh: { everySeconds: 60 }, locale: "en-US", timeZone: "UTC", preview: true })
    if (error) throw new Error(`${size}: ${error}`)
    host.tick("m", AT)
    await host.settle()
    scenes[`cmux.widget/1 ${size}`] = { ops: snapshot(host, "m") }
  }
  return scenes
}

async function main() {
  const { model, out, tasks } = args()
  let failed = 0
  for (const task of tasks) {
    const dir = join(out, task)
    if (existsSync(dir)) rmSync(dir, { recursive: true })
    mkdirSync(dir, { recursive: true })
    scaffold(dir, task)
    const source = ask(model, TASKS[task]!)
    writeFileSync(join(dir, "src/main.ts"), source)
    mkdirSync(join(dir, "preview"), { recursive: true })
    let verdict = "recorded"
    try {
      writeFileSync(join(dir, "preview/scenes.json"), `${JSON.stringify(await render(dir), null, 2)}\n`)
    } catch (error) {
      verdict = `did not render: ${error instanceof Error ? error.message : String(error)}`
      failed++
    }
    writeFileSync(join(dir, "cold-model.json"), `${JSON.stringify({ model, task: TASKS[task], page: "skills/cmux-customization/references/extension-design.md" }, null, 2)}\n`)
    const bin = process.env.CMUX_BIN
    if (bin && verdict === "recorded") {
      const check = spawnSync(bin, ["ext", "design", "--listing", dir, "--json"], { encoding: "utf8" })
      verdict = check.status === 0 ? "no design warning" : `design warnings:\n${check.stdout}`
      if (check.status !== 0) failed++
    }
    console.log(`${task}: ${verdict}`)
  }
  process.exit(failed ? 1 : 0)
}

if (import.meta.main) await main()
