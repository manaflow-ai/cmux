// cmux-extension-sdk/testing: test an extension the way cmux runs it, with no cmux running.
//
//     import { FakeHost, pack, validatePackage } from "cmux-extension-sdk/testing"
//
//     const host = new FakeHost(await pack(dir), { app: { id: "local/my-ext", version: "0.1.0" }, apiVersion: "1.0.0" })
//     host.handlers = { "workspace.list": () => ({ ok: true, body: { value: [] } }) }
//     host.mount("s", "renderSection")
//     await host.settle()
//
// These are the runtime's own pieces (cmux-app-host), not copies: the fake host loads the same
// runtime bundle cmux ships, and the validator is the one `cmux apps validate` runs. Publishing the
// package copies the files listed in runtime-files.json into it at the same relative paths.
import { existsSync, readFileSync } from "node:fs"

export { FakeHost, app, type Op, type OpHandler, type PaletteBatch } from "../../../cmux-app-host/js/test/fake-host.ts"
export { pack } from "../../../cmux-app-host/tools/pack.ts"
export { validatePackage, type ValidationResult } from "../../../cmux-app-host/tools/validate-manifest.ts"
export { SchemaValidator, type SchemaError } from "../../../cmux-app-host/tools/json-schema.ts"

const host = new URL("../../../cmux-app-host/", import.meta.url)
const json = (path: string) => JSON.parse(readFileSync(new URL(path, host), "utf8"))

/** The v2 manifest schema (`cmux-app.v2.json`), for `new SchemaValidator(manifestSchema())`. */
export function manifestSchema(): Record<string, unknown> {
  return json("schema/v2/cmux-app.schema.json")
}

/** The contract of a place or interface an extension implements (`"cmux.section/1"`), or undefined when cmux has none by that name. */
export function interfaceContract(name: string): Record<string, unknown> | undefined {
  const [iface, major] = name.split("/")
  if (!iface || !major || !/^[a-z0-9.]+$/.test(iface) || !/^\d+$/.test(major)) return undefined
  const path = `interfaces/${iface}/${major}.json`
  return existsSync(new URL(path, host)) ? json(path) : undefined
}
