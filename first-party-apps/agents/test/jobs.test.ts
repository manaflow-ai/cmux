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
const started = (job: string) => ok({ job, terminal: `terminal_${job}` })
const snapshot = (host: FakeHost) => JSON.parse(host.eval("JSON.stringify(__cmuxAppExports.snapshot())"))
const job = (host: FakeHost, machine = "server") => snapshot(host).jobs[`${machine}/codex`]
const invoke = (host: FakeHost, action: string, machine = "server", cli = "codex") =>
  host.eval(`__cmuxAppExports.${action}(${JSON.stringify(machine)}, ${JSON.stringify(cli)}, "npm")`)
const refresh = (host: FakeHost) => host.eval("__cmuxAppExports.refresh()")
function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((r) => { resolve = r })
  return { promise, resolve }
}
async function create() {
  const host = new FakeHost(source, {
    app: { id: "cmux/agents", version: "0.1.0", locale: "en" }, apiVersion: "1.0.0",
    settings: { variant: "byMachine", showMissing: true }
  })
  host.handlers = {
    "machine.list": () => ok([local, server]),
    "agent_cli.list": ({ machine }) => ok({ machine, clis: [], complete: false })
  }
  host.mount("pane", "renderPane", { locale: "en" })
  await host.settle()
  return host
}
const cases = [["update", "agent_cli.update"], ["install", "agent_cli.install"], ["signIn", "agent_cli.sign_in"]] as const

