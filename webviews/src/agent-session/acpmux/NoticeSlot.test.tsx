// One notice at a time above the composer (hq#2569 #12): of every notice that wants to show, only
// the highest tier draws, an agent CLI update never covers an error, and a waiting notice shows
// once the one above it clears.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HarnessHealthNotice } from "./HarnessHealthNotice";
import { type HarnessHealth } from "./harnessHealthNoticeModel";
import { Notice, NoticeSlot } from "./NoticeSlot";
import { type NoticeTier, topNotice } from "./noticeSlotModel";
import { settleReact } from "../../../test/support/domTeardown";
import { acpmuxPerf } from "./perf";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

type Line = { id: string; tier: NoticeTier; when: boolean };

async function render(container: HTMLElement, lines: Line[], extra?: React.ReactNode) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <NoticeSlot>
        {lines.map(({ id, tier, when }) => (
          <Notice key={id} id={id} tier={tier} when={when}>
            <p data-line={id}>{id}</p>
          </Notice>
        ))}
        {extra}
      </NoticeSlot>,
    );
  });
}

const shown = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>("[data-line], [data-harness-notice]")].map(
    (element) => element.dataset.line ?? `harness:${element.dataset.harnessNotice}`,
  );

test("with several notices, only the highest tier draws", async () => {
  const container = installDom();
  await render(container, [
    { id: "folder-hint", tier: "hint", when: true },
    { id: "worktree-creating", tier: "status", when: true },
    { id: "host-error", tier: "error", when: true },
    { id: "update", tier: "update", when: true },
  ]);
  expect(shown(container)).toEqual(["host-error"]);
});

test("a waiting notice shows once the one above it clears, and nothing shows when none wants to", async () => {
  const container = installDom();
  const lines: Line[] = [
    { id: "folder-hint", tier: "hint", when: true },
    { id: "host-error", tier: "error", when: true },
  ];
  await render(container, lines);
  expect(shown(container)).toEqual(["host-error"]);
  await render(container, [lines[0]!, { ...lines[1]!, when: false }]);
  expect(shown(container)).toEqual(["folder-hint"]);
  await render(container, [
    { ...lines[0]!, when: false },
    { ...lines[1]!, when: false },
  ]);
  expect(shown(container)).toEqual([]);
  // A new error takes the slot back.
  await render(container, [lines[0]!, lines[1]!]);
  expect(shown(container)).toEqual(["host-error"]);
});

test("on a tie the notice that asked first keeps the slot", async () => {
  const container = installDom();
  await render(container, [{ id: "import-error", tier: "error", when: true }]);
  await render(container, [
    { id: "host-error", tier: "error", when: true },
    { id: "import-error", tier: "error", when: true },
  ]);
  expect(shown(container)).toEqual(["import-error"]);
  expect(
    topNotice(
      new Map([
        ["b", { tier: 40, order: 2 }],
        ["a", { tier: 40, order: 1 }],
        ["c", { tier: 10, order: 0 }],
      ]),
    ),
  ).toBe("a");
  expect(topNotice(new Map())).toBeUndefined();
});

const codex = (health: HarnessHealth, native: (method: string) => Promise<unknown>) => (
  <HarnessHealthNotice
    health={health}
    harness="codex"
    name="Codex"
    open={() => undefined}
    native={native}
    onOffer={() => undefined}
  />
);
const outdated: HarnessHealth = {
  id: "codex",
  auth: "signedIn",
  version: "0.3.1",
  latest: "0.4.0",
  outdated: true,
  update: { command: "npm install -g @openai/codex@latest", elevated: false },
};

test("an update on offer never draws a line over the chat, even alone", async () => {
  const container = installDom();
  await render(
    container,
    [],
    codex(outdated, () => new Promise(() => undefined)),
  );
  expect(shown(container)).toEqual([]);
});

test("an agent CLI update in progress never covers an error, and shows again once the error clears", async () => {
  const container = installDom();
  let offered: { update(): void } | undefined;
  const native = () => new Promise<unknown>(() => undefined);
  const notice = (
    <HarnessHealthNotice
      health={outdated}
      harness="codex"
      name="Codex"
      open={() => undefined}
      native={native}
      onOffer={(offer) => (offered = offer)}
    />
  );
  await render(container, [], notice);
  await act(async () => offered!.update());
  expect(shown(container)).toEqual(["harness:outdated"]);
  await render(container, [{ id: "host-error", tier: "error", when: true }], notice);
  expect(shown(container)).toEqual(["host-error"]);
  await render(container, [{ id: "host-error", tier: "error", when: false }], notice);
  expect(shown(container)).toEqual(["harness:outdated"]);
});

test("a signed-out agent CLI is an error: it outranks a hint", async () => {
  const container = installDom();
  const signedOut: HarnessHealth = { id: "codex", auth: "signedOut", login: "codex login", outdated: false };
  await render(
    container,
    [{ id: "folder-hint", tier: "hint", when: true }],
    codex(signedOut, () => new Promise(() => undefined)),
  );
  expect(shown(container)).toEqual(["harness:signedOut"]);
});

test("notices outside a slot (a gallery) always draw", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <>
        <Notice id="a" tier="hint" when>
          <p data-line="a">a</p>
        </Notice>
        <Notice id="b" tier="error" when>
          <p data-line="b">b</p>
        </Notice>
      </>,
    );
  });
  expect(shown(container)).toEqual(["a", "b"]);
});

// Leo, 2026-11-19, watching a busy coordinator chat: "why stuff redraw often?". The pane renders on every snapshot
// that is not a streamed chunk (a tool call, its result, a new row) and hands each of its notices new children then,
// though nearly all of them want to show nothing. A notice that shows nothing draws nothing, so it renders again only
// when it comes to show; one that shows draws its new children.
test("a notice that shows nothing does not render again for its parent's new children", async () => {
  const container = installDom();
  acpmuxPerf.enable(new EventTarget());
  const draw = (count: number) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(
        <NoticeSlot>
          {["dictation", "cloud-hint", "import-error", "instructions", "switch", "background"].map((id) => (
            <Notice key={id} id={id} tier="error" when={false}>
              {/* A new element on each of the parent's renders, as the pane's inline children are. */}
              <p data-line={id}>{`${id} ${count}`}</p>
            </Notice>
          ))}
          <Notice id="managed-by" tier="status" when>
            <p data-line="managed-by">{`managed-by ${count}`}</p>
          </Notice>
        </NoticeSlot>,
      );
    });
  await draw(0);
  acpmuxPerf.resetRenders();
  for (let count = 1; count <= 10; count += 1) await draw(count);
  // The shown one draws each new child; the six that show nothing, none.
  expect(acpmuxPerf.renders.get("notice:managed-by")).toBe(10);
  expect(
    [...acpmuxPerf.renders].filter(([name]) => name.startsWith("notice:") && name !== "notice:managed-by"),
  ).toEqual([]);
  expect(container.querySelector('[data-line="managed-by"]')?.textContent).toBe("managed-by 10");
  // One that comes to show draws its newest children at once.
  await act(async () =>
    root!.render(
      <NoticeSlot>
        <Notice id="switch" tier="error" when>
          <p data-line="switch">switch 11</p>
        </Notice>
      </NoticeSlot>,
    ),
  );
  expect(shown(container)).toEqual(["switch"]);
  expect(container.querySelector('[data-line="switch"]')?.textContent).toBe("switch 11");
  acpmuxPerf.resetRenders();
});
