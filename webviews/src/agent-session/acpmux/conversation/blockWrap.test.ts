// The form a Shell card and a call's output open in. Leo, 2026-11-11, on a Shell card whose one long
// output line ran off the right edge: "shouldn't this be... not horizontally scrolled? as in, it goes
// down instead of to the right?" So output wraps down; but a table keeps each printed row on its own
// line, columns aligned (Leo, 2026-11-04, on a Shell card whose `ps` table had every row folded back
// under itself: "why isn't this just prettified by default?"). Wrap lines (the card's one toggle,
// blockWrap.ts) flips every output block. A diff of a code file keeps its lines; prose still wraps.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { blockWrapOf, outputWraps, setBlockWrap } from "./blockWrap";

// A viewer who never touched Wrap lines: a storage of its own, so what another test in this
// process chose (the module keeps the last choice) is not what these read.
const scope = globalThis as { localStorage?: Storage };
let had: PropertyDescriptor | undefined;
beforeEach(() => {
  had = Object.getOwnPropertyDescriptor(scope, "localStorage");
  const store = new Map<string, string>();
  Object.defineProperty(scope, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => void store.set(key, value),
      removeItem: (key: string) => void store.delete(key),
    } as unknown as Storage,
  });
});
afterEach(() => {
  if (had) Object.defineProperty(scope, "localStorage", had);
  else delete scope.localStorage;
});

test("a call's output wraps down by default", () => {
  expect(blockWrapOf("output")).toBe(true);
});

const LEO_LINE =
  "Command running in background with ID: baimgy381. Output is being written to: /private/tmp/claude-501/-Users-leoli-Projects/01a18a35-b23b-7b61-9798-dba14474a974/tasks/baimgy381.output";
const PS = [
  "  PID TTY           TIME CMD",
  " 4821 ttys001    0:00.12 -zsh",
  " 5120 ttys002    0:03.40 node /usr/local/bin/vite --port 5173 --host 127.0.0.1 --strictPort",
  " 5188 ttys002    0:00.02 bun test test/transcript-block-overflow.test.tsx",
].join("\n");

test("an output wraps by its shape: a long line, a path or indented text wraps, a table keeps its rows", () => {
  expect(outputWraps(LEO_LINE)).toBe(true);
  expect(outputWraps("x".repeat(300))).toBe(true);
  // Indentation is not a column gap: a stack trace or pretty JSON wraps.
  expect(outputWraps("Error: boom\n    at run (/a/b.ts:1:2)\n    at main (/a/c.ts:3:4)")).toBe(true);
  expect(outputWraps('{\n  "a": 1,\n  "b": "two"\n}')).toBe(true);
  // One gapped line in prose is not a table.
  expect(outputWraps("Done.  Next step\nline two\nline three")).toBe(true);
  expect(outputWraps(PS)).toBe(false);
  expect(outputWraps("a\tb\tc\n1\t2\t3")).toBe(false);
  expect(outputWraps("src\n├── a.ts\n└── b.ts")).toBe(false);
  expect(outputWraps(undefined)).toBe(true);
});

test("the viewer's pick holds over every block's shape, and an old aligned-default pick does not", () => {
  // A pick from when output had one fixed default (the `output` field) no longer pins it.
  globalThis.localStorage!.setItem("cmux.agentPane.blockWrap", JSON.stringify({ output: false }));
  expect(blockWrapOf("output")).toBe(true);
  setBlockWrap("output", false);
  expect(blockWrapOf("output")).toBe(false);
  expect(JSON.parse(globalThis.localStorage!.getItem("cmux.agentPane.blockWrap")!)).toEqual({ outputByShape: false });
});

test("prose still wraps and code still does not", () => {
  expect({ prose: blockWrapOf("prose"), code: blockWrapOf("code") }).toEqual({ prose: true, code: false });
});

test("Wrap lines flips output to one form and back", () => {
  setBlockWrap("output", false);
  expect(blockWrapOf("output")).toBe(false);
  setBlockWrap("output", true);
  expect(blockWrapOf("output")).toBe(true);
});
