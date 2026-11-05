// The agent page's calls to the app, checked against the contract both sides share,
// schemas/agent-bridge/contract.json. The app's AgentBridgeContractTests (Swift) keeps the contract
// equal to its own tables; this test fails when the page sends a method, a param key or a WebKit
// handler name the contract does not have, which the app would refuse (`cmux.protocol.unknown_op`
// on the page host, `unsupported` on the old bridge). `account.add` was sent here and missing from
// the app's page ops, so Add account failed on the page host.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import ts from "typescript";

type Contract = {
  ops: Record<string, string>;
  params: Record<string, string[]>;
  legacyOnly: Record<string, string>;
  unserved: Record<string, string>;
  handlers: Record<string, string>;
};

const repo = join(import.meta.dir, "../../../..");
const contract = JSON.parse(readFileSync(join(repo, "schemas/agent-bridge/contract.json"), "utf8")) as Contract;

/// One method the page sends: where, which sender, and the literal param keys (null when a spread
/// or a non-literal hides them).
type Sent = { at: string; method: string; prefix: boolean; keys: string[] | null; direct: boolean };

function sourceFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== "node_modules") sourceFiles(path, out);
    } else if (/\.(ts|tsx)$/.test(entry.name) && !/\.(test|spec)\.tsx?$/.test(entry.name)) {
      out.push(path);
    }
  }
  return out;
}

function parse(file: string, text: string): ts.SourceFile {
  return ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, file.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
}

function walk(node: ts.Node, visit: (node: ts.Node) => void): void {
  visit(node);
  node.forEachChild((child) => walk(child, visit));
}

function calleeName(call: ts.CallExpression): string | undefined {
  return ts.isIdentifier(call.expression) ? call.expression.text : undefined;
}

/// A function that forwards its first parameter (`method`/`op: string`) to a sender: its name, and
/// whether it tries the page's own direct actions first (`window.cmuxAcpmuxActions?.[method]`).
function wrappers(source: ts.SourceFile, senders: Map<string, boolean>): Map<string, boolean> {
  const found = new Map<string, boolean>();
  walk(source, (node) => {
    let name: string | undefined;
    let fn: ts.SignatureDeclaration | undefined;
    if (ts.isFunctionDeclaration(node) && node.name) {
      name = node.name.text;
      fn = node;
    } else if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer &&
      (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer))) {
      name = node.name.text;
      fn = node.initializer;
    }
    const first = fn?.parameters[0];
    if (!name || !fn || !first || !ts.isIdentifier(first.name)) return;
    const param = first.name.text;
    if (param !== "method" && param !== "op") return;
    let forwards = false;
    let direct = false;
    walk(fn, (inner) => {
      if (ts.isCallExpression(inner)) {
        const callee = calleeName(inner);
        const arg = inner.arguments[0];
        if (callee && senders.has(callee) && arg && ts.isIdentifier(arg) && arg.text === param) {
          forwards = true;
          direct ||= senders.get(callee)!;
        }
      }
      if (ts.isPropertyAccessExpression(inner) && inner.name.text === "cmuxAcpmuxActions") direct = true;
    });
    if (forwards) found.set(name, direct);
  });
  return found;
}

function literalKeys(arg: ts.Expression | undefined): string[] | null {
  if (!arg) return [];
  if (!ts.isObjectLiteralExpression(arg)) return null;
  const keys: string[] = [];
  for (const property of arg.properties) {
    if (ts.isSpreadAssignment(property)) return null;
    const name = property.name;
    if (!name) return null;
    if (ts.isIdentifier(name) || ts.isStringLiteral(name)) keys.push(name.text);
    else return null;
  }
  return keys;
}

