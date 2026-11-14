// ESLint-compatible rules for performance footguns that past fixes removed, shared by vp lint and the
// check:perf-footguns piece (perf-footguns.json). Each rule names the fix it keeps from coming back.
// docs/cmux-next/modding-kit.md lists them for anyone editing webviews, cmux live included.

const functions = new Set(["ArrowFunctionExpression", "FunctionExpression", "FunctionDeclaration"]);
const loops = new Set(["ForStatement", "ForInStatement", "ForOfStatement", "WhileStatement", "DoWhileStatement"]);
// Array methods whose callback runs once per item.
const perItem = new Set(["forEach", "map", "flatMap", "filter", "some", "every", "reduce", "find", "findIndex"]);

// Reading these makes the engine lay out a dirty page before it answers.
const layoutProperties = new Set([
  "offsetWidth",
  "offsetHeight",
  "offsetTop",
  "offsetLeft",
  "offsetParent",
  "clientWidth",
  "clientHeight",
  "clientTop",
  "clientLeft",
  "scrollWidth",
  "scrollHeight",
  "innerText",
]);
const layoutCalls = new Set(["getBoundingClientRect", "getClientRects", "getComputedStyle", "elementFromPoint"]);
// These dirty layout: a style or class change, or a DOM insert or removal.
const styleCalls = new Set(["setProperty", "removeProperty"]);
const classCalls = new Set(["add", "remove", "toggle", "replace"]);
const domCalls = new Set([
  "appendChild",
  "insertBefore",
  "removeChild",
  "replaceChild",
  "replaceChildren",
  "append",
  "prepend",
  "before",
  "after",
  "replaceWith",
  "insertAdjacentElement",
  "insertAdjacentHTML",
]);
const dirtyingAssignments = new Set(["className", "innerHTML", "textContent", "outerHTML"]);

const name = (node) => (node?.type === "Identifier" ? node.name : undefined);
const memberName = (node) => (node?.type === "MemberExpression" && !node.computed ? name(node.property) : undefined);

/** "read" for a layout read, "write" for a layout-dirtying write, else undefined. */
function classify(node) {
  if (node.type === "MemberExpression" && layoutProperties.has(memberName(node))) {
    const parent = node.parent;
    const assigned =
      (parent?.type === "AssignmentExpression" && parent.left === node) ||
      (parent?.type === "UpdateExpression" && parent.argument === node);
    if (!assigned) return "read";
  }
  if (node.type === "CallExpression") {
    const callee = node.callee;
    const method = memberName(callee) ?? name(callee);
    if (layoutCalls.has(method)) return "read";
    if (callee.type !== "MemberExpression") return undefined;
    const owner = memberName(callee.object);
    if (owner === "style" && styleCalls.has(method)) return "write";
    if (owner === "classList" && classCalls.has(method)) return "write";
    if (domCalls.has(method)) return "write";
    if (method === "setAttribute" && ["style", "class"].includes(node.arguments[0]?.value)) return "write";
  }
  if (node.type === "AssignmentExpression" && node.left.type === "MemberExpression") {
    const target = node.left;
    if (memberName(target.object) === "style" || memberName(target) === "style") return "write";
    if (dirtyingAssignments.has(memberName(target))) return "write";
  }
  return undefined;
}

/** Collects each function's and each loop body's layout reads and writes, then hands them to `report`. */
function layoutRule(messages, report) {
  return {
    meta: { type: "problem", schema: [], messages },
    create(context) {
      const source = context.sourceCode;
      // Per function, and per loop body: its layout reads and writes.
      const scopes = new Map();
      const scopeOf = (node) => {
        for (let parent = node.parent; parent; parent = parent.parent) {
          if (functions.has(parent.type)) return parent;
        }
        return source.ast;
      };
      // The loops (statements or per-item callbacks) a node runs inside, up to its function.
      const loopsOf = (node) => {
        const found = [];
        for (let child = node, parent = node.parent; parent; child = parent, parent = parent.parent) {
          if (loops.has(parent.type) && child === parent.body) found.push(parent);
          if (functions.has(parent.type)) {
            const call = parent.parent;
            if (call?.type === "CallExpression" && call.arguments[0] === parent && perItem.has(memberName(call.callee)))
              found.push(parent);
            break;
          }
        }
        return found;
      };
      // A per-item callback is both a function and a loop body: keep the two apart.
      const loopScopes = new Map();
      const add = (map, key, event) => {
        if (!map.has(key)) map.set(key, []);
        map.get(key).push(event);
      };
      const visit = (node) => {
        const kind = classify(node);
        if (!kind) return;
        add(scopes, scopeOf(node), { node, kind, loop: false });
        for (const loop of loopsOf(node)) add(loopScopes, loop, { node, kind, loop: true });
      };
      return {
        MemberExpression: visit,
        CallExpression: visit,
        AssignmentExpression: visit,
        "Program:exit"() {
          // A read the loop rule owns (a loop body that also writes) is not the one-turn rule's.
          const inThrashingLoop = new Set();
          for (const events of loopScopes.values()) {
            if (events.some((event) => event.kind === "write"))
              for (const event of events) inThrashingLoop.add(event.node);
          }
          for (const events of [...scopes.values(), ...loopScopes.values()]) {
            const node = report(events, inThrashingLoop);
            if (node) context.report({ node, messageId: "found" });
          }
        },
      };
    },
  };
}

// A loop body that both reads layout and dirties it forces one layout per item, so the cost grows
// with the list. #33624 (transcript rows measured one by one between writes) and #34711 (a hover
// sweep's four forced layouts per row) fixed this shape.
export const layoutThrashInLoop = layoutRule(
  {
    found:
      "This loop reads layout and writes the DOM or styles on every item, so each item forces its own layout and the cost grows with the list. Read every item first, then write (#33624, #34711).",
  },
  (events) =>
    events[0]?.loop && events.some((event) => event.kind === "write")
      ? events.find((event) => event.kind === "read")?.node
      : undefined,
);

// One read after a write in the same turn is one forced layout: cheap once, a jank source on a
// per-frame or per-hover path (#34711). Deliberate probes (measure a hidden copy) are common, so
// this one warns where you edit (`cmux live`, the dev server) and is not part of the repo lint.
export const layoutReadAfterWrite = layoutRule(
  {
    found:
      "Layout read after a DOM or style write in the same turn forces a synchronous layout. Read before you write, or read in the next frame (#34711).",
  },
  (events, inThrashingLoop) => {
    if (events[0]?.loop !== false) return undefined;
    // Only reads the loop rule owns drop out: a write in a write-only loop still counts.
    const sorted = [...events]
      .filter((event) => event.kind === "write" || !inThrashingLoop.has(event.node))
      .sort((a, b) => a.node.range[0] - b.node.range[0]);
    const write = sorted.find((event) => event.kind === "write");
    return write && sorted.find((event) => event.kind === "read" && event.node.range[0] > write.node.range[1])?.node;
  },
);

export default {
  meta: { name: "cmux-perf" },
  rules: { "layout-thrash-in-loop": layoutThrashInLoop, "layout-read-after-write": layoutReadAfterWrite },
};
