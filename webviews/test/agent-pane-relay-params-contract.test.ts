// Every request the agent pane page sends, against the app relay's params rule.
//
// The macOS app relays the page's frames through a params rule (AcpmuxPaneMethods+Params.swift
// `knownParams`, methods in AcpmuxPaneMethods.swift `requests`); the Rust host holds the same
// tables as data (cmux-agent-pane-policy policy.json). A key the rule does not name is refused as
// `transport.intent_invalid`. cmux#46563 added `_meta.acpmux.peerRowBatches` to the page's
// `initialize` and not to the rule: the app refused every handshake (737 refusals in one nightly,
// every chat a skeleton) until cmux#49148. The Rust twin of this check (cmux-agent-pane-policy
// tests/typescript.rs) reads the page as text, so it never saw params built by a helper
// (`initializeParams()`), and no pull request job ran it.
//
// This file asks the TypeScript checker instead: for every call in the page's transport code that
// names a relay method (`this.request(M, P)`, `this.typed(M, P)`, `typedRequest(send, M, P)`,
// `this.send(M, P)`), the type of P gives its top-level keys, its `_meta` keys and its
// `_meta.acpmux` keys, through helpers, spreads and conditionals alike. Each must be one the
// Swift rule and policy.json both take, and the two tables must be one table.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import ts from "typescript";

const root = join(import.meta.dir, "../..");
const pane = join(root, "webviews/src/agent-session/acpmux");
const swiftDir = join(root, "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane");
const policyPath = join(root, "cmux-tui/crates/cmux-agent-pane-policy/policy.json");

type Known = { params: Set<string>; acpmux: Set<string> };

/// The Swift text from `start` to the first line that is exactly `end`, `//` comments dropped.
function swiftBlock(file: string, start: string, end: string): string {
  const text = readFileSync(join(swiftDir, file), "utf8");
  const at = text.indexOf(start);
  if (at < 0) throw new Error(`${file}: ${start} not found`);
  const body = text.slice(at + start.length);
  const stop = body.indexOf(end);
  if (stop < 0) throw new Error(`${file}: end of ${start} not found`);
  return body
    .slice(0, stop)
    .split("\n")
    .map((line) => line.split("//")[0])
    .join("\n");
}

const strings = (text: string) => [...text.matchAll(/"([^"]*)"/g)].map((match) => match[1]);

function swiftKnownParams(): Map<string, Known> {
  const table = swiftBlock(
    "AcpmuxPaneMethods+Params.swift",
    "static let knownParams: [String: (params: Set<String>, acpmux: Set<String>)] = [",
    "\n    ]",
  );
  const known = new Map<string, Known>();
  // One entry per line: `"method": (["param", ...], ["acpmux key", ...]),`.
  for (const line of table.split("\n").map((l) => l.trim())) {
    if (!line.startsWith('"')) continue;
    const method = line.slice(1, line.indexOf('"', 1));
    const rest = line.slice(method.length + 2);
    const split = rest.indexOf("], [");
    if (split < 0) throw new Error(`knownParams entry: ${line}`);
    known.set(method, { params: new Set(strings(rest.slice(0, split))), acpmux: new Set(strings(rest.slice(split))) });
  }
  return known;
}

function swiftRequests(): Set<string> {
  return new Set(
    strings(swiftBlock("AcpmuxPaneMethods.swift", "public static let requests: Set<String> = [", "\n    ]")),
  );
}

const swiftInitialize = (() => {
  const text = readFileSync(join(swiftDir, "AcpmuxPaneMethods.swift"), "utf8");
  const match = text.match(/static let initialize\s*=\s*"([^"]+)"/);
  return match?.[1] ?? "initialize";
})();

const gestureTicketKey = (() => {
  const text = readFileSync(join(swiftDir, "AcpmuxPaneMethods.swift"), "utf8");
  const match = text.match(/static let gestureTicketKey\s*=\s*"([^"]+)"/);
  if (!match) throw new Error("AcpmuxPaneMethods.gestureTicketKey not found");
  return match[1];
})();

