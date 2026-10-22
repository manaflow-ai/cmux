// Writes the scene ops of each examples/custom-sidebars script, run against a fixed set of
// workspaces, to examples/custom-sidebars/scenes/<name>.json.
// CustomSidebarGalleryTests renders them with the native scene renderer.
//   bun cmux-tui/crates/cmux-app-host/js/test/custom-sidebar-fixtures.ts
import { readFileSync, writeFileSync } from "node:fs"
import { FakeHost } from "./fake-host.ts"

const root = new URL("../../../../../", import.meta.url).pathname
const names = ["api-gateway", "web-dashboard", "ios-release", "billing-migration", "docs", "perf-sidebar",
  "chromium-update", "cloud-vm", "onboarding", "notes", "release-1.9", "scratch"]
const workspaces = names.map((name, i) => ({ id: `ws_${i}`, name, focused: i === 2 }))
const agents = [
  { workspace_id: "ws_0", state: "working" }, { workspace_id: "ws_1", state: "blocked" },
  { workspace_id: "ws_3", state: "working" }, { workspace_id: "ws_3", state: "working" }, { workspace_id: "ws_3", state: "blocked" },
  { workspace_id: "ws_5", state: "working" }, { workspace_id: "ws_7", state: "idle" }, { workspace_id: "ws_10", state: "blocked" },
]
const notifications = [
  { workspace_id: "ws_1", read: false }, { workspace_id: "ws_1", read: false }, { workspace_id: "ws_4", read: false },
  { workspace_id: "ws_10", read: false }, { workspace_id: "ws_8", read: false },
]
for (const name of ["dots", "board", "cards"]) {
  const host = new FakeHost(readFileSync(`${root}examples/custom-sidebars/${name}.js`, "utf8"))
  host.handlers["workspace.list"] = () => ({ ok: true, body: { value: workspaces } })
  host.handlers["agent.list"] = () => ({ ok: true, body: { value: agents } })
  host.handlers["notification.list"] = () => ({ ok: true, body: { value: notifications } })
  const error = host.mount("m1", "sidebar")
  if (error) throw new Error(`${name}: ${error}`)
  await host.settle()
  const out = `${root}examples/custom-sidebars/scenes/${name}.json`
  writeFileSync(out, JSON.stringify(host.batches("m1").flat()) + "\n")
  console.log(`wrote ${out}`)
}
