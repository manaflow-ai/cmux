// Every method the agent page sends over the pane transport has a contract in
// `schemas/agent-pane/methods.json`, and the params the page gives it are ones the contract lists.
// The app's relay checks each frame against its params rule (AcpmuxPaneMethods+Params.swift
// `knownParams`), and `AcpmuxPaneMethodContractsTests` holds that table equal to the same file. A
// method or a key the page adds and the relay does not know is refused: `settled` on attach once
// (#41760, #42185), then `_meta.acpmux.peerRowBatches` on initialize, after which every chat in the
// app reconnected about 490 times an hour (cmux#46563, cmux#49148, ask-0e0d5a479b). RFD 0028
// (failure classes) asks for this test so the next one fails here, not in Leo's NIGHTLY.
//
// The methods come from the code, not a list: the TypeScript checker reads every call of a send
// (`request`, `typed`, `typedRequest`, `send`) under webviews/src/agent-session/acpmux whose
// method is a string literal type, and every `{ jsonrpc: "2.0", method }` frame the page writes.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import ts from "typescript";

type Method = { params: string[]; acpmux?: string[]; frames?: string };
type Contract = {
  methods: Record<string, Method>;
  not_relayed: Record<string, string>;
  refused_today: Record<string, string>;
};

const webviews = join(import.meta.dir, "..");
const root = join(webviews, "..");
const contract: Contract = JSON.parse(readFileSync(join(root, "schemas/agent-pane/methods.json"), "utf8"));
const pane = join(webviews, "src/agent-session/acpmux");

// The page's own code: no tests, galleries, the generated registry, or the mock daemon and
// simulator (they write the daemon's frames, not the page's).
function sources(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name !== "generated" && name !== "sim") sources(path, out);
    } else if (/\.tsx?$/.test(name) && !/\.(test|gallery)\.tsx?$/.test(name) && name !== "mock.ts") {
      out.push(path);
    }
  }
  return out;
}

// A method name as the transport carries one (`_acpmux/attach`, `acp.trust.get`, `initialize`), so
// a literal prompt text passed to a `send` is not read as one.
const METHOD = /^(initialize|[A-Za-z_]\w*([./][\w.]+)+)$/;

type Site = { method: string; where: string; params?: ts.Expression };

