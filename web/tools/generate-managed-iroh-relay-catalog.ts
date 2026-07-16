import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Relay = {
  readonly id: string;
  readonly provider: string;
  readonly region: string;
  readonly url: string;
};

type Catalog = {
  readonly version: 1;
  readonly sequence: number;
  readonly relays: readonly Relay[];
};

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const sourcePath = resolve(repositoryRoot, "config/iroh/managed-relay-catalog.json");
const outputPaths = [
  resolve(repositoryRoot, "web/services/relay/generated/managedRelayCatalog.ts"),
  resolve(repositoryRoot, "workers/presence/src/generated/managedRelayCatalog.ts"),
];

function record(value: unknown): Record<string, unknown> | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  return value as Record<string, unknown>;
}

function validatedCatalog(value: unknown): Catalog {
  const source = record(value);
  if (
    source?.version !== 1 || typeof source.sequence !== "number" ||
    !Number.isSafeInteger(source.sequence) || source.sequence < 1
  ) {
    throw new Error("managed relay catalog requires version 1 and a positive integer sequence");
  }
  if (!Array.isArray(source.relays) || source.relays.length === 0) {
    throw new Error("managed relay catalog requires at least one relay");
  }

  const ids = new Set<string>();
  const urls = new Set<string>();
  const relays = source.relays.map((value, index): Relay => {
    const relay = record(value);
    const id = relay?.id;
    const provider = relay?.provider;
    const region = relay?.region;
    const rawURL = relay?.url;
    if (
      typeof id !== "string" || !/^[a-z0-9-]{1,32}$/.test(id) ||
      typeof provider !== "string" || provider.length === 0 ||
      typeof region !== "string" || region.length === 0 ||
      typeof rawURL !== "string"
    ) {
      throw new Error(`invalid managed relay at index ${index}`);
    }

    let url: URL;
    try {
      url = new URL(rawURL);
    } catch {
      throw new Error(`invalid managed relay URL at index ${index}`);
    }
    if (
      url.protocol !== "https:" || url.username !== "" || url.password !== "" ||
      url.pathname !== "/" || url.search !== "" || url.hash !== "" ||
      url.toString() !== rawURL
    ) {
      throw new Error(`managed relay URL must be a canonical HTTPS origin at index ${index}`);
    }
    if (ids.has(id) || urls.has(rawURL)) {
      throw new Error(`managed relay IDs and URLs must be unique at index ${index}`);
    }
    ids.add(id);
    urls.add(rawURL);
    return { id, provider, region, url: rawURL };
  });

  return { version: 1, sequence: Number(source.sequence), relays };
}

function generatedSource(catalog: Catalog): string {
  return `/**
 * Generated from config/iroh/managed-relay-catalog.json.
 *
 * Fleet rotations are add-before-remove. Bump sequence and add first, deploy
 * both server consumers, wait one signed-policy lifetime, then bump sequence
 * again and remove. Run web/tools/generate-managed-iroh-relay-catalog.ts after
 * every edit. Signing keys and relay credentials never belong in this file.
 */
export const MANAGED_IROH_RELAY_CATALOG = ${JSON.stringify(catalog, null, 2)} as const;

/** Exact managed relay origins derived from the canonical catalog. */
export const MANAGED_IROH_RELAY_URLS = MANAGED_IROH_RELAY_CATALOG.relays.map(
  (relay) => relay.url,
);
`;
}

const catalog = validatedCatalog(JSON.parse(await readFile(sourcePath, "utf8")));
const expected = generatedSource(catalog);
const checkOnly = process.argv.includes("--check");
let drifted = false;

for (const outputPath of outputPaths) {
  if (checkOnly) {
    const current = await readFile(outputPath, "utf8").catch(() => "");
    if (current !== expected) {
      console.error(`generated managed relay catalog is stale: ${outputPath}`);
      drifted = true;
    }
    continue;
  }
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, expected, "utf8");
  console.log(`generated ${outputPath}`);
}

if (drifted) process.exit(1);
