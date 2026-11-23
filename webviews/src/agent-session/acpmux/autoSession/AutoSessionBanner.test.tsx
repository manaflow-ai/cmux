// What an Auto chat draws under its header (AutoSessionBanner.tsx): one line per state, the one
// action a blocked chat has, and the kept-changes notice's Show, Apply and Discard.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { AutoSessionBanner, LEFTOVER_FILES_SHOWN, type AutoSessionBannerProps } from "./AutoSessionBanner";
import type { AutoSession } from "./autoSession";
import type { LeftoverAction } from "./leftover";
import { translate } from "../i18n";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
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
    localStorage: dom.window.localStorage,
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

const auto = (over: Partial<AutoSession> = {}): AutoSession => ({
  auto: true,
  state: "local",
  here: true,
  keepInCloud: false,
  ...over,
});

async function render(container: HTMLElement, props: Partial<AutoSessionBannerProps> & { auto: AutoSession }) {
  root ??= createRoot(container);
  await act(async () => {
    root!.render(
      <AutoSessionBanner
        sending={false}
        onSetUpCloud={() => undefined}
        onLeftover={() => Promise.resolve(undefined)}
        onFailed={() => undefined}
        noteDelayMs={0}
        {...props}
      />,
    );
  });
}

const click = async (container: HTMLElement, label: string) => {
  const button = [...container.querySelectorAll("button")].find((each) => each.textContent === label);
  if (!button) throw new Error(`no button "${label}" in: ${container.textContent}`);
  await act(async () => {
    button.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
};
const buttons = (container: HTMLElement) => [...container.querySelectorAll("button")].map((each) => each.textContent);

test("a chat this Mac runs draws nothing, and each other state draws its one line", async () => {
  const container = installDom();
  await render(container, { auto: auto() });
  expect(container.textContent).toBe("");
  await render(container, { auto: auto({ state: "cloud", here: false }) });
  expect(container.querySelector('[data-auto="cloud"]')?.textContent).toBe(translate("auto.state.cloud"));
  await render(container, { auto: auto({ state: "resuming", here: false }) });
  expect(container.querySelector('[data-auto="resuming"]')?.textContent).toBe(translate("composer.envResuming"));
  await render(container, { auto: auto({ state: "coming_back", here: false }) });
  expect(container.querySelector('[data-auto="comingBack"]')?.textContent).toBe(
    translate("auto.state.cloud") + translate("auto.state.comingBack"),
  );
  expect(container.querySelectorAll("[data-auto]").length).toBe(1);
});

test("a chat nobody runs says nothing until a send, then Resuming", async () => {
  const container = installDom();
  const parked = auto({ state: "parked", here: false });
  await render(container, { auto: parked });
  expect(container.textContent).toBe("");
  await render(container, { auto: parked, sending: true });
  expect(container.querySelector('[data-auto="resuming"]')?.textContent).toBe(translate("composer.envResuming"));
});

test("a resume stays out of sight at first, as a paused machine's does", async () => {
  const container = installDom();
  await render(container, { auto: auto({ state: "resuming", here: false }), noteDelayMs: undefined });
  const slot = container.querySelector(".acpmux-peer-copy-slot");
  expect(slot).not.toBeNull();
  expect(slot!.hasAttribute("data-shown")).toBe(false);
  // A settled state is said at once.
  await render(container, { auto: auto({ state: "cloud", here: false }), noteDelayMs: undefined });
  expect(container.querySelector(".acpmux-peer-copy-slot")!.hasAttribute("data-shown")).toBe(true);
});

test("a blocked chat says why in one line, and only a missing machine has an action", async () => {
  const container = installDom();
  let setUps = 0;
  const onSetUpCloud = () => setUps++;
  await render(container, { auto: auto({ blocked: "no_machine" }), onSetUpCloud });
  expect(container.querySelector('[data-auto="no_machine"] span')?.textContent).toBe(
    translate("auto.blocked.noMachine"),
  );
  await click(container, translate("composer.newCloudMachine"));
  expect(setUps).toBe(1);
  await render(container, { auto: auto({ blocked: "too_large" }), onSetUpCloud });
  expect(container.querySelector('[data-auto="too_large"]')?.textContent).toBe(translate("auto.blocked.tooLarge"));
  expect(buttons(container)).toEqual([]);
  await render(container, { auto: auto({ state: "cloud", here: false, blocked: "offline" }), onSetUpCloud });
  expect(container.querySelector('[data-auto="offline"]')?.textContent).toBe(translate("auto.blocked.offline"));
  expect(container.querySelector('[data-auto="cloud"]')).toBeNull();
  expect(buttons(container)).toEqual([]);
});

test("no line names how Auto works", async () => {
  const container = installDom();
  const said: string[] = [];
  for (const each of [
    auto({ state: "cloud", here: false }),
    auto({ state: "resuming", here: false }),
    auto({ state: "coming_back", here: false }),
    auto({ blocked: "no_machine" }),
    auto({ blocked: "too_large" }),
    auto({ blocked: "offline" }),
    auto({ leftover: { files: 2 } }),
  ]) {
    await render(container, { auto: each });
    said.push(container.textContent ?? "");
  }
  expect(said.every((text) => text.length > 0)).toBe(true);
  expect(said.join(" ")).not.toMatch(/lease|epoch|mirror|snapshot|pause/i);
});

test("the kept-changes notice shows the files, applies them, and discards only after a second click", async () => {
  const container = installDom();
  const asked: LeftoverAction[] = [];
  const files = Array.from({ length: LEFTOVER_FILES_SHOWN + 3 }, (_, index) => `src/file-${index}.ts`);
  const onLeftover = (action: LeftoverAction) => {
    asked.push(action);
    return Promise.resolve(action === "show" ? { files } : undefined);
  };
  await render(container, { auto: auto({ leftover: { files: files.length } }), onLeftover });
  const notice = () => container.querySelector('[data-auto="leftover"]')!;
  expect(notice().querySelector("p")?.textContent).toBe(translate("auto.leftover.notice"));
  expect(buttons(container)).toEqual([
    translate("auto.leftover.show"),
    translate("auto.leftover.apply"),
    translate("auto.leftover.discard"),
  ]);

  await click(container, translate("auto.leftover.show"));
  expect([...notice().querySelectorAll("code")].map((each) => each.textContent)).toEqual(
    files.slice(0, LEFTOVER_FILES_SHOWN),
  );
  expect(notice().querySelector("[data-auto-files] span")?.textContent).toBe(
    translate("planBuild.moreFiles", { n: 3 }),
  );
  await click(container, translate("rules.hide"));
  expect(notice().querySelector("code")).toBeNull();

  // Discard asks first; Keep backs out and nothing was sent.
  await click(container, translate("auto.leftover.discard"));
  expect(notice().textContent).toContain(translate("auto.leftover.discardAsk"));
  expect(buttons(container)).toEqual([translate("auto.leftover.discard"), translate("header.worktreeRemoveKeep")]);
  await click(container, translate("header.worktreeRemoveKeep"));
  expect(asked).toEqual(["show"]);

  await click(container, translate("auto.leftover.discard"));
  await click(container, translate("auto.leftover.discard"));
  await click(container, translate("auto.leftover.apply"));
  expect(asked).toEqual(["show", "discard", "apply"]);

  // The row drops its leftover: the notice goes.
  await render(container, { auto: auto(), onLeftover });
  expect(container.textContent).toBe("");
});

test("a leftover action that fails is said, and the notice stays", async () => {
  const container = installDom();
  const failed: string[] = [];
  await render(container, {
    auto: auto({ leftover: { files: 1 } }),
    onLeftover: (action) => (action === "show" ? Promise.resolve({ files: [] }) : Promise.reject(new Error("no"))),
    onFailed: (text) => failed.push(text),
  });
  await click(container, translate("auto.leftover.show"));
  await click(container, translate("auto.leftover.apply"));
  await click(container, translate("auto.leftover.discard"));
  await click(container, translate("auto.leftover.discard"));
  expect(failed).toEqual([
    translate("auto.leftover.showFailed"),
    translate("auto.leftover.applyFailed"),
    translate("auto.leftover.discardFailed"),
  ]);
  expect(container.querySelector('[data-auto="leftover"]')).not.toBeNull();
  expect(buttons(container)).toEqual([
    translate("auto.leftover.show"),
    translate("auto.leftover.apply"),
    translate("auto.leftover.discard"),
  ]);
});
