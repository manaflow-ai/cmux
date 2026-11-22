import { describe, expect, test } from "bun:test"
import { callsOf, makeHost, tap, texts, visible } from "./harness.ts"

const M = "m1"
const ADD = "Add MCP server: name command… or name https://…"

async function mount(fixture: string, exportName: string, settings: Record<string, unknown> = {}, overrides: Record<string, unknown> = {}) {
  const host = makeHost(fixture, settings, overrides)
  expect(host.mount(M, exportName, {})).toBe("")
  await host.settle(20)
  return host
}

function submit(host: ReturnType<typeof makeHost>, placeholder: string, text: string) {
  const id = host.findNode(M, (n) => n.type === "TextField" && n.props.placeholder === placeholder)!
  host.dispatch(M, id, "submit", { text, gesture: "gst_test" })
  return host.settle(10)
}

describe("variants", () => {
  for (const variant of ["unified", "byAgent", "byScope"]) {
    test(`${variant}: lists items for the current project and everywhere`, async () => {
      const host = await mount(variant, "renderPane", { variant })
      const t = texts(host, M)
      expect(t.some((s) => s.includes("release-notes"))).toBe(true)
      expect(t.some((s) => s.includes("linear"))).toBe(true)
      expect(callsOf(host, "skill.list")[0]!.params).toMatchObject({ roots: ["root_proj01"] })
      expect(callsOf(host, "workspace.root")[0]!.params).toEqual({ workspace: "workspace_2" })
    })

    test(`${variant}: Add plans a dry run, shows the diff, Apply accepts it with the gesture`, async () => {
      const host = await mount(variant, "renderPane", { variant })
      await submit(host, ADD, "docs https://docs.example.com/mcp")
      const [add] = callsOf(host, "mcp_server.add")
      expect(add!.params).toMatchObject({ dry_run: true, name: "docs", scope: "user", entry: { transport: "http", url: "https://docs.example.com/mcp" } })
      expect(add!.params.agents).toEqual(variant === "byAgent" ? ["claude"] : ["claude", "codex", "opencode", "gemini"])
      const t = texts(host, M)
      expect(t).toContain("Add docs everywhere")
      expect(t.some((s) => s.includes("~/.codex/config.toml"))).toBe(true)
      if (variant !== "byAgent") expect(t.some((s) => s.includes("[mcp_servers.docs]"))).toBe(true)
      // The secret in the fixture's config never reaches the screen.
      expect(t.join("\n")).not.toContain("fake-token-for-preview")
      await tap(host, M, "Apply")
      const [decide] = callsOf(host, "diff.decide")
      expect(decide!.params).toEqual({ diff: "diff_cfg01", decisions: [{ decision: "accept" }] })
      expect(decide!.options.gesture).toBe("gst_test")
      expect(texts(host, M)).toContain("Applied")
    })
  }

  test("unified: selecting a group shows source, requests, sandbox and per-agent switches", async () => {
    const host = await mount("unified", "renderPane", { variant: "unified" })
    await tap(host, M, "github")
    const t = texts(host, M)
    expect(t).toContain("Not sandboxed")
    expect(t).toContain("process:execute")
    expect(t).toContain("Secrets it reads: GITHUB_TOKEN")
    await tap(host, M, "Turn Off")
    expect(callsOf(host, "mcp_server.disable")[0]!.params).toMatchObject({ id: "mcp_03", agent: "codex", scope: "user", name: "github", dry_run: true })
    expect(texts(host, M)).toContain("Turn off github for Codex everywhere")
  })

  test("Open in Diffs asks for the user's diff renderer with the planned diff", async () => {
    const host = await mount("unified", "renderPane", { variant: "unified" })
    await submit(host, ADD, "docs https://docs.example.com/mcp")
    await tap(host, M, "Open in Diffs")
    const [open] = callsOf(host, "ui.open")
    expect(open!.params).toEqual({ interface: "cmux.diff.renderer/1", props: { diff: "diff_cfg01", layout: "unified" } })
    expect(open!.options.gesture).toBe("gst_test")
  })

  test("a stale apply re-plans and shows the new diff with a note", async () => {
    const host = await mount("stale", "renderPane", { variant: "unified" })
    await submit(host, ADD, "docs https://docs.example.com/mcp")
    await tap(host, M, "Apply")
    expect(callsOf(host, "mcp_server.add")).toHaveLength(2)
    expect(texts(host, M)).toContain("An agent changed these files after the first preview. This is the new diff.")
  })

  test("Cancel drops the plan without writing", async () => {
    const host = await mount("unified", "renderPane", { variant: "unified" })
    await submit(host, ADD, "docs https://docs.example.com/mcp")
    await tap(host, M, "Cancel")
    expect(callsOf(host, "diff.decide")).toHaveLength(0)
    expect(texts(host, M)).not.toContain("Add docs everywhere")
  })

  test("bad input never calls an op", async () => {
    const host = await mount("unified", "renderPane", { variant: "unified" })
    await submit(host, ADD, "docs http://insecure.example")
    await submit(host, "Install skill: git URL, owner/repo or store:id", "file:///etc")
    expect(callsOf(host, "mcp_server.add")).toHaveLength(0)
    expect(callsOf(host, "skill.install")).toHaveLength(0)
    expect(texts(host, M)).toContain("Only https and ssh git URLs can be installed")
  })

  test("install from owner/repo plans skill.install for every agent with skills", async () => {
    const host = await mount("unified", "renderPane", { variant: "unified" }, { "skill.install": { diff: "diff_sk", title: "Install", files: [{ path_label: "~/.claude/skills/x/SKILL.md", kind: "create", patch: "--- /dev/null\n+++ b/SKILL.md\n@@ -0,0 +1 @@\n+---\n" }], requests: ["process:execute"], sandbox: "contained" } })
    await submit(host, "Install skill: git URL, owner/repo or store:id", "acme/agent-skills//release-notes#v1.4.0")
    expect(callsOf(host, "skill.install")[0]!.params).toMatchObject({ dry_run: true, agents: ["claude", "codex", "opencode"], scope: "user", source: { git: "https://github.com/acme/agent-skills.git", ref: "v1.4.0", path: "release-notes" } })
    expect(texts(host, M)).toContain("Contained sandbox")
  })

  test("a config the owner cannot rewrite says so", async () => {
    const host = await mount("unparseable", "renderPane", { variant: "unified" })
    await submit(host, ADD, "docs https://docs.example.com/mcp")
    expect(texts(host, M)).toContain("The agent's config file has comments or errors; cmux does not rewrite it.")
  })
})

describe("section and states", () => {
  test("section: counts and the unsandboxed server that runs commands", async () => {
    const host = await mount("unified", "renderSection")
    const t = texts(host, M)
    expect(t).toContain("Skills")
    expect(t).toContain("github")
    const rows = visible(host, M).filter(([, n]) => n.type === "Row").map(([, n]) => [n.props.title, n.props.subtitle ?? null, n.props.badge ?? null])
    expect(rows).toEqual([["Skills", null, 4], ["MCP Servers", null, 5], ["github", "Runs commands without a sandbox", null]])
  })
  test("empty, error and missing ops", async () => {
    expect(texts(await mount("empty", "renderPane"), M)).toContain("No skills or MCP servers yet")
    expect(texts(await mount("error", "renderPane"), M)).toContain("Cannot read agent configuration")
    expect(texts(await mount("missing", "renderPane"), M)).toContain("Skill and MCP management is not available yet")
  })
  test("cycleVariant walks the three designs", async () => {
    const host = await mount("unified", "renderPane", {}, { "app.settings.set": {} })
    host.global.__cmuxAppRunCommand("cycleVariant", "{}", 1)
    await host.settle(5)
    expect(host.commandResults.get(1)?.body.value.variant).toBe("byAgent")
  })
})
