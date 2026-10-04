import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { keepStuckHeaderInView } from "../src/App";
import type { DiffItem } from "../src/diff-stream";
import { isSearchableItem, useDiffFind } from "../src/find/useDiffFind";

let root: Root | null = null;
let dom: JSDOM | null = null;
const globalKeys = ["window", "document", "Element", "Node", "HTMLElement"] as const;
const originals = new Map<string, unknown>(globalKeys.map((key) => [key, (globalThis as any)[key]]));

afterEach(async () => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of originals) {
    if (value === undefined) {
      delete (globalThis as any)[key];
    } else {
      (globalThis as any)[key] = value;
    }
  }
});

function item(
  id: string,
  line: string,
  extra: Partial<DiffItem> = {},
  fileDiff: Record<string, unknown> = {},
): DiffItem {
  return {
    id,
    type: "diff",
    version: 0,
    fileDiff: {
      name: id,
      additionLines: [`${line}\n`],
      deletionLines: [],
      hunks: [
        {
          additionStart: 1,
          additionLineIndex: 0,
          deletionStart: 1,
          deletionLineIndex: 0,
          hunkContent: [{ type: "change", additions: 1, deletions: 0 }],
        },
      ],
      ...fileDiff,
    },
    ...extra,
  } as DiffItem;
}

function fakeCodeView(log: string[]) {
  return {
    current: {
      scrollTo: (target: any) => log.push(`scroll ${target.id}:${target.lineNumber ?? target.type}`),
      getInstance: () => ({ getTopForItem: () => 0, getScrollTop: () => 0 }),
    },
  } as any;
}

function renderFind(items: DiffItem[], query: string, log: string[]) {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>");
  for (const key of globalKeys) {
    (globalThis as any)[key] = key === "window" ? dom.window : (dom.window as any)[key];
  }
  root = createRoot(dom.window.document.getElementById("root")!);
  const codeViewRef = fakeCodeView(log);
  let current: ReturnType<typeof useDiffFind> | null = null;
  function Probe({ initial }: { initial: DiffItem[] }) {
    const [items, setItems] = useState(initial);
    current = useDiffFind({
      items,
      open: true,
      query,
      dispatch: () => {},
      codeViewRef,
      viewerContainerRef: { current: null },
      revealItem: (itemId) => {
        log.push(`reveal ${itemId}`);
        setItems((list) => list.map((entry) => (entry.id === itemId ? { ...entry, collapsed: false } : entry)));
      },
    });
    return null;
  }
  flushSync(() => root?.render(<Probe initial={items} />));
  return async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
    return current!;
  };
}

test("a match in a collapsed file expands that file, then scrolls to the line", async () => {
  const log: string[] = [];
  const find = renderFind(
    [item("open.ts", "nothing here"), item("folded.ts", "needle", { collapsed: true })],
    "needle",
    log,
  );
  expect((await find()).matches.map((match) => match.itemId)).toEqual(["folded.ts"]);
  expect(log).toEqual(["reveal folded.ts", "scroll folded.ts:1"]);
});

test("a match in an expanded file only scrolls", async () => {
  const log: string[] = [];
  await renderFind([item("open.ts", "needle")], "needle", log)();
  expect(log).toEqual(["scroll open.ts:1"]);
});

test("a collapsed generated or large file behind Load diff is not searched", async () => {
  const deferred = item("bun.lock", "needle", { collapsed: true }, { cmuxDeferredReason: "generated" });
  const loaded = item("big.ts", "needle", { collapsed: false }, { cmuxDeferredReason: "large" });
  expect(isSearchableItem(deferred)).toBe(false);
  expect(isSearchableItem(loaded)).toBe(true);
  expect(isSearchableItem(item("folded.ts", "needle", { collapsed: true }))).toBe(true);

  const log: string[] = [];
  const find = renderFind([deferred, loaded], "needle", log);
  expect((await find()).matches.map((match) => match.itemId)).toEqual(["big.ts"]);
  expect(log).toEqual(["scroll big.ts:1"]);
});

test("collapsing a file whose header is stuck scrolls that header back to the top", () => {
  const log: string[] = [];
  const handle = (top: number, scrollTop: number) =>
    ({
      current: {
        getInstance: () => ({ getTopForItem: () => top, getScrollTop: () => scrollTop }),
        scrollTo: (target: any) => log.push(`scroll ${target.type} ${target.id} ${target.align} ${target.behavior}`),
      },
    }) as any;

  // Scrolled into the file's body: the header is stuck.
  keepStuckHeaderInView(handle(1000, 5000), "a.ts", () => log.push("update"));
  expect(log).toEqual(["update", "scroll item a.ts start instant"]);

  // The header is in its own place, or the change expands: nothing to keep.
  log.length = 0;
  keepStuckHeaderInView(handle(1000, 1000), "a.ts", () => log.push("update"));
  keepStuckHeaderInView(handle(1000, 5000), null, () => log.push("update"));
  expect(log).toEqual(["update", "update"]);
});