/// Every method literal `files` send the app, through postNative or a wrapper of it.
function sentMethods(files: { path: string; text: string }[]): Sent[] {
  const sources = files.map(({ path, text }) => ({ path, source: parse(path, text) }));
  // Wrappers are found to a fixed point: a wrapper of a wrapper is a sender too.
  const senders = new Map<string, boolean>([["postNative", false]]);
  for (let round = 0; round < 4; round++) {
    const before = senders.size;
    for (const { source } of sources) for (const [name, direct] of wrappers(source, senders)) senders.set(name, direct);
    if (senders.size === before) break;
  }
  const sent: Sent[] = [];
  for (const { path, source } of sources) {
    // A sender counts in a file that defines or imports it; another file's `call` is another function.
    const inScope = new Set<string>();
    walk(source, (node) => {
      if (ts.isImportSpecifier(node) && senders.has(node.name.text)) inScope.add(node.name.text);
    });
    for (const name of wrappers(source, senders).keys()) inScope.add(name);
    walk(source, (node) => {
      if (!ts.isCallExpression(node)) return;
      const callee = calleeName(node);
      if (!callee || !inScope.has(callee)) return;
      const arg = node.arguments[0];
      const at = `${path}:${source.getLineAndCharacterOfPosition(node.getStart()).line + 1}`;
      const direct = senders.get(callee)!;
      if (arg && (ts.isStringLiteral(arg) || ts.isNoSubstitutionTemplateLiteral(arg))) {
        sent.push({ at, method: arg.text, prefix: false, keys: literalKeys(node.arguments[1]), direct });
      } else if (arg && ts.isTemplateExpression(arg) && arg.head.text) {
        sent.push({ at, method: arg.head.text, prefix: true, keys: null, direct });
      }
    });
  }
  // A sender handed to a function as a callback: a parameter that defaults to one (`send = postNative`,
  // attachRunTerminal) or that a call passes one to (`toggleRemoteControl(..., callNative)`). The literals the
  // function calls that parameter with are methods too; any other callback (a daemon's) is not.
  const passed = new Map<string, Set<number>>();
  for (const { source } of sources) {
    walk(source, (node) => {
      if (!ts.isCallExpression(node)) return;
      const callee = calleeName(node);
      if (!callee) return;
      node.arguments.forEach((arg, index) => {
        if (ts.isIdentifier(arg) && senders.has(arg.text)) {
          const set = passed.get(callee) ?? new Set<number>();
          set.add(index);
          passed.set(callee, set);
        }
      });
    });
  }
  for (const { path, source } of sources) {
    walk(source, (node) => {
      let name: string | undefined;
      let fn: ts.SignatureDeclaration | undefined;
      if (ts.isFunctionDeclaration(node) && node.name) {
        name = node.name.text;
        fn = node;
      } else if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer &&
        (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer))) {
        name = node.name.text;
        fn = node.initializer;
      }
      if (!name || !fn) return;
      const callbacks = new Map<string, boolean>();
      fn.parameters.forEach((parameter, index) => {
        if (!ts.isIdentifier(parameter.name)) return;
        const initial = parameter.initializer;
        if (initial && ts.isIdentifier(initial) && senders.has(initial.text)) callbacks.set(parameter.name.text, senders.get(initial.text)!);
        else if (passed.get(name!)?.has(index)) callbacks.set(parameter.name.text, true);
      });
      if (callbacks.size === 0) return;
      walk(fn, (inner) => {
        if (!ts.isCallExpression(inner)) return;
        const callee = calleeName(inner);
        const arg = inner.arguments[0];
        if (!callee || !callbacks.has(callee) || !arg) return;
        if (ts.isStringLiteral(arg) || ts.isNoSubstitutionTemplateLiteral(arg)) {
          const at = `${path}:${source.getLineAndCharacterOfPosition(inner.getStart()).line + 1}`;
          sent.push({ at, method: arg.text, prefix: false, keys: literalKeys(inner.arguments[1]), direct: callbacks.get(callee)! });
        }
      });
    });
  }
  return sent;
}

/// The page's own direct actions (App.tsx `window.cmuxAcpmuxActions = {...}` and `[name] =`): a wrapper
/// that tries them first never reaches the app for these.
function directActions(text: string): Set<string> {
  const names = new Set<string>();
  walk(parse("App.tsx", text), (node) => {
    if (!ts.isBinaryExpression(node) || node.operatorToken.kind !== ts.SyntaxKind.EqualsToken) return;
    const left = node.left;
    if (ts.isPropertyAccessExpression(left) && left.name.text === "cmuxAcpmuxActions" && ts.isObjectLiteralExpression(node.right)) {
      for (const property of node.right.properties) {
        const name = property.name;
        if (name && (ts.isIdentifier(name) || ts.isStringLiteral(name))) names.add(name.text);
      }
    }
    if (ts.isElementAccessExpression(left) && ts.isPropertyAccessExpression(left.expression) &&
      left.expression.name.text === "cmuxAcpmuxActions" && ts.isStringLiteral(left.argumentExpression)) {
      names.add(left.argumentExpression.text);
    }
  });
  return names;
}

/// The WebKit handler names `files` post to: `messageHandlers?.name`, `messageHandlers?.[CONST]`, and a
/// `find*Handler(name = "...")` default.
function handlerNames(files: { path: string; text: string }[]): Map<string, string> {
  const found = new Map<string, string>();
  for (const { path, text } of files) {
    const source = parse(path, text);
    const consts = new Map<string, string>();
    walk(source, (node) => {
      if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer && ts.isStringLiteral(node.initializer)) {
        consts.set(node.name.text, node.initializer.text);
      }
    });
    const at = (node: ts.Node) => `${path}:${source.getLineAndCharacterOfPosition(node.getStart()).line + 1}`;
    const onHandlers = (expression: ts.Expression) =>
      ts.isPropertyAccessExpression(expression) && expression.name.text === "messageHandlers";
    walk(source, (node) => {
      if (ts.isPropertyAccessExpression(node) && onHandlers(node.expression)) found.set(node.name.text, at(node));
      if (ts.isElementAccessExpression(node) && onHandlers(node.expression)) {
        const arg = node.argumentExpression;
        const name = ts.isStringLiteral(arg) ? arg.text : ts.isIdentifier(arg) ? consts.get(arg.text) : undefined;
        if (name) found.set(name, at(node));
      }
      if (ts.isFunctionDeclaration(node) && node.name && /^find\w*Handler$/.test(node.name.text)) {
        for (const parameter of node.parameters) {
          if (parameter.initializer && ts.isStringLiteral(parameter.initializer)) found.set(parameter.initializer.text, at(parameter));
        }
      }
    });
  }
  return found;
}

