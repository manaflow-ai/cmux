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
 * The commands a graduated apt name promises, run after the install: a name listed here whose command does not run
 * fails the bake, so an image never ships without a tool people were told it has. ffmpeg, imagemagick and
 * poppler-utils were added by hand (Leo, 2026-11-25: a Cloud chat on a folder of MP4s answered "ffprobe isn't
 * installed"); the rest are the small everyday tools agents reach for.
 */
export const GRADUATED_APT_CHECKS: Readonly<Record<string, string>> = {
  ffmpeg: "ffmpeg -hide_banner -version >/dev/null && ffprobe -hide_banner -version >/dev/null",
  imagemagick: "convert -version >/dev/null && identify -version >/dev/null",
  "poppler-utils": "pdfinfo -v 2>&1 | grep -qi poppler && command -v pdftotext >/dev/null && command -v pdftoppm >/dev/null",
  sqlite3: "sqlite3 --version >/dev/null",
  "git-lfs": "git lfs version >/dev/null",
  "fd-find": "fd --version >/dev/null",
  unzip: "unzip -v >/dev/null",
  zip: "zip -v >/dev/null",
  file: "file --version >/dev/null",
  tree: "tree --version >/dev/null",
  bc: "echo 1+1 | bc >/dev/null",
};

/**
 * Wiring a name needs after its install: Debian names fd `fdfind`, and git-lfs's filters go in the system gitconfig
 * so every clone, the work user's included, fetches LFS objects.
 */
const GRADUATED_APT_AFTER: Readonly<Record<string, string>> = {
  "fd-find": "{ command -v fd >/dev/null || ln -sf \"$(command -v fdfind)\" /usr/local/bin/fd; }",
  "git-lfs": "git lfs install --system --skip-repo >/dev/null",
};

/** The checks of the graduated apt names that have one: each prints its result, and any failure exits 1. */
export function graduatedCheckCommand(g: Graduated): string {
  const names = g.apt.filter((n) => n in GRADUATED_APT_CHECKS);
  if (names.length === 0) return "";
  const lines = names.map((n) => `if { ${GRADUATED_APT_CHECKS[n]}; } 2>/dev/null; then echo "graduated: check ${n} ok"; else echo "graduated: check ${n} FAILED"; bad=1; fi`);
  return `bad=0; ${lines.join("; ")}; [ "$bad" = 0 ]`;
}

/**
 * The agents layer's install of the graduated names, as root, by name. A name the archive or registry no longer
 * has does not stop the bake: the batch retries one name at a time and a name that still fails is reported. A name
 * with a check (GRADUATED_APT_CHECKS) must then run, or the command exits 1 and the bake stops.
 */
export function graduatedInstallCommand(g: Graduated, aptUpdate: string): string {
  const parts: string[] = [];
  if (g.apt.length > 0) {
    const one = "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends";
    parts.push(
      `${aptUpdate}; ${one} ${g.apt.join(" ")} >/tmp/graduated-apt.log 2>&1 || for n in ${g.apt.join(" ")}; do ${one} "$n" >>/tmp/graduated-apt.log 2>&1 || echo "graduated: apt $n did not install"; done`,
    );
    for (const n of g.apt) if (GRADUATED_APT_AFTER[n]) parts.push(`${GRADUATED_APT_AFTER[n]} || echo "graduated: wiring ${n} failed"`);
  }
  if (g.npm.length > 0) {
    const one = "npm i -g --no-audit --no-fund --no-update-notifier";
    parts.push(`${one} ${g.npm.join(" ")} >/tmp/graduated-npm.log 2>&1 || for n in ${g.npm.join(" ")}; do ${one} "$n" >>/tmp/graduated-npm.log 2>&1 || echo "graduated: npm $n did not install"; done`);
  }
  const check = graduatedCheckCommand(g);
  if (check) parts.push(`{ ${check}; } || { tail -20 /tmp/graduated-apt.log; exit 1; }`);
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
 * Where the summary is served, and the Stack project whose token it takes (cloud-journey.ts STACK; kept in step by
 * hand). The summary is cmux-platform's, not cmux-api's: cmux-api answers 404 on /v1/install-counts (the first
 * graduate run, 2026-11-23, read that 404), and the machines send their lists to the platform (acpmux
 * install_share.rs).
 */
const BACKENDS: Record<string, { api: string; cmuxApi: string; stack: { project: string; clientKey: string } }> = {
  dev: { api: "https://cmux-platform-development.debussy.workers.dev", cmuxApi: "https://cmux-api-development.debussy.workers.dev", stack: { project: "454ecd03-1db2-4050-845e-4ce5b0cd9895", clientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g" } },
  prod: { api: "https://cmux-platform-production.debussy.workers.dev", cmuxApi: "https://cloud-api.cmux.dev", stack: { project: "9790718f-14cd-4f7e-824d-eaf527a82b82", clientKey: "" } },
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

/**
 * A cmux access token of an install, which the summary takes (platform UsageSharing.ts personInstallToken: a Stack
 * session answers 401 install_counts.unauthorized, the second graduate run on 2026-11-27). Registers a CLI install
 * with a fresh key and signs cmux-api's challenge, as dev-e2e.ts "install.register + token" does.
 */
async function installToken(cmuxApi: string, session: string): Promise<string> {
  const post = async (route: string, body: unknown, bearer?: string) => {
    const r = await fetch(`${cmuxApi}${route}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(bearer ? { authorization: `Bearer ${bearer}` } : {}) },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
    const parsed = (await r.json().catch(() => ({}))) as { value?: unknown; message_prefix?: string; nonce?: string; access_token?: unknown };
    if (r.status !== 200) throw new Error(`${route} HTTP ${r.status} ${JSON.stringify(parsed).slice(0, 200)}`);
    return parsed;
  };
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const tag = `graduate-${Date.now().toString(36)}`;
  const registered = await post(
    "/v1/ops",
    { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `cmux graduate ${tag}`, device_name: "cmux graduate", platform: "linux" }, idempotency_key: tag },
    session,
  );
  const install = registered.value as { id: string; user?: string };
  install.user ??= ((await post("/v1/ops", { op: "user.ensure", params: {}, idempotency_key: `${tag}-ensure` }, session)).value as { id: string }).id;
  const challenge = await post("/v1/auth/challenge", { user: install.user, install: install.id });
  const signed = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${challenge.message_prefix}${challenge.nonce}`));
  const token = await post("/v1/auth/token", { user: install.user, install: install.id, nonce: challenge.nonce, signature: Buffer.from(signed).toString("base64url") });
  if (typeof token.access_token !== "string") throw new Error("/v1/auth/token: no access_token");
  return token.access_token;
}

function argValue(flag: string, argv: readonly string[]): string | undefined {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : undefined;
}

/** `--backend`: its summary host, and the test account's install token unless CMUX_INSTALL_COUNTS_TOKEN gave one. */
async function backendAccess(name: string, api: string | undefined, token: string): Promise<{ api: string; token: string }> {
  const backend = BACKENDS[name];
  if (!backend) throw new Error(`--backend: one of ${Object.keys(BACKENDS).join(", ")}`);
  if (token) return { api: api ?? backend.api, token };
  const email = process.env.CMUX_DOGFOOD_STACK_EMAIL ?? "";
  const password = process.env.CMUX_DOGFOOD_STACK_PASSWORD ?? "";
  if (!email || !password) throw new Error("--backend needs CMUX_INSTALL_COUNTS_TOKEN, or CMUX_DOGFOOD_STACK_EMAIL and CMUX_DOGFOOD_STACK_PASSWORD");
  return { api: api ?? backend.api, token: await installToken(backend.cmuxApi, await passwordSignIn(backend.stack, email, password)) };
}

async function main(argv: string[]): Promise<number> {
  const minPeople = Number(argValue("--min-people", argv) ?? MIN_PEOPLE);
  if (!Number.isInteger(minPeople) || minPeople < 3) throw new Error("--min-people: an integer, at least 3 (the platform's floor)");
  const file = argValue("--summary", argv);
  const backendName = argValue("--backend", argv);
  let api = argValue("--api", argv);
  let token = process.env.CMUX_INSTALL_COUNTS_TOKEN ?? "";
  if (backendName && !file) ({ api, token } = await backendAccess(backendName, api, token));
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
