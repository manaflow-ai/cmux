/** image-staleness.ts: channel images against the tip's capability list, on temp git repos (no VM, no network). */
import { describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { checkStaleness, revReader, tipCapabilities, treeReader } from "../image-staleness.ts"
import { REAL } from "./helpers.ts"

const CAPS_RS = "cmux-tui/crates/cmux-tui-core/src/server/capabilities.rs"

/** A capabilities.rs in the real shape: a vec of constants and literals, cfg pushes, extends, and runtime pushes in identify. */
const capabilitiesRs = (extra: Array<string> = []) => `//! fixture
use super::*;

pub(super) fn identify_capabilities(mux: &Mux) -> Vec<&'static str> {
    let mut capabilities = advertised_capabilities(cfg!(unix));
    capabilities.push(activity::CAPABILITY);
    if mux.cloud_conversations().is_some() {
        capabilities.push(cloud_conversations::CAPABILITY);
    }
    capabilities
}

pub(super) fn advertised_capabilities(bounded: bool) -> Vec<&'static str> {
    let mut capabilities = vec![
        TABS_CAPABILITY,
        "attach-identity-v1",
        crate::state::folder::CAPABILITY,
${extra.map((e) => `        ${e},`).join("\n")}
    ];
    if bounded {
        capabilities.push(CLEAR_KEY_CAPABILITY);
    }
    #[cfg(any(target_os = "linux", target_vendor = "apple"))]
    capabilities.push(crate::image_paste::CAPABILITY);
    #[cfg(windows)]
    capabilities.push(WINDOWS_ONLY_CAPABILITY);
    capabilities.extend(crate::apps::advertised_capabilities());
    capabilities
}
`

const SOURCES: Record<string, string> = {
  "cmux-tui/crates/cmux-tui-core/src/server.rs": `pub const TABS_CAPABILITY: &str = "frontend-browser-tabs-v1";\npub const CLEAR_KEY_CAPABILITY: &str =\n    "clear-history-key-v1";\npub const WINDOWS_ONLY_CAPABILITY: &str = "windows-only-v1";\npub const PALETTE_CAPABILITY: &str = "palette-usage-v1";\n`,
  "cmux-tui/crates/cmux-tui-core/src/server/activity.rs": `pub const CAPABILITY: &str = "vm-activity-v1";\n`,
  "cmux-tui/crates/cmux-tui-core/src/server/cloud_conversations.rs": `pub(super) use crate::cloud_conversations::CLOUD_CONVERSATIONS_CAPABILITY as CAPABILITY;\n`,
  "cmux-tui/crates/cmux-tui-cloud-conversations/src/lib.rs": `pub const CLOUD_CONVERSATIONS_CAPABILITY: &str = "cloud-conversations-v1";\n`,
  "cmux-tui/crates/cmux-tui-core/src/state/folder.rs": `pub const CAPABILITY: &str = "agent-folder-v1";\n`,
  "cmux-tui/crates/cmux-tui-core/src/image_paste.rs": `pub const CAPABILITY: &str = "image-paste-v1";\n`,
  "cmux-tui/crates/cmux-tui-core/src/apps.rs": `pub const CAPABILITY: &str = "apps-v1";\n`,
  "cmux-tui/crates/cmux-tui-core/src/server/daemon_env_tests.rs": `const CAPABILITY: &str = "test-only-v1";\n`,
}
const TIP_ALWAYS = ["agent-folder-v1", "attach-identity-v1", "clear-history-key-v1", "frontend-browser-tabs-v1", "image-paste-v1", "vm-activity-v1"]

const WRANGLER = (dev: Record<string, string>) =>
  `{\n  "env": {\n    "development": {\n      "vars": { "ENVIRONMENT": "development"${Object.entries(dev).map(([k, v]) => `, "${k}": "${v}"`).join("")}, "X": "1" }\n    },\n    "staging": {\n      "vars": { "ENVIRONMENT": "staging", "X": "1" }\n    },\n    "production": {\n      "vars": { "ENVIRONMENT": "production", "X": "1" }\n    }\n  }\n}\n`

interface Fixture {
  capabilities?: Array<string>
  extraSource?: Array<string>
  imageCommittedAt?: string
  tipDate?: string
  team?: boolean
  wrangler?: Record<string, string>
  record?: boolean
}

const repo = (f: Fixture = {}) => {
  const root = mkdtempSync(join(tmpdir(), "rails-staleness-"))
  const write = (path: string, text: string) => {
    mkdirSync(dirname(join(root, path)), { recursive: true })
    writeFileSync(join(root, path), text)
  }
  for (const [path, text] of Object.entries(SOURCES)) write(path, text)
  write(CAPS_RS, capabilitiesRs(f.extraSource))
  const record = (snapshot: string, id: string) => ({
    snapshot,
    snapshot_id: id,
    smoke: { result: "PASSED" },
    ...(f.record === false ? {} : { cmux_tui: { commit: "a".repeat(40), committed_at: f.imageCommittedAt ?? "2026-10-08T00:00:00Z", capabilities: f.capabilities ?? [...TIP_ALWAYS, "cloud-conversations-v1"] } }),
  })
  const dev: Record<string, unknown> = { schema: 1, env: "dev", snapshot: "cmuxnp-dev-vmimg-hostrun6", snapshot_id: "sh-hostrun6", history: [record("cmuxnp-dev-vmimg-hostrun6", "sh-hostrun6"), record("cmuxnp-dev-vmimg-teamvm4", "sh-teamvm4")] }
  if (f.team !== false) dev.team_vm = { var: "TEAM_VM_SNAPSHOT", snapshot: "cmuxnp-dev-vmimg-teamvm4", snapshot_id: "sh-teamvm4" }
  write("images/cmux-vm/channels/dev.json", JSON.stringify(dev, null, 2))
  write("backend/apps/api/wrangler.jsonc", WRANGLER(f.wrangler ?? { CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-hostrun6", TEAM_VM_SNAPSHOT: "cmuxnp-dev-vmimg-teamvm4" }))
  const env = { ...process.env, GIT_AUTHOR_DATE: f.tipDate ?? "2026-10-09T00:00:00Z", GIT_COMMITTER_DATE: f.tipDate ?? "2026-10-09T00:00:00Z", GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" }
  const git = (...args: Array<string>) => execFileSync("git", ["-C", root, ...args], { env, stdio: "pipe" })
  git("init", "-q")
  git("add", "-A")
  git("commit", "-q", "-m", "fixture")
  return root
}

describe("image staleness guard", () => {
  it("reads the tip's capability list from source: vec, cfg pushes for Linux, aliased re-exports; runtime pushes are conditional", () => {
    const tip = tipCapabilities(treeReader(repo()))
    expect(tip.always).toEqual(TIP_ALWAYS)
    expect(tip.conditional).toEqual(["cloud-conversations-v1"])
  })

  it("passes when every channel image serves every capability the tip always serves", () => {
    const report = checkStaleness(treeReader(repo()))
    expect(report.problems).toEqual([])
    expect(report.images.map((i) => `${i.variable} ${i.snapshot}`)).toEqual(["CLOUD_FREESTYLE_SNAPSHOT cmuxnp-dev-vmimg-hostrun6", "TEAM_VM_SNAPSHOT cmuxnp-dev-vmimg-teamvm4"])
  })

  it("fails at once when the tip adds a capability the images lack (both images named)", () => {
    const report = checkStaleness(treeReader(repo({ extraSource: ["PALETTE_CAPABILITY"] })))
    expect(report.problems).toHaveLength(2)
    expect(report.problems.every((p) => p.includes("lacks 1 tip capability: palette-usage-v1"))).toBe(true)
    expect(report.images.map((i) => i.missing)).toEqual([["palette-usage-v1"], ["palette-usage-v1"]])
  })

  it("does not require a conditional capability", () => {
    expect(checkStaleness(treeReader(repo({ capabilities: TIP_ALWAYS }))).problems).toEqual([])
  })

  it("fails when the set differs (a capability the tip dropped) and the image is more than 7 days older than the tip", () => {
    const capabilities = [...TIP_ALWAYS, "dropped-v1"]
    expect(checkStaleness(treeReader(repo({ capabilities, imageCommittedAt: "2026-10-05T00:00:00Z" }))).problems).toEqual([])
    const old = checkStaleness(treeReader(repo({ capabilities, imageCommittedAt: "2026-09-30T00:00:00Z" })))
    expect(old.problems).toHaveLength(2)
    expect(old.problems[0]).toContain("9.0 days older than the tip (limit 7); not served by the tip: dropped-v1")
  })

  it("fails when an image has no recorded capability list", () => {
    const report = checkStaleness(treeReader(repo({ record: false })))
    expect(report.problems).toHaveLength(2)
    expect(report.problems[0]).toContain("has no cmux_tui.capabilities")
  })

  it("fails when the Worker boots an image the channel file does not point at", () => {
    const report = checkStaleness(treeReader(repo({ team: false })))
    expect(report.problems).toEqual([expect.stringContaining("env development boots TEAM_VM_SNAPSHOT=cmuxnp-dev-vmimg-teamvm4, but channels/dev.json does not point at it")])
  })

  it("reads a git revision the same way as the tree", () => {
    const root = repo({ extraSource: ["PALETTE_CAPABILITY"] })
    expect(checkStaleness(revReader(root, "HEAD")).problems).toEqual(checkStaleness(treeReader(root)).problems)
  })

  it("fails closed on a capability name it cannot resolve", () => {
    expect(() => tipCapabilities(treeReader(repo({ extraSource: ["NO_SUCH_CAPABILITY"] })))).toThrow(/cannot resolve capability NO_SUCH_CAPABILITY/)
  })

  it("resolves every capability of this checkout's cmux-tui source", () => {
    const tip = tipCapabilities(treeReader(REAL(".")))
    expect(tip.always.length).toBeGreaterThan(100)
    expect(tip.always).toContain("frontend-browser-tabs-v1")
    expect(tip.conditional).toContain("terminal-reaper-active-v1")
  })
})
