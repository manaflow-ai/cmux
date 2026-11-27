// ESLint-compatible rules for performance footguns that past fixes removed, shared by vp lint and the
// check:perf-footguns piece (perf-footguns.json). Each rule names the fix it keeps from coming back.
// docs/cmux-next/modding-kit.md lists them for anyone editing webviews, cmux live included.

import { readFileSync } from "node:fs";
import { relative } from "node:path";

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

// Building an Intl formatter resolves the locale, loads ICU data and compiles a pattern: far more than the
// format() it is built for, and a row or render that built one paid it per row per render (Allegro Tech,
// https://blog.allegro.tech/2020/08/using-eslint.html). src/ui/intl.ts hands out one shared formatter per
// locale and options, and starts over each minute so a zone or language change still shows.
const intlKinds = new Set([
  "NumberFormat",
  "DateTimeFormat",
  "RelativeTimeFormat",
  "ListFormat",
  "PluralRules",
  "Collator",
  "Segmenter",
  "DisplayNames",
]);
export const noIntlConstruct = {
  meta: {
    type: "problem",
    schema: [],
    messages: {
      found:
        "Building an Intl.{{kind}} costs far more than formatting with one. Use intl.{{kind}}(...) from src/ui/intl.ts, which shares one per locale and options.",
    },
  },
  create(context) {
    const file = (context.filename ?? context.getFilename?.() ?? "").replaceAll("\\", "/");
    if (file.endsWith("/src/ui/intl.ts")) return {};
    return {
      NewExpression(node) {
        const callee = node.callee;
        if (callee.type !== "MemberExpression" || callee.computed || name(callee.object) !== "Intl") return;
        const kind = name(callee.property);
        if (!intlKinds.has(kind)) return;
        context.report({ node, messageId: "found", data: { kind } });
      },
    };
  },
};

// The chat transcript has one scroll writer (cmuxterm-hq docs/design/agent-transcript-clean-slate.md,
// invariant 1): conversation/scrollController.ts. Twenty-odd writers that each set the offset while
// the others were mid-flight were the jostle Leo saw (2026-11-11: "the jostling is just insane").
// config/vite-plus/check.ts turns this on for the transcript's files only. A write to another element
// in those files (the prompt rail's own list) says so: `// scroll-writer-ok: <why>` on its line or the
// line above.
const scrollWriteCalls = new Set(["scrollTo", "scrollBy", "scrollIntoView"]);
const SCROLL_WRITER_OK = /scroll-writer-ok:\s*\S/;
export const transcriptScrollWriter = {
  meta: {
    type: "problem",
    schema: [],
    messages: {
      found:
        "Only the ScrollController writes the transcript's offset: call writeScrollTop or writeScrollBy from conversation/scrollController.ts, or mark another element's write `// scroll-writer-ok: <why>`.",
    },
  },
  create(context) {
    const source = context.sourceCode ?? context.getSourceCode();
    const lines = source.text.split("\n");
    const marked = (node) => {
      const line = node.loc.start.line;
      return SCROLL_WRITER_OK.test(lines[line - 1] ?? "") || SCROLL_WRITER_OK.test(lines[line - 2] ?? "");
    };
    const report = (node) => {
      if (!marked(node)) context.report({ node, messageId: "found" });
    };
    return {
      AssignmentExpression(node) {
        if (memberName(node.left) === "scrollTop") report(node);
      },
      UpdateExpression(node) {
        if (memberName(node.argument) === "scrollTop") report(node);
      },
      CallExpression(node) {
        if (scrollWriteCalls.has(memberName(node.callee))) report(node);
      },
    };
  },
};