function readTree(dir: string): { path: string; text: string }[] {
  return sourceFiles(dir).map((path) => ({ path: relative(repo, path), text: readFileSync(path, "utf8") }));
}

const appMethods = new Set(Object.values(contract.ops));
const pageOnly = new Set([...Object.keys(contract.legacyOnly), ...Object.keys(contract.unserved)]);

/// Why `sent` would be refused, or null when the app takes it.
function refusal(sent: Sent, direct: Set<string>): string | null {
  const known = (method: string) => appMethods.has(method) || pageOnly.has(method) || (sent.direct && direct.has(method));
  if (sent.prefix) {
    const any = [...appMethods, ...pageOnly].some((method) => method.startsWith(sent.method));
    return any ? null : `${sent.at}: no app method starts with '${sent.method}'`;
  }
  if (!known(sent.method)) return `${sent.at}: the app has no method '${sent.method}'`;
  const keys = contract.params[sent.method];
  if (keys && sent.keys) {
    const stray = sent.keys.filter((key) => !keys.includes(key));
    if (stray.length) return `${sent.at}: ${sent.method} takes ${JSON.stringify(keys)}, not ${JSON.stringify(stray)}`;
  }
  return null;
}

describe("agent bridge contract (schemas/agent-bridge/contract.json)", () => {
  const pane = readTree(join(repo, "webviews/src/agent-session"));
  const direct = directActions(readFileSync(join(repo, "webviews/src/agent-session/acpmux/App.tsx"), "utf8"));

  test("every method the page sends is one the app serves", () => {
    const sent = sentMethods(pane);
    expect(sent.length).toBeGreaterThan(100);
    expect(direct.size).toBeGreaterThan(50);
    const refused = sent.map((entry) => refusal(entry, direct)).filter((line): line is string => line !== null);
    expect(refused).toEqual([]);
  });

  test("every WebKit handler the webviews post to is listed, and the app registers the listed ones", () => {
    const used = handlerNames(readTree(join(repo, "webviews/src")));
    const unlisted = [...used].filter(([name]) => !(name in contract.handlers)).map(([name, at]) => `${at}: ${name}`);
    expect(unlisted).toEqual([]);
    const swiftText = sourceSwift(join(repo, "Packages/macOS/CmuxNext/Sources"));
    const missing = Object.entries(contract.handlers)
      .filter(([, owner]) => !owner.startsWith("external"))
      .filter(([name]) => !swiftText.includes(`"${name}"`))
      .map(([name]) => name);
    expect(missing).toEqual([]);
  });

  test("the scanner sees a drifted method, a stray key and an unlisted handler", () => {
    const file = {
      path: "webviews/src/agent-session/acpmux/fake.ts",
      text: `
        import { postNative } from "./native";
        function callNative(method: string, params: Record<string, unknown> = {}) {
          const direct = window.cmuxAcpmuxActions?.[method];
          return direct ? direct(params) : postNative(method, params);
        }
        postNative("account.ad", {});
        postNative("link.inspect", { url: "u", cachd: true });
        callNative("chat.send", { text: "hi" });
        function attach(id: string, send: (method: string, params: object) => Promise<unknown> = postNative) {
          return send("run.atach", { id });
        }
        function toggle(on: boolean, call: (method: string, params: object) => Promise<unknown>) {
          return call("pane.setRemoteContrl", { on });
        }
        toggle(true, callNative);
        function daemonRead(daemon: (method: string, params: object) => Promise<unknown>) {
          return daemon("_acpmux/info", {});
        }
        const H = "cmuxNope";
        window.webkit?.messageHandlers?.[H]?.postMessage({});
      `,
    };
    const refused = sentMethods([file]).map((entry) => refusal(entry, new Set(["chat.send"])));
    expect(refused.filter(Boolean)).toEqual([
      "webviews/src/agent-session/acpmux/fake.ts:7: the app has no method 'account.ad'",
      expect.stringContaining("link.inspect takes"),
      "webviews/src/agent-session/acpmux/fake.ts:11: the app has no method 'run.atach'",
      "webviews/src/agent-session/acpmux/fake.ts:14: the app has no method 'pane.setRemoteContrl'",
    ]);
    expect([...handlerNames([file]).keys()]).toEqual(["cmuxNope"]);
  });
});

function sourceSwift(dir: string): string {
  let text = "";
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) text += sourceSwift(path);
    else if (entry.name.endsWith(".swift")) text += readFileSync(path, "utf8");
  }
  return text;
}
