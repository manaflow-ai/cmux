import { describe, expect, test } from "bun:test"
import { FakeHost } from "../../../cmux-tui/crates/cmux-app-host/js/test/fake-host.ts"

const bundle = await Bun.build({
  entrypoints: [new URL("./fixtures/inventory-runtime.ts", import.meta.url).pathname],
  format: "iife", target: "browser"
})
if (!bundle.success) throw new Error(bundle.logs.map(String).join("\n"))
const source = await bundle.outputs[0]!.text()
const ok = (value: unknown) => ({ ok: true, body: { value } })
const refused = (code: string) => ({ ok: false, body: { code, message: code, retryable: false } })
const local = { id: "local", name: "This Mac", origin: "local", status: "running" }
const server = { id: "server", name: "Server", origin: "server", status: "running" }
const entry = (version: string) => ({
  cli: "codex", installed: true, version, latest: null, install_method: "npm",
  updatable: false, accounts: [], auth_status: "missing"
})
const inventory = (machine: string, version: string) => ok({ machine, clis: [entry(version)], complete: false })
function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((r) => { resolve = r })
  return { promise, resolve }
}
function create() {
  const host = new FakeHost(source, {
    app: { id: "cmux/agents", version: "0.1.0", locale: "en" }, apiVersion: "1.0.0",
    settings: { variant: "byMachine", showMissing: true }
  })
  host.handlers = {
    "machine.list": () => ok([local, server]),
    "agent_cli.list": ({ machine }) => inventory(machine, "1.0.0")
  }
  return host
}
const snapshot = (host: FakeHost) => JSON.parse(host.eval("JSON.stringify(__cmuxAppExports.snapshot())"))
const version = (host: FakeHost, machine = "server") => snapshot(host).inventories[machine]?.entries[0]?.version
const read = (host: FakeHost, machine = "server") => host.eval(`__cmuxAppExports.read(${JSON.stringify(machine)})`)
const refresh = (host: FakeHost) => host.eval("__cmuxAppExports.refresh()")
async function mount(host: FakeHost) {
  host.mount("pane", "renderPane", { locale: "en" })
  await host.settle()
}

