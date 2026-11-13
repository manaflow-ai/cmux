import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { parsePatchFiles } from "@pierre/diffs";
import { PlainEnglishView, type PlainEnglishFile } from "./PlainEnglishView";
import { SummaryStore, type SummaryFileDiff } from "./hunkSummaries";

// Plain English asks only for the hunks in or near the window: a 40-file change costs the hunks
// on screen. Each row keeps its height while its sentence loads, then shows the sentence.
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

/** An IntersectionObserver the test drives: `show(ids)` makes exactly those rows intersect. */
class FakeObserver {
  static last: FakeObserver | null = null;
  readonly observed = new Set<Element>();
  disconnected = false;
  constructor(private readonly callback: (entries: { target: Element; isIntersecting: boolean }[]) => void) {
    FakeObserver.last = this;
  }
  observe(element: Element) {
    this.observed.add(element);
  }
  unobserve(element: Element) {
    this.observed.delete(element);
  }
  disconnect() {
    this.disconnected = true;
    this.observed.clear();
  }
  show(ids: readonly string[]) {
    this.callback(
      [...this.observed].map((target) => ({
        target,
        isIntersecting: ids.includes((target as HTMLElement).dataset.hunkId ?? ""),
      })),
    );
  }
}

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IntersectionObserver: FakeObserver,
    requestAnimationFrame: (run: () => void) => frames.push(run),
    cancelAnimationFrame: (id: number) => {
      frames[id - 1] = () => {};
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
  FakeObserver.last = null;
  frames = [];
});

/** A fixture diff of `files` files with `hunks` hunks each. */
function files(count: number, hunks: number): PlainEnglishFile[] {
  return Array.from({ length: count }, (_, f) => {
    let patch = `diff --git a/src/f${f}.ts b/src/f${f}.ts\n--- a/src/f${f}.ts\n+++ b/src/f${f}.ts\n`;
    for (let h = 0; h < hunks; h++) {
      const line = 1 + h * 20;
      patch += `@@ -${line},2 +${line},2 @@\n context ${h}\n-old ${f}.${h}\n+new ${f}.${h}\n`;
    }
    const fileDiff = parsePatchFiles(patch)[0]!.files[0] as unknown as SummaryFileDiff;
    return { itemId: `item-${f}`, fileDiff };
  });
}

const label = (key: string) => key;
/** The animation frames asked for, run by `frame()`: the next frame, then the answers it led to. */
let frames: (() => void)[] = [];
async function frame() {
  const due = frames;
  frames = [];
  for (const run of due) run();
  // The asks' promises settle, and their rows render.
  await Promise.resolve();
  await Promise.resolve();
}

test("only hunks near the window are asked for; scrolled-away ones are dropped", async () => {
  const container = installDom();
  const asked: string[] = [];
  const answers = new Map<string, (text: string) => void>();
  const store = new SummaryStore(
    (path, patch) =>
      new Promise((resolve) => {
        const id = `${path}|${patch.split("\n").at(-1)}`;
        asked.push(id);
        answers.set(id, resolve);
      }),
  );
  root = createRoot(container);
  await act(async () => root!.render(<PlainEnglishView files={files(40, 3)} store={store} label={label as any} />));
  const observer = FakeObserver.last!;
  expect(observer.observed.size).toBe(120);
  // Nothing has been seen: nothing is asked.
  await act(frame);
  expect(asked).toEqual([]);

  // Three rows come into view: at most two asks run, in reading order.
  await act(async () => observer.show(["item-0#0", "item-0#1", "item-0#2"]));
  await act(frame);
  expect(asked).toEqual(["src/f0.ts|+new 0.0", "src/f0.ts|+new 0.1"]);

  // The person scrolls far down before those answer: item-0#2 is never asked.
  await act(async () => observer.show(["item-30#0"]));
  await act(frame);
  await act(async () => {
    answers.get("src/f0.ts|+new 0.0")!("Renames old 0.0 to new 0.0.");
    answers.get("src/f0.ts|+new 0.1")!("Renames old 0.1.");
  });
  await act(frame);
  expect(asked).toEqual(["src/f0.ts|+new 0.0", "src/f0.ts|+new 0.1", "src/f30.ts|+new 30.0"]);
  expect(asked.length).toBeLessThan(120);

  // The answered row shows its sentence in the same row; the loading row its code preview.
  const row = (id: string) => container.querySelector(`[data-hunk-id="${id}"] .plain-english-row`) as HTMLElement;
  expect(row("item-0#0").dataset.state).toBe("ready");
  expect(row("item-0#0").textContent).toContain("Renames old 0.0 to new 0.0.");
  expect(row("item-0#0").dataset.arrives).toBe("true");
  expect(row("item-30#0").dataset.state).toBe("loading");
  expect(row("item-30#0").querySelector(".plain-english-preview")?.textContent).toBe("new 30.0");
  expect(row("item-30#0").getAttribute("aria-busy")).toBe("true");
});

test("a sentence known when its row mounts is drawn in place, and the code unfolds on click", async () => {
  const container = installDom();
  const store = new SummaryStore(async () => "Renames old to new.");
  const fixture = files(1, 1);
  root = createRoot(container);
  await act(async () => root!.render(<PlainEnglishView files={fixture} store={store} label={label as any} />));
  await act(async () => FakeObserver.last!.show(["item-0#0"]));
  await act(frame);
  // Toggled off and on again: the kept sentence is there from the first frame, with no slide.
  await act(async () => root!.render(<div />));
  await act(async () => root!.render(<PlainEnglishView files={fixture} store={store} label={label as any} />));
  const row = container.querySelector(".plain-english-row") as HTMLElement;
  expect(row.dataset.state).toBe("ready");
  expect(row.dataset.arrives).toBeUndefined();
  expect(row.getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelector(".plain-english-code")).toBeNull();
});

test("unmounting disconnects the observer", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <PlainEnglishView files={files(2, 1)} store={new SummaryStore(async () => "")} label={label as any} />,
    ),
  );
  const observer = FakeObserver.last!;
  await act(async () => root!.unmount());
  root = undefined;
  expect(observer.disconnected).toBe(true);
});
