/**
 * Graduate (plans/cloud/images-per-user.md in cmuxterm-hq, step 4): a package name that many people's own layers
 * hold moves into the image's agents layer, so one shared copy replaces the many personal ones.
 *
 * The aggregate is the platform's `GET /v1/install-counts/additions/summary` (cmux-platform InstallCounts.ts): the
 * names people added since the image, one count per person, under the opt-in usage setting, never below 3 people.
 * This reads it (from the API with a person's token, or a saved answer), keeps the apt and npm names held by at
 * least `minPeople` people, and with --write adds them to images/cmux-vm/graduated.json. The next bake installs
 * that list in the agents layer (bake.ts installGraduated) and folds it into the agents key (layers.ts layerKeys).
 * Once the image has a name, its finalize records it in /etc/cmux/image-packages.txt, so a person's additions
 * (layers.ts userAdditionsCommand) stop listing it and their own layer drops it: the dedupe across people.
 *
 * Only apt and npm graduate: they are the kinds the image's package list records, so a graduated name leaves every
 * person's list. A name never leaves graduated.json on its own; removing one is an edit.
 *
 * Usage (from web/):
 *   bun scripts/cmux-vm-image/graduate.ts --summary SUMMARY.json [--min-people N] [--write]
 *   CMUX_INSTALL_COUNTS_TOKEN=... bun scripts/cmux-vm-image/graduate.ts --api https://cmux-platform-production.debussy.workers.dev [--min-people N] [--write]
 *   bun scripts/cmux-vm-image/graduate.ts --backend dev [--out REPORT.json]   (signs in as CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD)
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/** The kinds that graduate: the ones the image's package list (layers.ts imagePackagesCommand) records. */
export const GRADUATE_KINDS = ["apt", "npm"] as const;
export type GraduateKind = (typeof GRADUATE_KINDS)[number];

/** A name moves into the image once this many people's lists hold it (the platform's own floor is 3). */
export const MIN_PEOPLE = 10;
/** At most this many names of one kind in the image's list. */
export const MAX_PER_KIND = 200;

export const GRADUATED_PATH = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../images/cmux-vm/graduated.json");
/** The same file, repo-relative (layers.ts keeps it out of the system layer's inputs). */
export const GRADUATED_REPO_PATH = "images/cmux-vm/graduated.json";

const NPM_NAME = /^(@[a-z0-9][a-z0-9._-]{0,100}\/)?[a-z0-9][a-z0-9._-]{0,100}$/;
/** The person layer's own name rules (cmux-platform PersonLayer.ts): safe in a shell line unquoted, no versions or paths. */
const NAME: Record<GraduateKind, RegExp> = { apt: /^[a-z0-9][a-z0-9+.-]{0,127}$/, npm: NPM_NAME };

export type Graduated = Record<GraduateKind, string[]>;
export const NONE: Graduated = { apt: [], npm: [] };

/** One summary row: `"apt jq"`, held by `people` people. */
export type SummaryRow = { name: string; people: number };

/** graduated.json, checked: unknown kinds and unsafe names refuse the whole file. A missing file is no names. */
export function parseGraduated(text: string | undefined): Graduated {
  if (text === undefined) return NONE;
  const v = JSON.parse(text) as Record<string, unknown>;
  const out = { apt: [] as string[], npm: [] as string[] };
  for (const k of GRADUATE_KINDS) {
    const names = v[k] ?? [];
    if (!Array.isArray(names) || !names.every((n) => typeof n === "string" && NAME[k].test(n))) throw new Error(`${GRADUATED_REPO_PATH}: ${k} must be a list of plain ${k} names`);
    out[k] = [...new Set(names as string[])].sort();
  }
  return out;
}

export function readGraduated(file = GRADUATED_PATH): Graduated {
  return parseGraduated(existsSync(file) ? readFileSync(file, "utf8") : undefined);
}

/** The agents key's part: empty with no names, so an image with nothing graduated keeps its key. */
export function graduatedKeyText(g: Graduated): string {
  return GRADUATE_KINDS.some((k) => g[k].length > 0) ? JSON.stringify({ apt: g.apt, npm: g.npm }) : "";
}

/**
 * The previous list plus every apt or npm name the summary shows held by at least `minPeople` people. Other kinds,
 * unsafe names, npm itself and corepack are skipped; nothing already graduated is removed.
 */
export function graduate(rows: readonly SummaryRow[], previous: Graduated, minPeople = MIN_PEOPLE): { graduated: Graduated; added: SummaryRow[] } {
  const by = { apt: new Set(previous.apt), npm: new Set(previous.npm) };
  const added: SummaryRow[] = [];
  for (const row of [...rows].sort((a, b) => b.people - a.people || a.name.localeCompare(b.name))) {
    if (!(row.people >= minPeople)) continue;
    const [kind, name, ...rest] = row.name.trim().split(/\s+/);
    if (!kind || !name || rest.length > 0 || !(GRADUATE_KINDS as readonly string[]).includes(kind)) continue;
    const k = kind as GraduateKind;
    if (k === "npm" && (name === "npm" || name === "corepack")) continue;
    if (!NAME[k].test(name) || by[k].has(name) || by[k].size >= MAX_PER_KIND) continue;
    by[k].add(name);
    added.push(row);
  }
  return { graduated: { apt: [...by.apt].sort(), npm: [...by.npm].sort() }, added };
}

/**
 * The agents layer's install of the graduated names, as root, by name. A name the archive or registry no longer
 * has does not stop the bake: the batch retries one name at a time and a name that still fails is reported.
 */
