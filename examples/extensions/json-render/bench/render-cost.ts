// Render cost of a spec against the same view written by hand, in one harness (the SDK's fake
// host, Bun's JSC): mount, then one toggle, each N times; the ops each sends; the bundle sizes.
//   bun examples/extensions/json-render/bench/render-cost.ts [N]
// Run it on cmux-ci (`cmux-ci test -- bun ...`), not on a person's Mac.

import { readFileSync } from "node:fs"
import { join } from "node:path"
import { gzipSync } from "node:zlib"
import { pack } from "../../../../cmux-tui/crates/cmux-app-host/tools/pack.ts"
import { app, FakeHost } from "../../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const N = Number(process.argv[2] ?? 300)
const dir = join(import.meta.dir, "..")
const spec = JSON.parse(readFileSync(join(dir, "specs/todo.json"), "utf8"))
const built = await pack(dir)

// The same tree by hand: what an extension author would write for this widget.
const handBody = `
const [s, set] = signal(${JSON.stringify(spec.state)})
const todos = computed(() => s().todos)
let n = 0
const push = () => set({ ...s(), todos: [...s().todos, { id: "h" + n++, title: s().newTodo, done: false }], newTodo: "" })
function renderSection() {
  return VStack([Panel({ title: "Todos" }, [
    HStack({ spacing: 6 }, [Text("Tasks").font("caption").color("secondary"), Spacer(), Badge(() => String(todos().length), "accent")]),
    HStack({ spacing: 6 }, [TextField(() => s().newTodo, { placeholder: "Add a task", onEdit: (t) => set({ ...s(), newTodo: t }), onSubmit: push }), Button("Add", push)]),
    Divider(),
    VStack({ spacing: 4 }, [ForEach({ items: todos, key: (t) => t.id }, (t, key) => VStack({ spacing: 2 }, [HStack({ spacing: 6 }, [
      Toggle(() => t().done, { label: () => t().title, onChange: (on) => set({ ...s(), todos: s().todos.map((x) => x.id === key ? { ...x, done: on } : x) }) }),
      Spacer(),
      Button("✕", () => set({ ...s(), todos: s().todos.filter((x) => x.id !== key) }))
    ])]))]),
    VStack({ spacing: 0 }, [() => (todos().length === 0 ? Text("All clear. Add a task above.").font("caption").color("secondary") : null)])
  ])])
}
return { renderSection }`

function host(source: string) {
  const h = new FakeHost(source, { app: { id: "local/bench", version: "0.0.0" }, settings: {} })
  h.handlers["app.storage.get"] = () => ({ ok: true, body: { value: null } })
  h.handlers["app.storage.set"] = () => ({ ok: true, body: { value: null } })
  return h
}

function measure(name: string, source: string) {
  const mounts: number[] = []
  const toggles: number[] = []
  let mountOps = 0
  let toggleOps = 0
  for (let i = 0; i < N; i++) {
    const h = host(source)
    let t = performance.now()
    h.mount("s", "renderSection")
    mounts.push(performance.now() - t)
    mountOps = h.batches("s").flat().length
    const toggle = h.findNode("s", (x) => x.type === "Toggle" && x.props.label === "Write release notes")!
    t = performance.now()
    h.dispatch("s", toggle, "change", { value: true })
    toggles.push(performance.now() - t)
    toggleOps = h.batches("s").flat().length - mountOps
  }
  const q = (xs: number[], p: number) => xs.sort((a, b) => a - b)[Math.floor(p * (xs.length - 1))].toFixed(3)
  return { name, n: N, mount_ms_p50: q(mounts, 0.5), mount_ms_p95: q(mounts, 0.95), toggle_ms_p50: q(toggles, 0.5), toggle_ms_p95: q(toggles, 0.95), mount_ops: mountOps, toggle_ops: toggleOps }
}

const handSource = app(handBody)
console.log(JSON.stringify(measure("hand-written kit", handSource)))
console.log(JSON.stringify(measure("json-render spec", built)))
const size = (s: string) => ({ bytes: Buffer.byteLength(s), gzip: gzipSync(s, { level: 9 }).length })
const src = ["src/check.ts", "src/spec.ts", "catalog.json"].map((f) => readFileSync(join(dir, f), "utf8")).join("\n")
console.log(JSON.stringify({ bundle: { "packed extension (SDK runtime shim + interpreter + catalog + todo spec)": size(built), "interpreter + catalog source": size(src), "todo spec": size(JSON.stringify(spec)) } }))
if (process.env.FAST_CHECKS_OUT) await Bun.write(join(process.env.FAST_CHECKS_OUT, "main.js"), built)
