// User actions. Each one runs from a tap (the gesture token makes the host
// run it with origin user) and only asks the host: the owner opens a visible
// terminal and runs the CLI's own update, install or login command there.
// The app never runs a command or sees a credential.

import { type InstallMethod, providerFor } from "./model/providers.ts"
import { call } from "./ops.ts"
import { gesture, withGesture } from "./runtime.ts"
import { dispatchJob, isCurrentJob, load, machineById, requestJob } from "./store.ts"
import type { JobKind } from "./model/jobs.ts"

type Started = { job: string; terminal?: string | null }

async function run(kind: JobKind, machine: string, cli: string, op: string, params: Record<string, unknown>, token: string | null) {
  const owner = machineById(machine)
  const request = requestJob(machine, cli, kind)
  if (!owner || !request) return null
  const current = () => isCurrentJob(machine, cli, request) && machineById(machine)?.origin === owner.origin
  const r = await call<Started>(op, { ...(machine ? { machine } : {}), cli, ...params }, withGesture(token))
  if (!current()) return null
  const provider = providerFor(cli)?.accountsProvider
  if (!r.ok && r.error.code === "operation.unsupported" && kind === "sign_in" && provider && owner.origin === "local") {
    // Keep the same pending request across the legacy local Accounts hop.
    // A second tap cannot create another operation while this answer is pending.
    const a = await call<unknown>("action.run", { id: "accounts.reauthenticate", args: { provider } }, withGesture(token))
    if (current()) dispatchJob(machine, cli, a.ok
      ? { type: "started", job: "accounts.reauthenticate", terminal: null }
      : { type: "refused", error: a.error.code })
    return r
  }
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
export function signIn(machine: string, cli: string) {
  return run("sign_in", machine, cli, "agent_cli.sign_in", {}, gesture())
}

export function refresh() {
  return load(true)
}

export function openPane(token: string | null = gesture()) {
  return call<unknown>("app.pane.open", { kind: "agentHub" }, withGesture(token))
}
