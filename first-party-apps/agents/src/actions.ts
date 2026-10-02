// User actions. Each one runs from a tap (the gesture token makes the host
// run it with origin user) and only asks the host: the owner opens a visible
// terminal and runs the CLI's own update, install or login command there.
// The app never runs a command or sees a credential.

import { type InstallMethod, providerFor } from "./model/providers.ts"
import { call } from "./ops.ts"
import { gesture, withGesture } from "./runtime.ts"
import { dispatchJob, load, localMachine } from "./store.ts"
import type { JobKind } from "./model/jobs.ts"

type Started = { job: string; terminal?: string | null }

async function run(kind: JobKind, machine: string, cli: string, op: string, params: Record<string, unknown>, token: string | null) {
  dispatchJob(machine, cli, { type: "request", kind })
  const r = await call<Started>(op, { ...(machine ? { machine } : {}), cli, ...params }, withGesture(token))
  if (r.ok) dispatchJob(machine, cli, { type: "started", job: r.value.job, terminal: r.value.terminal ?? null })
  else dispatchJob(machine, cli, { type: "refused", error: r.error.code })
  return r
}

export function update(machine: string, cli: string) {
  return run("update", machine, cli, "agent_cli.update", {}, gesture())
}

export function install(machine: string, cli: string, method: InstallMethod) {
  return run("install", machine, cli, "agent_cli.install", { method }, gesture())
}

/**
 * Sign in with the CLI's own login in a terminal. Falls back to the existing
 * accounts action (`accounts.reauthenticate`, this Mac only) when the owner
 * has no agent_cli.sign_in yet.
 */
export async function signIn(machine: string, cli: string) {
  const token = gesture()
  const r = await run("sign_in", machine, cli, "agent_cli.sign_in", {}, token)
  const provider = providerFor(cli)?.accountsProvider
  const isLocal = !machine || machine === localMachine().id
  if (!r.ok && r.error.code === "operation.unsupported" && provider && isLocal) {
    dispatchJob(machine, cli, { type: "clear" })
    dispatchJob(machine, cli, { type: "request", kind: "sign_in" })
    const a = await call<unknown>("action.run", { id: "accounts.reauthenticate", args: { provider } }, withGesture(token))
    // The accounts screen owns that flow and reports through the next list.
    dispatchJob(machine, cli, a.ok ? { type: "started", job: "accounts.reauthenticate", terminal: null } : { type: "refused", error: a.error.code })
  }
}

export function refresh() {
  return load(true)
}

export function openPane() {
  return call<unknown>("app.pane.open", { kind: "agentHub" }, withGesture(gesture()))
}