function sends(): { sites: Site[]; checker: ts.TypeChecker } {
  const files = sources(pane);
  const config = ts.getParsedCommandLineOfConfigFile(
    join(webviews, "tsconfig.json"),
    {},
    { ...ts.sys, onUnRecoverableConfigFileDiagnostic: () => {} },
  );
  const program = ts.createProgram(files, {
    ...config!.options,
    types: [],
    noEmit: true,
  });
  const checker = program.getTypeChecker();
  const wanted = new Set(files);
  // The string literals an expression's type holds; none for a plain `string` or a parameter that
  // forwards its caller's method (a wrapper such as `typedRequest` itself).
  const literals = (node: ts.Expression): string[] => {
    if (ts.isIdentifier(node)) {
      const declaration = checker.getSymbolAtLocation(node)?.valueDeclaration;
      if (declaration && ts.isParameter(declaration)) return [];
    }
    const type = checker.getTypeAtLocation(node);
    const parts = type.isUnion() ? type.types : [type];
    if (!parts.every((part) => part.isStringLiteral())) return [];
    return parts.map((part) => (part as ts.StringLiteralType).value).filter((value) => METHOD.test(value));
  };
  const sites: Site[] = [];
  for (const file of program.getSourceFiles()) {
    if (!wanted.has(file.fileName)) continue;
    const at = (node: ts.Node) =>
      `${relative(webviews, file.fileName)}:${file.getLineAndCharacterOfPosition(node.getStart()).line + 1}`;
    const visit = (node: ts.Node) => {
      if (ts.isCallExpression(node)) {
        const callee = node.expression;
        const name = ts.isPropertyAccessExpression(callee)
          ? callee.name.text
          : ts.isIdentifier(callee)
            ? callee.text
            : "";
        const index = name === "typedRequest" ? 1 : ["request", "typed", "send"].includes(name) ? 0 : -1;
        const method = index >= 0 ? node.arguments[index] : undefined;
        if (method) {
          for (const value of literals(method))
            sites.push({
              method: value,
              where: at(node),
              params: node.arguments[index + 1],
            });
        }
      }
      if (ts.isObjectLiteralExpression(node)) {
        const property = (key: string) =>
          node.properties.find(
            (p): p is ts.PropertyAssignment => ts.isPropertyAssignment(p) && p.name.getText(file) === key,
          );
        const method = property("method");
        if (property("jsonrpc") && method) {
          const params = property("params")?.initializer;
          for (const value of literals(method.initializer)) sites.push({ method: value, where: at(node), params });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(file);
  }
  return { sites, checker };
}

const { sites, checker } = sends();

// The keys a params argument's type names, for each member of a union (`cwd ? { harness, cwd } :
// { harness }`); undefined when the type does not say (a `Record<string, unknown>`, `any`).
function keysOf(type: ts.Type): string[] | undefined {
  if (type.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) return undefined;
  const parts = type.isUnion() ? type.types : [type];
  const keys = new Set<string>();
  for (const part of parts) {
    if (part.flags & (ts.TypeFlags.Undefined | ts.TypeFlags.Null)) continue;
    if (part.getStringIndexType() || part.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) return undefined;
    for (const property of part.getProperties()) keys.add(property.name);
  }
  return [...keys];
}

function propertyType(type: ts.Type, name: string, at: ts.Node): ts.Type | undefined {
  const parts = (type.isUnion() ? type.types : [type])
    .map((part) => part.getProperty(name))
    .filter((symbol): symbol is ts.Symbol => !!symbol)
    .map((symbol) => checker.getNonNullableType(checker.getTypeOfSymbolAtLocation(symbol, at)));
  if (!parts.length) return undefined;
  return parts.length === 1 ? parts[0] : undefined;
}

test("the page sends through the pane transport (the scan still finds its sends)", () => {
  const methods = new Set(sites.map((site) => site.method));
  for (const known of [
    "initialize",
    "session/new",
    "session/prompt",
    "session/cancel",
    "_acpmux/attach",
    "_acpmux/typing",
  ]) {
    expect(methods.has(known)).toBe(true);
  }
  expect(methods.size).toBeGreaterThan(100);
});

test("every method the page sends has a contract in schemas/agent-pane/methods.json", () => {
  const missing = [
    ...new Set(
      sites
        .filter(
          (site) =>
            !contract.methods[site.method] &&
            !(site.method in contract.not_relayed) &&
            !(site.method in contract.refused_today),
        )
        .map((site) => `${site.method} (${site.where})`),
    ),
  ].sort();
  expect(missing).toEqual([]);
});

// The relay's table may hold a method the page no longer sends (the Swift test holds `methods` to
// that table), so only the exceptions must be live: an entry the page stopped sending goes.
test("every not-relayed and refused-today entry is still sent, and none has a contract", () => {
  const sent = new Set(sites.map((site) => site.method));
  const exceptions = [...Object.keys(contract.not_relayed), ...Object.keys(contract.refused_today)];
  expect(exceptions.filter((method) => !sent.has(method))).toEqual([]);
  expect(exceptions.filter((method) => contract.methods[method])).toEqual([]);
  expect(Object.keys(contract.not_relayed).filter((method) => method in contract.refused_today)).toEqual([]);
});

test("the params the page sends are the contract's", () => {
  const refused: string[] = [];
  let checked = 0;
  for (const site of sites) {
    const method = contract.methods[site.method];
    // A frames method's params type is acpmux's registry type, wider than what the page fills in
    // (`AttachParams` has `beforeSeq`, `attending`); its frames file and test hold it instead.
    if (!method || method.frames || !site.params) continue;
    const type = checker.getTypeAtLocation(site.params);
    const keys = keysOf(type);
    if (!keys) continue;
    checked += 1;
    for (const key of keys) if (!method.params.includes(key)) refused.push(`${site.method} ${key} (${site.where})`);
    const meta = keys.includes("_meta") ? propertyType(type, "_meta", site.params) : undefined;
    const acpmux = meta && propertyType(meta, "acpmux", site.params);
    for (const key of (acpmux && keysOf(acpmux)) ?? []) {
      if (!(method.acpmux ?? []).includes(key)) refused.push(`${site.method} _meta.acpmux.${key} (${site.where})`);
    }
  }
  expect(checked).toBeGreaterThan(100);
  expect([...new Set(refused)].sort()).toEqual([]);
});

// A method whose params a helper builds (initialize, session/new, attach) is held to its frames
// file by its own test; each frame there takes only the keys this file lists for the method.
test("each frames file takes only its method's contract keys", () => {
  for (const [name, method] of Object.entries(contract.methods)) {
    if (!method.frames) continue;
    const file = JSON.parse(readFileSync(join(root, "schemas/agent-pane", method.frames), "utf8")) as Record<
      string,
      unknown
    >;
    const frames = Object.entries(file)
      .filter(([key]) => key !== "$comment")
      .flatMap(([, value]) =>
        Array.isArray(value) ? value.map((frame) => (frame as { params: Record<string, unknown> }).params) : [value],
      ) as Record<string, unknown>[];
    expect(frames.length).toBeGreaterThan(0);
    for (const params of frames) {
      expect(Object.keys(params).filter((key) => !method.params.includes(key))).toEqual([]);
      const acpmux = Object.keys((params._meta as { acpmux?: object } | undefined)?.acpmux ?? {});
      expect([name, acpmux.filter((key) => !(method.acpmux ?? []).includes(key))]).toEqual([name, []]);
    }
  }
});

// The host's pane policy as data (cmux-agent-pane-policy policy.json, which its tests/swift.rs keeps
// equal to AcpmuxPaneMethods.swift) lists the same methods and keys.
test("the pane policy's params rule is the contract", () => {
  const policy = JSON.parse(readFileSync(join(root, "cmux-tui/crates/cmux-agent-pane-policy/policy.json"), "utf8")) as {
    known_params: Record<string, { params: string[]; acpmux: string[] }>;
  };
  const sorted = (keys: string[] | undefined) => [...(keys ?? [])].sort();
  const asPolicy = Object.fromEntries(
    Object.entries(contract.methods).map(([name, method]) => [
      name,
      { params: sorted(method.params), acpmux: sorted(method.acpmux) },
    ]),
  );
  const fromPolicy = Object.fromEntries(
    Object.entries(policy.known_params).map(([name, known]) => [
      name,
      { params: sorted(known.params), acpmux: sorted(known.acpmux) },
    ]),
  );
  expect(fromPolicy).toEqual(asPolicy);
});