const policy = JSON.parse(readFileSync(policyPath, "utf8")) as {
  initialize: string;
  requests: string[];
  known_params: Record<string, { params: string[]; acpmux: string[] }>;
};
const policyKnown = new Map(
  Object.entries(policy.known_params).map(([method, k]) => [
    method,
    { params: new Set(k.params), acpmux: new Set(k.acpmux) },
  ]),
);

/// What the page sends through the relay that the relay is known to refuse, each with why it stays.
/// Nothing else may be here: a new entry is a decision about the relay, not a way to make this pass.
const KNOWN_REFUSED: Record<string, string> = {
  // Sent by the page, refused by both relay tables today; whether the pane relay serves them is the
  // relay owners' call (inbox_threads reads a session's inbox; acpmux refuses it to agents).
  "_acpmux/browser_workspaces": "browser device workspace list; not in the relay tables yet",
  "_acpmux/inbox_threads": "a session's inbox threads; not in the relay tables yet",
};

/// Sites whose params type the checker cannot read (`method what`), each with why it is allowed for
/// now. Each is a follow-up: give the helper a closed params type and drop its row here.
const RECORD = "params has an index signature (Record<string, unknown>)";
const OPAQUE_OK = new Map<string, string>(
  [
    [
      "session/new",
      "startSession/watchLive take caller-built params (newSessionParams, schemas/agent-pane/session-new-params.json covers its shape)",
    ],
    ["_acpmux/ledger", "History > Costs passes ledgerModel.ts's query through"],
    ["_acpmux/perf", "the Inspector's Perf tab and perfReporter.ts pass perf_watch.rs's op params through"],
    ["_acpmux/team_audit", "History > Team passes teamAuditModel.ts's query through"],
    ["_acpmux/review_queue", "History > Waiting on you passes queueModel.ts's query through"],
    ["_acpmux/review_verdict", "the review card passes its verdict through"],
    ["_acpmux/audit", "the approvals audit page passes its cursor through"],
  ].map(([method, why]) => [`${method} ${RECORD}`, why] as [string, string]),
);

/// Methods the page names that go to the native host in mock mode only, never through the relay.
const NOT_RELAYED = new Set(["file.search"]);

function sources(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name === "generated" || name === "__tests__") continue;
      out.push(...sources(path));
    } else if (/\.tsx?$/.test(name) && !/\.(test|gallery|bench)\.tsx?$/.test(name)) out.push(path);
  }
  return out;
}

type Site = { file: string; line: number; method: string; params: Set<string>; meta: Set<string>; acpmux: Set<string> };
type Opaque = { file: string; line: number; method: string; what: string };

/// A relay method name: what the relay's tables name, or the protocol's own name shapes.
const relayMethod = (name: string, relay: Set<string>) =>
  relay.has(name) || /^(_acpmux\/|session\/|acp\.|chat\.)/.test(name) || name === "initialize";