// A transcript row may not move itself (cmuxterm-hq docs/design/transcript-motion-model.md, "What a row may
// not do"): the list owns every row's motion, so a row that starts its own moves another row the reader
// did not touch (Leo, 2026-11-11: "the jostling is just insane"). Ban 1, the offset, is
// transcript-scroll-writer above; this is the rest a static rule can see in a row component: a
// ResizeObserver, flushSync, an inline translate or transform, and an animated height (`.animate`
// keyframes or a `transition` that names height or translate). config/vite-plus/check.ts turns it on for
// the row components (conversation/*.tsx, transcript/*.tsx). Today's uses are counted per file in
// scripts/lint/row-motion-baseline.json; a file over its count reports every use of that ban, so a new
// one fails and an old one may move. A use that is not a row moving itself says so:
// `// row-motion-ok: <why>` on its line or the line above.
const ROW_MOTION_OK = /row-motion-ok:\s*\S/;
const ROW_MOTION_BASELINE = new URL("./row-motion-baseline.json", import.meta.url);
const WEBVIEWS_ROOT = new URL("../../", import.meta.url).pathname;
let rowMotionBaseline;
const rowMotionAllowed = (file, ban) => {
  rowMotionBaseline ??= JSON.parse(readFileSync(ROW_MOTION_BASELINE, "utf8")).files;
  return rowMotionBaseline[relative(WEBVIEWS_ROOT, file)]?.[ban] ?? 0;
};
const motionProperties = new Set(["translate", "transform"]);
const keyName = (property) =>
  property.type === "Property" && !property.computed
    ? property.key.type === "Identifier"
      ? property.key.name
      : typeof property.key.value === "string"
        ? property.key.value
        : undefined
    : undefined;
const stringOf = (node) =>
  node?.type === "Literal" && typeof node.value === "string"
    ? node.value
    : node?.type === "TemplateLiteral"
      ? node.quasis.map((quasi) => quasi.value.cooked ?? "").join(" ")
      : undefined;
const keyframeObjects = (node) =>
  node?.type === "ArrayExpression"
    ? node.elements.filter((element) => element?.type === "ObjectExpression")
    : node?.type === "ObjectExpression"
      ? [node]
      : [];
export const transcriptRowMotion = {
  meta: {
    type: "problem",
    schema: [],
    messages: {
      found:
        'A transcript row may not {{ban}} (transcript-motion-model.md, "What a row may not do"): ask the list with transition() from conversation/motionOwner.ts, or mark a use that is not the row moving itself `// row-motion-ok: <why>`. This file\'s baseline allows {{allowed}} and it has {{count}} (scripts/lint/row-motion-baseline.json).',
    },
  },
  create(context) {
    const source = context.sourceCode ?? context.getSourceCode();
    const lines = source.text.split("\n");
    const file = context.physicalFilename ?? context.filename ?? context.getFilename();
    const found = new Map();
    const marked = (node) => {
      const line = node.loc.start.line;
      return ROW_MOTION_OK.test(lines[line - 1] ?? "") || ROW_MOTION_OK.test(lines[line - 2] ?? "");
    };
    const note = (ban, node) => {
      if (marked(node)) return;
      if (!found.has(ban)) found.set(ban, []);
      found.get(ban).push(node);
    };
    return {
      NewExpression(node) {
        if (name(node.callee) === "ResizeObserver") note("create a ResizeObserver", node);
      },
      CallExpression(node) {
        const callee = memberName(node.callee) ?? name(node.callee);
        if (callee === "flushSync") note("call flushSync", node);
        if (callee === "setProperty" && motionProperties.has(stringOf(node.arguments[0]))) note("set translate", node);
        if (callee === "animate" && node.callee.type === "MemberExpression") {
          const keys = keyframeObjects(node.arguments[0]).flatMap((frame) => frame.properties.map(keyName));
          if (keys.some((key) => key === "height" || key === "maxHeight" || key === "max-height"))
            note("animate height", node);
          else if (keys.some((key) => motionProperties.has(key))) note("set translate", node);
        }
      },
      AssignmentExpression(node) {
        const property = memberName(node.left);
        if (memberName(node.left.object) !== "style") return;
        if (motionProperties.has(property)) note("set translate", node);
        if (property === "transition" && /height|translate|transform/.test(stringOf(node.right) ?? ""))
          note("animate height", node);
      },
      "Program:exit"() {
        for (const [ban, nodes] of found) {
          const allowed = rowMotionAllowed(file, ban);
          if (nodes.length <= allowed) continue;
          for (const node of nodes)
            context.report({
              node,
              messageId: "found",
              data: { ban, allowed: String(allowed), count: String(nodes.length) },
            });
        }
      },
    };
  },
};

export default {
  meta: { name: "cmux-perf" },
  rules: {
    "layout-thrash-in-loop": layoutThrashInLoop,
    "layout-read-after-write": layoutReadAfterWrite,
    "no-intl-construct": noIntlConstruct,
    "transcript-scroll-writer": transcriptScrollWriter,
    "transcript-row-motion": transcriptRowMotion,
  },
};
