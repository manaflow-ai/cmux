// l10n-allow-file: test fixtures.
// The held messages panel's search reaches the inbox's archive (SurgeArchiveResults.tsx): posts
// evicted from the live inbox and older text in a live thread, found by a debounced or submitted
// search, paged, each opening to its whole original; never one read per keystroke or arriving post.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SurgeHoldRow } from "./SurgeHoldRow";
import type { SurgeHold } from "./conversation/surgeHold";
import { ARCHIVE_DEBOUNCE_MS } from "./conversation/surgeHold";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
    });
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const wait = (ms: number) =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });

// The live listing holds one thread; the archive also holds a post evicted from the inbox and an
// older post of the live thread, neither of which the listing's previews carry.
const LISTING = {
  threads: [
    {
      threadId: "pr:48120",
      label: "#48120",
      from: ["lane-7"],
      count: 1,
      newestAt: 100,
      newestPreview: "Can you lift the freeze?",
      class: "blocker",
      surgeHeld: true,
    },
  ],
};
const OLDER = "Earlier on #48120: the macos-15 queue was busy.\n\nSecond paragraph with the whole detail.";
const EVICTED = "runner-capacity: fleet queue drained after 42 min";

type Search = { search: string; before?: string | number };

async function render(pages: (call: Search) => unknown) {
  const container = installDom();
  const searches: Search[] = [];
  const surge: SurgeHold = { held: 12, needYou: 1, seq: 1 };
  const draw = (next: SurgeHold) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(
        <SurgeHoldRow
          surge={next}
          sessionId="s1"
          listThreads={async () => LISTING}
          readThread={async () => []}
          onOpenSender={() => undefined}
          searchArchive={async (search, before) => {
            const call = { search, ...(before !== undefined && { before }) };
            searches.push(call);
            return pages(call);
          }}
          initiallyOpen
        />,
      );
    });
  await draw(surge);
  await wait(0);
  return { container, searches, draw };
}

const type = (container: HTMLElement, value: string) =>
  act(async () => {
    const input = container.querySelector<HTMLInputElement>(".acpmux-surge-search input")!;
    Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });

const click = (element: Element | null | undefined) =>
  act(async () => {
    element!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });

const hits = (container: HTMLElement) =>
  [...container.querySelectorAll(".acpmux-surge-hit")].map((node) => node.textContent ?? "");

const onePage = () => ({
  hits: [
    {
      seq: 90,
      at: Date.now() - 60_000,
      promptId: "p90",
      threadId: "topic:runner-capacity",
      text: EVICTED,
      from: "runner-watch",
    },
    {
      seq: 12,
      at: Date.now() - 3_600_000,
      promptId: "p12",
      threadId: "pr:48120",
      text: OLDER,
      from: "lane-7",
      sender: { session: "abc", label: "lane-7" },
    },
  ],
});

test("typing settles into one archive read; evicted and older posts show and open to their whole original", async () => {
  const { container, searches } = await render(onePage);
  for (const partial of ["f", "fl", "fle", "flee", "fleet"]) await type(container, partial);
  expect(searches.length).toBe(0);
  await wait(ARCHIVE_DEBOUNCE_MS + 60);
  expect(searches).toEqual([{ search: "fleet" }]);
  const lines = hits(container);
  expect(lines.length).toBe(2);
  expect(lines[0]).toContain("runner-watch");
  expect(lines[0]).toContain("fleet queue drained");
  // Shut, a hit shows its first line; open, the whole original, every paragraph.
  expect(container.textContent).not.toContain("Second paragraph");
  await click(container.querySelectorAll(".acpmux-surge-hit-line")[1]);
  expect(container.querySelector(".acpmux-surge-hit-body")?.textContent).toContain(
    "Second paragraph with the whole detail.",
  );
  expect(container.querySelectorAll(".acpmux-surge-hit-line")[1]?.getAttribute("aria-expanded")).toBe("true");
});

test("Enter searches at once; a one-letter search asks nothing", async () => {
  const { container, searches } = await render(onePage);
  await type(container, "q");
  await act(async () => {
    container
      .querySelector("form.acpmux-surge-search")!
      .dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  await wait(ARCHIVE_DEBOUNCE_MS + 60);
  expect(searches.length).toBe(0);
  await type(container, "macos");
  await act(async () => {
    container
      .querySelector("form.acpmux-surge-search")!
      .dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  await wait(0);
  expect(searches).toEqual([{ search: "macos" }]);
  // The debounce that follows asks for the same search: no second read.
  await wait(ARCHIVE_DEBOUNCE_MS + 60);
  expect(searches.length).toBe(1);
});

test("results page with the archive's cursor, one read per More, a repeated hit drawn once", async () => {
  const { container, searches } = await render(({ before }) =>
    before === undefined
      ? { hits: [{ seq: 50, threadId: "t", text: "page one fleet", from: "a" }], next: "c1" }
      : before === "c1"
        ? {
            hits: [
              { seq: 50, threadId: "t", text: "page one fleet", from: "a" },
              { seq: 20, threadId: "t", text: "page two fleet", from: "b" },
            ],
            next: 7,
          }
        : { hits: [{ seq: 3, threadId: "t", text: "page three fleet", from: "c" }] },
  );
  await type(container, "fleet");
  await wait(ARCHIVE_DEBOUNCE_MS + 60);
  expect(hits(container).length).toBe(1);
  await click(container.querySelector(".acpmux-surge-archive .acpmux-surge-more"));
  await wait(0);
  expect(hits(container).length).toBe(2);
  await click(container.querySelector(".acpmux-surge-archive .acpmux-surge-more"));
  await wait(0);
  expect(hits(container).map((line) => line.includes("page three"))).toEqual([false, false, true]);
  expect(container.querySelector(".acpmux-surge-archive .acpmux-surge-more")).toBeNull();
  expect(searches).toEqual([{ search: "fleet" }, { search: "fleet", before: "c1" }, { search: "fleet", before: 7 }]);
});

test("posts arriving while results show read nothing more", async () => {
  const { container, searches, draw } = await render(onePage);
  await type(container, "fleet");
  await wait(ARCHIVE_DEBOUNCE_MS + 60);
  for (let n = 13; n <= 40; n += 1) await draw({ held: n, needYou: 1, seq: n });
  await wait(ARCHIVE_DEBOUNCE_MS + 60);
  expect(searches.length).toBe(1);
  expect(hits(container).length).toBe(2);
});

test("a failed search says so and Try again asks the same page again", async () => {
  let fail = true;
  const { container, searches } = await render(() => {
    if (fail) throw new Error("offline");
    return onePage();
  });
  await type(container, "fleet");
  await wait(ARCHIVE_DEBOUNCE_MS + 60);
  expect(container.querySelector('.acpmux-surge-archive [role="alert"]')).not.toBeNull();
  fail = false;
  await click(container.querySelector(".acpmux-surge-archive .acpmux-surge-retry"));
  await wait(0);
  expect(searches).toEqual([{ search: "fleet" }, { search: "fleet" }]);
  expect(hits(container).length).toBe(2);
});