function scan(): { sites: Site[]; opaque: Opaque[] } {
  const config = ts.getParsedCommandLineOfConfigFile(
    join(root, "webviews/tsconfig.json"),
    {},
    {
      ...ts.sys,
      onUnRecoverableConfigFileDiagnostic: (d) => {
        throw new Error(ts.flattenDiagnosticMessageText(d.messageText, "\n"));
      },
    },
  );
  if (!config) throw new Error("webviews/tsconfig.json did not parse");
  const files = sources(pane);
  const program = ts.createProgram(files, { ...config.options, noEmit: true, types: [] });
  const checker = program.getTypeChecker();
  const relay = new Set([...swiftRequests(), ...policy.requests]);
  const sites: Site[] = [];
  const opaque: Opaque[] = [];

  // The literal method names `type` can be: a string literal, or a union of them.
  const literals = (type: ts.Type): string[] | undefined => {
    if (type.isStringLiteral()) return [type.value];
    if (type.isUnion() && type.types.every((t) => t.isStringLiteral()))
      return type.types.map((t) => (t as ts.StringLiteralType).value);
    return undefined;
  };
  // The object constituents of `type` (a union's every arm; undefined, null and {} add none).
  // A list is the arms of a nested prop read off several arms (TypeChecker has no public union builder).
  const objects = (type: ts.Type | ts.Type[]): ts.Type[] =>
    (Array.isArray(type) ? type : [type])
      .flatMap((t) => (t.isUnion() ? t.types : [t]))
      .filter(
        (t) => !(t.flags & (ts.TypeFlags.Undefined | ts.TypeFlags.Null | ts.TypeFlags.Void | ts.TypeFlags.Never)),
      );
  const keysOf = (type: ts.Type | ts.Type[], at: ts.Node, what: string, push: (what: string) => void): Set<string> => {
    const keys = new Set<string>();
    for (const arm of objects(type)) {
      if (arm.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) {
        push(`${what} is ${checker.typeToString(arm)}`);
        continue;
      }
      if (checker.getIndexInfosOfType(arm).length > 0)
        push(`${what} has an index signature (${checker.typeToString(arm)})`);
      for (const prop of checker.getPropertiesOfType(arm)) keys.add(prop.getName());
    }
    return keys;
  };
  const propType = (type: ts.Type | ts.Type[], name: string, at: ts.Node): ts.Type[] | undefined => {
    const arms = objects(type)
      .map((arm) => arm.getProperty(name))
      .filter((p): p is ts.Symbol => !!p)
      .map((p) => checker.getNonNullableType(checker.getTypeOfSymbolAtLocation(p, at)));
    if (arms.length === 0) return undefined;
    return arms;
  };

  for (const file of files) {
    const source = program.getSourceFile(file);
    if (!source) continue;
    const rel = relative(root, file);
    const visit = (node: ts.Node) => {
      if (ts.isCallExpression(node)) {
        const callee = node.expression;
        const name = ts.isPropertyAccessExpression(callee)
          ? callee.name.text
          : ts.isIdentifier(callee)
            ? callee.text
            : undefined;
        // `typedRequest(send, method, params)`; every other sender takes `(method, params)`.
        const methodAt = name === "typedRequest" ? 1 : ["request", "typed", "send"].includes(name ?? "") ? 0 : -1;
        const methodArg = methodAt >= 0 ? node.arguments[methodAt] : undefined;
        // A sender that forwards its own `method` parameter (`typedRequest`'s `request(method, ...)`)
        // sends what its callers name; those calls are scanned where they are written.
        const forwards =
          methodArg && ts.isIdentifier(methodArg) && checker.getSymbolAtLocation(methodArg)?.valueDeclaration
            ? ts.isParameter(checker.getSymbolAtLocation(methodArg)!.valueDeclaration!)
            : false;
        const methods = methodArg && !forwards ? literals(checker.getTypeAtLocation(methodArg)) : undefined;
        for (const method of methods?.filter((m) => relayMethod(m, relay)) ?? []) {
          const line = source.getLineAndCharacterOfPosition(node.getStart()).line + 1;
          const paramsArg = node.arguments[methodAt + 1];
          const site: Site = { file: rel, line, method, params: new Set(), meta: new Set(), acpmux: new Set() };
          const push = (what: string) => opaque.push({ file: rel, line, method, what });
          if (paramsArg) {
            const type = checker.getTypeAtLocation(paramsArg);
            site.params = keysOf(type, paramsArg, "params", push);
            const meta = propType(type, "_meta", paramsArg);
            if (meta) {
              site.meta = keysOf(meta, paramsArg, "_meta", push);
              const acpmux = propType(meta, "acpmux", paramsArg);
              if (acpmux) site.acpmux = keysOf(acpmux, paramsArg, "_meta.acpmux", push);
            }
          }
          sites.push(site);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  return { sites, opaque };
}

const scanned = scan();
const swiftKnown = swiftKnownParams();
const swiftMethods = swiftRequests();

const setText = (s: Set<string>) => [...s].sort().join(",");

test("the Swift relay rule and policy.json are one table", () => {
  const diffs: string[] = [];
  for (const method of new Set([...swiftKnown.keys(), ...policyKnown.keys()])) {
    const a = swiftKnown.get(method);
    const b = policyKnown.get(method);
    if (!a || !b) {
      diffs.push(`${method}: only in ${a ? "AcpmuxPaneMethods+Params.swift knownParams" : "policy.json known_params"}`);
      continue;
    }
    if (setText(a.params) !== setText(b.params))
      diffs.push(`${method} params: swift [${setText(a.params)}] policy [${setText(b.params)}]`);
    if (setText(a.acpmux) !== setText(b.acpmux))
      diffs.push(`${method} _meta.acpmux: swift [${setText(a.acpmux)}] policy [${setText(b.acpmux)}]`);
  }
  for (const method of swiftMethods)
    if (!policy.requests.includes(method)) diffs.push(`${method}: request only in Swift`);
  for (const method of policy.requests)
    if (!swiftMethods.has(method)) diffs.push(`${method}: request only in policy.json`);
  if (policy.initialize !== swiftInitialize)
    diffs.push(`initialize: swift ${swiftInitialize} policy ${policy.initialize}`);
  expect(diffs).toEqual([]);
});

test("the scan reaches the page's requests", () => {
  // Fewer means the senders were renamed and this check went blind: teach `scan` the new name.
  expect(scanned.sites.length).toBeGreaterThan(150);
  const methods = new Set(scanned.sites.map((s) => s.method));
  for (const method of [
    "initialize",
    "session/new",
    "session/prompt",
    "_acpmux/attach",
    "_acpmux/typing",
    "_acpmux/watch",
  ])
    expect(methods.has(method)).toBe(true);
});

test("every key the page sends a relay method is one the relay takes", () => {
  const refused: string[] = [];
  for (const site of scanned.sites) {
    if (NOT_RELAYED.has(site.method) || KNOWN_REFUSED[site.method]) continue;
    const at = `${site.file}:${site.line} ${site.method}`;
    for (const [table, methods, known] of [
      ["AcpmuxPaneMethods (Swift)", swiftMethods, swiftKnown],
      ["policy.json", new Set(policy.requests), policyKnown],
    ] as const) {
      if (site.method !== policy.initialize && !methods.has(site.method)) {
        refused.push(`${at}: method not in ${table} requests`);
        continue;
      }
      const rule = known.get(site.method);
      if (!rule) {
        if (site.params.size > 0) refused.push(`${at}: ${table} takes no params, page sends [${setText(site.params)}]`);
        continue;
      }
      for (const key of site.params) if (!rule.params.has(key)) refused.push(`${at}: param "${key}" not in ${table}`);
      for (const key of site.meta) {
        const ticket = key === gestureTicketKey;
        if (key !== "acpmux" && !ticket) refused.push(`${at}: _meta key "${key}" not taken by ${table}`);
      }
      for (const key of site.acpmux)
        if (!rule.acpmux.has(key)) refused.push(`${at}: _meta.acpmux key "${key}" not in ${table}`);
    }
  }
  expect(refused).toEqual([]);
});

test("every params the page sends a relay method has keys the checker can read", () => {
  // An index signature or `unknown` params hides what goes on the wire from this check: give the
  // helper a closed object type, or list why here.
  const unread = scanned.opaque
    .filter((o) => !NOT_RELAYED.has(o.method) && !KNOWN_REFUSED[o.method] && !OPAQUE_OK.has(`${o.method} ${o.what}`))
    .map((o) => `${o.file}:${o.line} ${o.method}: ${o.what}`);
  expect(unread).toEqual([]);
});

test("the known refusals are still sent and still refused", () => {
  for (const method of Object.keys(KNOWN_REFUSED)) {
    expect(scanned.sites.some((s) => s.method === method)).toBe(true);
    expect(swiftMethods.has(method)).toBe(false);
  }
});
