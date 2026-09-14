import { JSONSchemaInput, JSONSchemaStore, InputData, quicktype, type JSONSchema } from "quicktype-core";
import { z } from "zod";
import { mkdir, readFile, writeFile, readdir, unlink } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import * as common from "../src/contracts/common";
import * as requests from "../src/contracts/requests";
import * as responses from "../src/contracts/responses";

const check = process.argv.includes("--check");
const packageRoot = resolve(import.meta.dir, "..");
const registry = z.registry<z.core.JSONSchemaMeta>();
const schemas = new Map<string, z.ZodType>();
const moduleEntries = [common, requests, responses];
for (const exports of moduleEntries) {
  for (const [name, value] of Object.entries(exports)) {
    if (name.endsWith("Schema") && value instanceof z.ZodType) {
      const wireName = "V2" + name.slice(0, -6);
      value.register(registry, { id: wireName });
      schemas.set(wireName, value);
    }
  }
}
common.DeviceMetadataSchema.shape.platform.register(registry, { id: "V2Platform" });
const uri = (id: string) => `https://contracts.cmux.invalid/iroh-v2/${id}.json`;
const exported = z.toJSONSchema(registry, { target: "draft-7", unrepresentable: "throw", uri });

/** Generation can only read schemas exported in this invocation. */
class LocalSchemaStore extends JSONSchemaStore {
  async fetch(address: string): Promise<JSONSchema | undefined> {
    const match = Object.entries(exported.schemas).find(([id]) => uri(id) === address);
    if (!match) throw new Error(`Unexpected external schema: ${address}`);
    return match[1];
  }
}
const input = new JSONSchemaInput(new LocalSchemaStore());
async function emit(path: string, contents: string): Promise<void> {
  const absolute = resolve(packageRoot, path);
  if (check) {
    const prior = await readFile(absolute, "utf8").catch(() => "");
    if (prior !== contents) throw new Error(`Generated contract is stale: ${path}`);
  } else {
    await mkdir(dirname(absolute), { recursive: true });
    await writeFile(absolute, contents);
  }
}
for (const [name, schema] of Object.entries(exported.schemas)) {
  await emit(`generated/${name}.schema.json`, JSON.stringify(schema, null, 2) + "\n");
  // Generate each operation separately. Flattening a union into an object with
  // optional fields would lose the exact request/response shape on clients.
  if (name !== "V2Request" && name !== "V2Response") await input.addSource({ name, uris: [uri(name)] });
}
const inputData = new InputData();
inputData.addInput(input);
const swift = await quicktype({
  lang: "swift", inputData,
  rendererOptions: {
    "access-level": "public", "struct-or-class": "struct", "initializers": "false",
    "protocol": "equatable", "sendable": "true", "just-types": "false",
  },
});
const typescript = await quicktype({
  lang: "typescript", inputData,
  rendererOptions: { "just-types": "true", "prefer-unions": "true" },
});
const swiftText = swift.lines.join("\n") + "\n";
if (/(?:class|struct|typealias)\s+JSONAny|:\s*\[?JSONAny/.test(swiftText)) throw new Error("Wire contracts must not generate unrestricted JSONAny");
await emit("../../Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/ControlPlane/V2WireModels.swift", swiftText);
const requestNames = Object.entries(requests).filter(([k,v]) => k.endsWith("Schema") && k !== "RequestSchema" && k !== "SocketSetupSchema" && v instanceof z.ZodType).map(([k]) => "V2" + k.slice(0,-6));
const responseNames = Object.entries(responses).filter(([k,v]) => k.endsWith("ResponseSchema") && k !== "ResponseSchema" && v instanceof z.ZodType).map(([k]) => "V2" + k.slice(0,-6));
await emit("generated/wire.ts", typescript.lines.join("\n") + `\nexport type V2Request = ${requestNames.join(" | ")};\nexport type V2Response = ${responseNames.join(" | ")};\n`);
const assertions: string[] = [];
for (const [index,exports] of moduleEntries.entries()) {
  for (const [name,value] of Object.entries(exports)) {
    if (name.endsWith("Schema") && value instanceof z.ZodType) {
      const wireName = "V2" + name.slice(0,-6);
      assertions.push(`export type ${wireName}ServerToWire = Assert<WireShape<z.infer<typeof M${index}.${name}>> extends WireShape<W.${wireName}> ? true : false>;`);
      assertions.push(`export type ${wireName}WireToServer = Assert<WireShape<W.${wireName}> extends WireShape<z.infer<typeof M${index}.${name}>> ? true : false>;`);
    }
  }
}
await emit("src/contracts/generated-compatibility.ts", `// Generated. Both directions must preserve every operation's wire shape.\nimport type { z } from "zod";\nimport type * as W from "../../generated/wire";\nimport type * as M0 from "./common";\nimport type * as M1 from "./requests";\nimport type * as M2 from "./responses";\ntype Assert<T extends true> = T;\n// JSON omits undefined object properties. Array cardinality remains a server\n// validation constraint; Swift arrays and Zod inference represent element types.\ntype WireShape<T> = T extends readonly (infer Item)[] ? WireShape<Item>[] : T extends object ? { [K in keyof T]: WireShape<Exclude<T[K], undefined>> } : T;\n${assertions.join("\n")}\n`);
const wanted = new Set(Object.keys(exported.schemas).map(name => name + ".schema.json"));
for (const name of await readdir(resolve(packageRoot,"generated"))) {
  if (name.endsWith(".schema.json") && !wanted.has(name)) {
    if (check) throw new Error(`Retired generated schema remains: ${name}`);
    await unlink(resolve(packageRoot,"generated",name));
  }
}
console.log(`${check ? "Verified" : "Generated"} ${Object.keys(exported.schemas).length} named schemas and exact Swift/TypeScript operation models`);