describe("selected-owner job admission", () => {
  for (const [action, op] of cases) {
    test(`${action} sends once while requested or running, including competing actions`, async () => {
      const host = await create()
      const pending = deferred<ReturnType<typeof started>>()
      for (const [, name] of cases) host.handlers[name] = () => pending.promise
      const first = invoke(host, action)
      await host.settle()
      // Do not await a duplicate: an incorrect implementation shares the held host response.
      for (const [other] of cases) void invoke(host, other)
      await host.settle()
      expect(host.calls.filter((c) => c.name.startsWith("agent_cli.") && c.name !== "agent_cli.list")).toHaveLength(1)
      pending.resolve(started("first"))
      await first
      await host.settle()
      for (const [other] of cases) await invoke(host, other)
      expect(host.calls.filter((c) => c.name.startsWith("agent_cli.") && c.name !== "agent_cli.list")).toHaveLength(1)
      expect(job(host)?.phase).toBe("running")
      expect(host.calls.find((c) => c.name === op)?.params.machine).toBe("server")
    })

    test(`${action} refuses an undiscovered owner before sending any operation`, async () => {
      const host = await create()
      host.handlers[op] = () => started("foreign")
      await invoke(host, action, "unknown")
      expect(host.calls.filter((c) => c.name === op)).toHaveLength(0)
      expect(snapshot(host).jobs).toEqual({})
    })
  }

  for (const answer of [started("old"), refused("scope.missing")]) {
    test(`a removed and re-admitted owner's older ${answer.ok ? "success" : "refusal"} cannot settle its new request`, async () => {
      const host = await create()
      const old = deferred<ReturnType<typeof ok> | ReturnType<typeof refused>>()
      host.handlers["agent_cli.update"] = () => old.promise
      const first = invoke(host, "update")
      await host.settle()
      host.handlers["machine.list"] = () => ok([local])
      await refresh(host)
      host.handlers["machine.list"] = () => ok([local, server])
      await refresh(host)
      const next = deferred<ReturnType<typeof started>>()
      host.handlers["agent_cli.update"] = () => next.promise
      const second = invoke(host, "update")
      await host.settle()
      old.resolve(answer)
      await first
      expect(job(host)?.phase).toBe("requested")
      next.resolve(started("new"))
      await second
      expect(job(host)?.job).toBe("new")
      expect(job(host)?.phase).toBe("running")
    })
  }

  test("an old local refusal cannot launch Accounts after removal and re-admission", async () => {
    const host = await create()
    const old = deferred<ReturnType<typeof refused>>()
    host.handlers["agent_cli.sign_in"] = () => old.promise
    host.handlers["action.run"] = () => ok({})
    const first = invoke(host, "signIn", "local")
    await host.settle()
    host.handlers["machine.list"] = () => ok([server])
    await refresh(host)
    host.handlers["machine.list"] = () => ok([local, server])
    await refresh(host)
    old.resolve(refused("operation.unsupported"))
    await first
    expect(host.calls.filter((c) => c.name === "action.run")).toHaveLength(0)
    expect(job(host, "local")).toBeUndefined()
  })

  test("ordinary rediscovery preserves a pending job and different owners remain independent", async () => {
    const host = await create()
    const pending = deferred<ReturnType<typeof started>>()
    host.handlers["agent_cli.update"] = ({ machine }) => machine === "server" ? pending.promise : started("local")
    const first = invoke(host, "update")
    await host.settle()
    await refresh(host)
    await invoke(host, "update", "local")
    expect(job(host)?.phase).toBe("requested")
    expect(job(host, "local")?.job).toBe("local")
    pending.resolve(started("server"))
    await first
    expect(job(host)?.job).toBe("server")
    expect(host.timers.size).toBe(0)
  })

  test("a definitive refusal permits a new explicit request", async () => {
    const host = await create()
    host.handlers["agent_cli.update"] = () => refused("scope.missing")
    await invoke(host, "update")
    expect(job(host)?.phase).toBe("refused")
    host.handlers["agent_cli.update"] = () => started("retry")
    await invoke(host, "update")
    expect(job(host)?.job).toBe("retry")
    expect(host.calls.filter((c) => c.name === "agent_cli.update")).toHaveLength(2)
  })

  test("the Accounts hop keeps admission busy across all action kinds", async () => {
    const host = await create()
    host.handlers["agent_cli.sign_in"] = () => refused("operation.unsupported")
    const pending = deferred<ReturnType<typeof ok>>()
    host.handlers["action.run"] = () => pending.promise
    const first = invoke(host, "signIn", "local")
    await host.settle()
    for (const [action] of cases) await invoke(host, action, "local")
    expect(host.calls.filter((c) => c.name === "action.run")).toHaveLength(1)
    expect(host.calls.filter((c) => c.name.startsWith("agent_cli.") && c.name !== "agent_cli.list")).toHaveLength(1)
    pending.resolve(ok({}))
    await first
    expect(job(host, "local")?.job).toBe("accounts.reauthenticate")
  })

  test("an older Accounts answer cannot settle a re-admitted owner's next request", async () => {
    const host = await create()
    host.handlers["agent_cli.sign_in"] = () => refused("operation.unsupported")
    const old = deferred<ReturnType<typeof ok>>()
    host.handlers["action.run"] = () => old.promise
    const first = invoke(host, "signIn", "local")
    await host.settle()
    host.handlers["machine.list"] = () => ok([server])
    await refresh(host)
    host.handlers["machine.list"] = () => ok([local, server])
    await refresh(host)
    const next = deferred<ReturnType<typeof started>>()
    host.handlers["agent_cli.update"] = () => next.promise
    const second = invoke(host, "update", "local")
    await host.settle()
    old.resolve(ok({}))
    await first
    expect(job(host, "local")?.phase).toBe("requested")
    next.resolve(started("new"))
    await second
    expect(job(host, "local")?.job).toBe("new")
  })

  test("different CLIs on the same owner have independent admission", async () => {
    const host = await create()
    const pending = deferred<ReturnType<typeof started>>()
    host.handlers["agent_cli.update"] = ({ cli }) => cli === "codex" ? pending.promise : started("claude")
    const first = invoke(host, "update")
    await host.settle()
    await invoke(host, "update", "server", "claude")
    expect(snapshot(host).jobs["server/claude"]?.job).toBe("claude")
    expect(job(host)?.phase).toBe("requested")
    pending.resolve(started("codex"))
    await first
    expect(job(host)?.job).toBe("codex")
  })
})