export function graduatedInstallCommand(g: Graduated, aptUpdate: string): string {
  const parts: string[] = [];
  if (g.apt.length > 0) {
    const one = "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends";
    parts.push(
      `${aptUpdate}; ${one} ${g.apt.join(" ")} >/tmp/graduated-apt.log 2>&1 || for n in ${g.apt.join(" ")}; do ${one} "$n" >>/tmp/graduated-apt.log 2>&1 || echo "graduated: apt $n did not install"; done`,
    );
  }
  if (g.npm.length > 0) {
    const one = "npm i -g --no-audit --no-fund --no-update-notifier";
    parts.push(`${one} ${g.npm.join(" ")} >/tmp/graduated-npm.log 2>&1 || for n in ${g.npm.join(" ")}; do ${one} "$n" >>/tmp/graduated-npm.log 2>&1 || echo "graduated: npm $n did not install"; done`);
  }
  parts.push(`echo "graduated: ${g.apt.length} apt, ${g.npm.length} npm"`);
  return parts.join("; ");
}

/** A summary answer (`{"names":[{"name":"apt jq","people":12}]}`), checked. */
export function parseSummary(text: string): SummaryRow[] {
  const v = JSON.parse(text) as { names?: unknown };
  if (!Array.isArray(v.names)) throw new Error("not an additions summary: no names list");
  return v.names.filter((r): r is SummaryRow => !!r && typeof r.name === "string" && typeof r.people === "number");
}

/**
 * The cmux-platform worker that serves /v1/install-counts per backend (its wrangler.jsonc PLATFORM_ORIGIN, not the cmux-api
 * host, which answers 404 there), and the Stack project cloud-journey.ts signs in to (its STACK; kept in step by hand).
 */
const BACKENDS: Record<string, { api: string; stack: { project: string; clientKey: string } }> = {
  dev: { api: "https://cmux-platform-development.debussy.workers.dev", stack: { project: "454ecd03-1db2-4050-845e-4ce5b0cd9895", clientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g" } },
  prod: { api: "https://cmux-platform-production.debussy.workers.dev", stack: { project: "9790718f-14cd-4f7e-824d-eaf527a82b82", clientKey: "" } },
};

/** The test account's person token: Stack's password sign-in, as cloud-journey.ts passwordSignIn. */
async function passwordSignIn(stack: { project: string; clientKey: string }, email: string, password: string): Promise<string> {
  const r = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-stack-access-type": "client",
      "x-stack-project-id": stack.project,
      ...(stack.clientKey ? { "x-stack-publishable-client-key": stack.clientKey } : {}),
    },
    body: JSON.stringify({ email, password }),
  });
  const body = (await r.json().catch(() => ({}))) as { access_token?: unknown; code?: unknown };
  if (r.status !== 200 || typeof body.access_token !== "string") throw new Error(`Stack sign-in HTTP ${r.status} ${String(body.code ?? "")}`);
  return body.access_token;
}

function argValue(flag: string, argv: readonly string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

async function main(argv: string[]): Promise<number> {
  const minPeople = Number(argValue("--min-people", argv) ?? MIN_PEOPLE);
  if (!Number.isInteger(minPeople) || minPeople < 3) throw new Error("--min-people: an integer, at least 3 (the platform's floor)");
  const file = argValue("--summary", argv);
  const backendName = argValue("--backend", argv);
  let api = argValue("--api", argv);
  let token = process.env.CMUX_INSTALL_COUNTS_TOKEN ?? "";
  if (backendName && !file) {
    const backend = BACKENDS[backendName];
    if (!backend) throw new Error(`--backend: one of ${Object.keys(BACKENDS).join(", ")}`);
    api ??= backend.api;
    if (!token) {
      const email = process.env.CMUX_DOGFOOD_STACK_EMAIL ?? "";
      const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD ?? "";
      if (!email || !password) throw new Error("--backend needs CMUX_INSTALL_COUNTS_TOKEN, or CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD");
      token = await passwordSignIn(backend.stack, email, password);
    }
  }
  let text: string;
  if (file) text = readFileSync(file, "utf8");
  else if (api) {
    if (!token) throw new Error("--api needs CMUX_INSTALL_COUNTS_TOKEN: a person's token of a sharing team member");
    const r = await fetch(`${api.replace(/\/+$/, "")}/v1/install-counts/additions/summary?minPeople=${minPeople}`, { headers: { authorization: `Bearer ${token}` } });
    text = await r.text();
    if (!r.ok) throw new Error(`additions summary HTTP ${r.status}: ${text.slice(0, 300)}`);
  } else throw new Error("usage: graduate.ts (--summary FILE | --api URL | --backend NAME) [--min-people N] [--out FILE] [--write]");
  const rows = parseSummary(text);
  const previous = readGraduated();
  const { graduated, added } = graduate(rows, previous, minPeople);
  const out = argValue("--out", argv);
  const report = { min_people: minPeople, summary_names: rows.length, at_or_above: rows.filter((r) => r.people >= minPeople).length, added, graduated };
  console.log(JSON.stringify(report, null, 2));
  if (out) writeFileSync(out, JSON.stringify(report, null, 2) + "\n");
  if (argv.includes("--write") && added.length > 0) writeFileSync(GRADUATED_PATH, JSON.stringify(graduated, null, 2) + "\n");
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e: Error) => {
      console.error(e.message);
      process.exit(1);
    },
  );
}
