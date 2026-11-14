// A menu's rows as they settle while it is open (rowPresence.ts): on open nothing moves; a data
// change while open grows rows in, keeps leaving rows in place while they shrink out, and fades
// changed words; another list or search replaces rows at once.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { mergeLeavingRows, useRowPresence, type RowMotion } from "./rowPresence";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "getComputedStyle", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const key of keys) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom.window.close();
  for (const key of keys) {
    const value = saved.get(key);
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

type Seen = { rows: readonly string[]; motion: Record<string, RowMotion | undefined> };

function Probe(props: {
  rows: string[];
  open: boolean;
  context?: string;
  labels?: Record<string, string>;
  seen: Seen[];
}) {
  const presence = useRowPresence(props.rows, props.open, props.context ?? "", (value) => props.labels?.[value] ?? "");
  props.seen.push({
    rows: presence.rows,
    motion: Object.fromEntries(presence.rows.map((value) => [value, presence.motion(value)])),
  });
  return null;
}

function render(props: Parameters<typeof Probe>[0]) {
  root ??= createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<Probe {...props} />));
  return props.seen[props.seen.length - 1]!;
}

test("a leaving row goes back where it stood", () => {
  expect(mergeLeavingRows(["a", "b", "c"], ["a", "c"])).toEqual(["a", "b", "c"]);
  expect(mergeLeavingRows(["a", "b", "c"], ["b", "c"])).toEqual(["a", "b", "c"]);
  expect(mergeLeavingRows(["a", "b"], ["c"])).toEqual(["a", "b", "c"]);
});

test("the menu opens with its rows and no motion", () => {
  const seen: Seen[] = [];
  render({ rows: ["mac", "cloud"], open: false, seen });
  const opened = render({ rows: ["mac", "cloud", "another"], open: true, seen });
  expect(opened.rows).toEqual(["mac", "cloud", "another"]);
  expect(Object.values(opened.motion).every((motion) => motion === undefined)).toBe(true);
});

test("a data change while open grows a row in and keeps a leaving one, disabled, in its place", () => {
  const seen: Seen[] = [];
  render({ rows: ["mac", "box", "cloud"], open: true, seen });
  const changed = render({ rows: ["mac", "cloud", "gpu"], open: true, seen });
  expect(changed.rows).toEqual(["mac", "box", "cloud", "gpu"]);
  expect(changed.motion).toEqual({ mac: undefined, box: "leave", cloud: undefined, gpu: "enter" });
});

test("words that change in place fade in; the row count stays", () => {
  const seen: Seen[] = [];
  render({ rows: ["mac", "cloud"], open: true, labels: { cloud: "Cloud" }, seen });
  const changed = render({ rows: ["mac", "cloud"], open: true, labels: { cloud: "Sign in for Cloud" }, seen });
  expect(changed.rows).toEqual(["mac", "cloud"]);
  expect(changed.motion.cloud).toBe("swap");
});

test("another list or a search replaces rows at once", () => {
  const seen: Seen[] = [];
  render({ rows: ["mac", "cloud"], open: true, context: "main", seen });
  const searched = render({ rows: ["gpu"], open: true, context: "machines\u0001g", seen });
  expect(searched.rows).toEqual(["gpu"]);
  expect(searched.motion).toEqual({ gpu: undefined });
});

test("with the app's motion off, a data change replaces rows at once", () => {
  dom.window.document.documentElement.dataset.agentMotion = "off";
  const seen: Seen[] = [];
  render({ rows: ["mac", "box"], open: true, seen });
  const changed = render({ rows: ["mac", "gpu"], open: true, seen });
  expect(changed.rows).toEqual(["mac", "gpu"]);
  expect(changed.motion).toEqual({ mac: undefined, gpu: undefined });
});

for (const gate of ["off", "reduced"])
  test(`with the app's motion gate ${gate}, a data change replaces rows at once`, () => {
    dom.window.document.documentElement.dataset.cmuxMotion = gate;
    const seen: Seen[] = [];
    render({ rows: ["mac", "box"], open: true, seen });
    const changed = render({ rows: ["mac", "gpu"], open: true, seen });
    expect(changed.rows).toEqual(["mac", "gpu"]);
    expect(changed.motion).toEqual({ mac: undefined, gpu: undefined });
  });