describe("owner-fenced inventory refresh", () => {
  test("discovery explicitly requests the admitted machine catalog", async () => {
    const host = create()
    host.handlers["machine.list"] = ({ catalog }) => ok(catalog === true ? [local, server] : [local])
    await mount(host)
    expect(snapshot(host).machines.map((m: { id: string }) => m.id)).toEqual(["local", "server"])
    expect(version(host)).toBe("1.0.0")
    expect(host.calls.find((c) => c.name === "machine.list")?.params).toEqual({ catalog: true })
  })

  test("matching owners populate their own rows without polling or execution", async () => {
    const host = create()
    await mount(host)
    expect(version(host)).toBe("1.0.0")
    expect(version(host, "local")).toBe("1.0.0")
    expect(host.timers.size).toBe(0)
    expect(host.calls.every((c) => c.name === "machine.list" || c.name === "agent_cli.list")).toBe(true)
  })

  test("a foreign or missing owner echo never populates another machine", async () => {
    for (const machine of ["local", "unknown", "", undefined]) {
      const host = create()
      host.handlers["agent_cli.list"] = (p) => p.machine === "local"
        ? inventory("local", "1.0.0") : ok({ machine, clis: [entry("9.9.9")], complete: true })
      await mount(host)
      const state = snapshot(host).inventories
      expect(state.local.entries[0]?.version).toBe("1.0.0")
      expect(state.server.entries).toEqual([])
      expect(state.server.complete).toBe(false)
      expect(state.server.error?.code).toBe("machine.owner_mismatch")
    }
  })

  test("a late older read cannot overwrite a newer result", async () => {
    const host = create()
    await mount(host)
    const older = deferred<ReturnType<typeof inventory>>()
    host.handlers["agent_cli.list"] = () => older.promise
    const oldRead = read(host)
    await host.settle()
    host.handlers["agent_cli.list"] = () => inventory("server", "2.0.0")
    await read(host)
    older.resolve(inventory("server", "0.1.0"))
    await oldRead
    expect(version(host)).toBe("2.0.0")
  })

  test("an older discovery cannot re-admit a removed server or start its read", async () => {
    const host = create()
    const oldCatalog = deferred<ReturnType<typeof ok>>()
    host.handlers["machine.list"] = () => oldCatalog.promise
    await mount(host)
    host.handlers["machine.list"] = () => ok([local])
    await refresh(host)
    const calls = host.calls.length
    oldCatalog.resolve(ok([local, server]))
    await host.settle()
    expect(snapshot(host).machines.map((m: { id: string }) => m.id)).toEqual(["local"])
    expect(host.calls.length).toBe(calls)
  })

  test("removal and re-admission cannot resurrect an old inventory reply", async () => {
    const host = create()
    await mount(host)
    const older = deferred<ReturnType<typeof inventory>>()
    host.handlers["agent_cli.list"] = () => older.promise
    const oldRead = read(host)
    await host.settle()
    host.handlers["machine.list"] = () => ok([local])
    host.handlers["agent_cli.list"] = ({ machine }) => inventory(machine, "2.0.0")
    await refresh(host)
    expect(snapshot(host).inventories.server).toBeUndefined()
    host.handlers["machine.list"] = () => ok([local, server])
    await refresh(host)
    older.resolve(inventory("server", "0.1.0"))
    await oldRead
    expect(version(host)).toBe("2.0.0")
  })

  test("a discovery refusal clears observations and never falls back to this Mac", async () => {
    for (const code of ["machine.unavailable", "scope.missing"]) {
      const host = create()
      await mount(host)
      host.handlers["machine.list"] = () => refused(code)
      const reads = host.calls.filter((c) => c.name === "agent_cli.list").length
      await refresh(host)
      expect(snapshot(host).machines).toEqual([])
      expect(snapshot(host).inventories).toEqual({})
      expect(host.calls.filter((c) => c.name === "agent_cli.list").length).toBe(reads)
    }
  })

  test("an old host without discovery retains anonymous local reads", async () => {
    const host = create()
    host.handlers["machine.list"] = () => refused("operation.unsupported")
    host.handlers["agent_cli.list"] = () => ok({ clis: [entry("1.0.0")] })
    await mount(host)
    expect(version(host, "")).toBe("1.0.0")
  })

  test("an invalidation re-read wins over an inventory read already in flight", async () => {
    const host = create()
    await mount(host)
    const older = deferred<ReturnType<typeof inventory>>()
    host.handlers["agent_cli.list"] = () => older.promise
    const oldRead = read(host)
    await host.settle()
    host.handlers["agent_cli.list"] = ({ machine }) => inventory(machine, "2.0.0")
    host.emit("agent_cli.changed", {})
    await host.settle()
    older.resolve(inventory("server", "0.1.0"))
    await oldRead
    expect(version(host)).toBe("2.0.0")
    expect(snapshot(host).inventories.server.loading).toBe(false)
  })

  test("unimplemented payload streams and invalidation payloads cannot supply observations", async () => {
    const host = create()
    await mount(host)
    host.emit("agent_cli.watch", { machine: "unknown", cli: "codex", entry: entry("9.9.9") })
    host.emit("agent_cli.watch", { machine: "server", cli: "codex", entry: { ...entry("9.9.9"), cli: "claude" } })
    host.emit("agent_cli.watch", { machine: "server", cli: "codex", entry: entry("9.9.9") })
    await host.settle()
    expect(version(host)).toBe("1.0.0")
    host.emit("agent_cli.changed", { machine: "unknown", cli: "codex", entry: entry("9.9.9") })
    await host.settle()
    expect(snapshot(host).inventories.unknown).toBeUndefined()
    expect(version(host)).toBe("1.0.0")
  })

  test("server-only discovery never offers the local Accounts fallback", async () => {
    const host = create()
    host.handlers["machine.list"] = () => ok([server])
    host.handlers["agent_cli.sign_in"] = () => refused("operation.unsupported")
    host.handlers["action.run"] = () => ok({})
    await mount(host)
    await host.eval('__cmuxAppExports.signIn("server", "codex")')
    expect(host.calls.filter((c) => c.name === "action.run")).toEqual([])
  })

  test("the local Accounts fallback still works on explicit and legacy local routes", async () => {
    for (const legacy of [false, true]) {
      const host = create()
      host.handlers["machine.list"] = () => legacy ? refused("operation.unsupported") : ok([local])
      host.handlers["agent_cli.list"] = ({ machine }) => inventory(machine ?? "", "1.0.0")
      host.handlers["agent_cli.sign_in"] = () => refused("operation.unsupported")
      host.handlers["action.run"] = () => ok({})
      await mount(host)
      await host.eval(`__cmuxAppExports.signIn(${JSON.stringify(legacy ? "" : "local")}, "codex")`)
      expect(host.calls.filter((c) => c.name === "action.run").map((c) => c.params.id)).toEqual(["accounts.reauthenticate"])
    }
  })

  test("a local route removed while sign-in is pending cannot trigger a fallback", async () => {
    const host = create()
    await mount(host)
    const pending = deferred<ReturnType<typeof refused>>()
    host.handlers["agent_cli.sign_in"] = () => pending.promise
    const signIn = host.eval('__cmuxAppExports.signIn("local", "codex")')
    await host.settle()
    host.handlers["machine.list"] = () => ok([server])
    await refresh(host)
    pending.resolve(refused("operation.unsupported"))
    await signIn
    expect(host.calls.filter((c) => c.name === "action.run")).toEqual([])
    expect(Object.keys(snapshot(host).jobs).some((k) => k.startsWith("local/"))).toBe(false)
  })

  test("cache invalidations re-discover and re-read admitted owners without live checks", async () => {
    const host = create()
    await mount(host)
    host.handlers["agent_cli.list"] = ({ machine }) => inventory(machine, "2.0.0")
    const before = host.calls.length
    host.emit("agent_cli.changed", {})
    await host.settle()
    expect(version(host)).toBe("2.0.0")
    expect(version(host, "local")).toBe("2.0.0")
    expect(host.calls.slice(before).find((c) => c.name === "machine.list")?.params).toEqual({ catalog: true })
    expect(host.calls.slice(before).filter((c) => c.name === "agent_cli.list").map((c) => c.params)).toEqual([
      { machine: "local" }, { machine: "server" }
    ])
    expect(host.timers.size).toBe(0)
  })

  test("cache invalidations never import claimed rows or machine selectors from the event", async () => {
    const host = create()
    await mount(host)
    host.handlers["agent_cli.list"] = ({ machine }) => inventory(machine, "2.0.0")
    host.emit("agent_cli.changed", { machine: "unknown", cli: "codex", entry: entry("9.9.9"), command: "do not run" })
    await host.settle()
    expect(snapshot(host).inventories.unknown).toBeUndefined()
    expect(version(host)).toBe("2.0.0")
    expect(host.calls.every((c) => c.name === "machine.list" || c.name === "agent_cli.list")).toBe(true)
  })

  test("cache invalidations coalesce while a batch is pending and retain one follow-up", async () => {
    const host = create()
    await mount(host)
    const pending = deferred<ReturnType<typeof ok>>()
    host.handlers["machine.list"] = () => pending.promise
    const count = () => host.calls.filter((c) => c.name === "machine.list").length
    const before = count()
    host.emit("agent_cli.changed", {})
    await host.settle()
    expect(count()).toBe(before + 1)
    for (let i = 0; i < 50; i++) host.emit("agent_cli.changed", {})
    await host.settle()
    expect(count()).toBe(before + 1)
    host.handlers["machine.list"] = () => ok([local, server])
    host.handlers["agent_cli.list"] = ({ machine }) => inventory(machine, "3.0.0")
    pending.resolve(ok([local, server]))
    await host.settle()
    expect(count()).toBe(before + 2)
    expect(version(host)).toBe("3.0.0")
    expect(host.timers.size).toBe(0)
  })


  test("an invalidation discovery refusal clears admission without local fallback", async () => {
    for (const code of ["scope.missing", "permission.denied", "transport.unavailable"]) {
      const host = create()
      await mount(host)
      const before = host.calls.filter((c) => c.name === "agent_cli.list").length
      host.handlers["machine.list"] = () => refused(code)
      host.emit("agent_cli.changed", {})
      await host.settle()
      expect(snapshot(host).machines).toEqual([])
      expect(snapshot(host).inventories).toEqual({})
      expect(host.calls.filter((c) => c.name === "agent_cli.list").length).toBe(before)
      expect(host.timers.size).toBe(0)
    }
  })

  test("an invalidation withdraws an owner before its older read completes", async () => {
    const host = create()
    await mount(host)
    const pending = deferred<ReturnType<typeof inventory>>()
    host.handlers["agent_cli.list"] = ({ machine }) => machine === "server" ? pending.promise : inventory(machine, "1.0.0")
    const oldRead = read(host)
    await host.settle()
    host.handlers["machine.list"] = () => ok([local])
    host.emit("agent_cli.changed", {})
    await host.settle()
    expect(snapshot(host).machines.map((m: { id: string }) => m.id)).toEqual(["local"])
    expect(snapshot(host).inventories.server).toBeUndefined()
    pending.resolve(inventory("server", "9.9.9"))
    await oldRead
    await host.settle()
    expect(snapshot(host).inventories.server).toBeUndefined()
  })

})
