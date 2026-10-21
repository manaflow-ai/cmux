// Test entry: exercise the production store, actions and view in the real JS runtime.
import { renderPane } from "../../src/main.ts"
import { install, signIn, update } from "../../src/actions.ts"
import { byMachine, jobs, load, loadMachine, machines, selected } from "../../src/store.ts"

;(globalThis as any).__cmuxAppExports = {
  renderPane,
  refresh: () => load(true),
  read: (machine: string) => loadMachine(machine, false),
  signIn,
  update,
  install,
  snapshot: () => ({ machines: machines(), inventories: byMachine(), jobs: jobs(), selected: selected() })
}
