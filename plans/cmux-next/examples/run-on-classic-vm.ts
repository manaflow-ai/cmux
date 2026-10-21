// Runs an org workflow spec step by step on a real Cloud VM, with the same step executor the
// automation Workflow uses (backend/apps/api/src/automation-machine.ts) and a journal file that
// plays the part of the Workflow's step.do journal. Proof tool for org-workflows-DESIGN.md
// section 7, not a product path: the port is the classic `cmux vm exec` (it has no stdin, so the
// stdin goes as base64 in argv; it runs as the work user, so `sudo -n` gives the root exec the
// product driver has).
//
//   bun run-on-classic-vm.ts SPEC.json --vm vm-… --run run_… --journal FILE [--cmux PATH --socket PATH]
import { readFileSync, existsSync, appendFileSync } from "node:fs"
import { spawnSync } from "node:child_process"
import { runMachineStep, type MachineExec, type StepOutcome } from "../../../backend/apps/api/src/automation-machine.ts"

const arg = (name: string, def?: string) => {
  const i = process.argv.indexOf(`--${name}`)
  const v = i > 0 ? process.argv[i + 1] : def
  if (v === undefined) throw new Error(`--${name} is required`)
  return v
}
const spec = JSON.parse(readFileSync(process.argv[2]!, "utf8"))
const vm = arg("vm"), run = arg("run"), journalPath = arg("journal")
const cmux = arg("cmux", "/Applications/cmux.app/Contents/Resources/bin/cmux"), socket = arg("socket", `${process.env.HOME}/.local/state/cmux/cmux.sock`)

let execCalls = 0
const port: MachineExec = {
  exec: async (_machine, command, stdin, timeoutMs) => {
    execCalls++
    const b64 = stdin ? Buffer.from(stdin).toString("base64") : ""
    const script = 'if [ -n "$1" ]; then printf %s "$1" | base64 -d | bash -c "$2"; else bash -c "$2" </dev/null; fi'
    const r = spawnSync(cmux, ["--socket", socket, "vm", "exec", "--json", "--timeout", String(Math.min(900, Math.ceil(timeoutMs / 1000))), vm, "--", "sudo", "-n", "bash", "-c", script, "_", b64, command], { encoding: "utf8", maxBuffer: 64 << 20 })
    try {
      const j = JSON.parse(r.stdout)
      return { ok: true, exitCode: j.exit_code ?? j.exitCode ?? -1, stdout: j.stdout ?? "", stderr: j.stderr ?? "" }
    } catch {
      return { ok: false, refusal: "provider_failed" }
    }
  }
}

const journal = new Map<number, StepOutcome>()
if (existsSync(journalPath)) for (const line of readFileSync(journalPath, "utf8").split("\n").filter(Boolean)) {
  const e = JSON.parse(line)
  if (e.run === run) journal.set(e.step, e.outcome)
}
const outputs = new Map<number, string>()
const steps = spec.body.steps
for (let i = 0; i < steps.length; i++) {
  const s = steps[i]
  const started = Date.now()
  let outcome = journal.get(i)
  const replayed = outcome !== undefined
  if (!outcome) {
    const input = s.input_from === undefined ? null : (outputs.get(s.input_from) ?? null)
    outcome = await runMachineStep(port, s, { run, index: i }, input)
    appendFileSync(journalPath, JSON.stringify({ run, step: i, outcome }) + "\n")
  }
  console.log(JSON.stringify({ run, step: i, type: s.type, replayed, ms: Date.now() - started, ...outcome }))
  if (!outcome.ok) process.exit(1)
  outputs.set(i, outcome.output)
}
console.log(JSON.stringify({ run, state: "succeeded", execCalls }))
