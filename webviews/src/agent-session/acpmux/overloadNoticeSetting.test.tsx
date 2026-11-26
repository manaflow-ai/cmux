// l10n-allow-file: test fixtures.
// The "This Mac is overloaded" banner above the composer is a Developer Tools setting, off by
// default (https://github.com/manaflow-ai/cmux/issues/56156): off, the chat never asks acpmux for
// the verdict and draws nothing, even on an overloaded Mac; on, it warns; off again, it goes.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DEFAULT_COMPOSER, setComposerSettings } from "./composerSettings";
import { NoticeSlot } from "./NoticeSlot";
import { OverloadNotice, usePaneHostOverload } from "./OverloadNotice";
import { settleReact } from "../../../test/support/domTeardown";

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
  setComposerSettings(DEFAULT_COMPOSER);
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const overloaded = { overloaded: true, load1: 75, cores: 15, loadOver: true, swapOver: false };

function Pane({ read }: { read: () => Promise<unknown> }) {
  const state = usePaneHostOverload(read);
  return (
    <NoticeSlot>
      <OverloadNotice state={state} />
    </NoticeSlot>
  );
}

test("the overload banner is off by default: no acpmux read and no banner on an overloaded Mac", async () => {
  expect(DEFAULT_COMPOSER.showOverloadNotice).toBe(false);
  setComposerSettings(DEFAULT_COMPOSER);
  const container = installDom();
  let reads = 0;
  const read = () => {
    reads += 1;
    return Promise.resolve(overloaded);
  };
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane read={read} />);
  });
  await act(async () => undefined);
  expect(reads).toBe(0);
  expect(container.querySelector("[data-overload]")).toBeNull();

  await act(async () => setComposerSettings({ showOverloadNotice: true }));
  await act(async () => undefined);
  expect(reads).toBe(1);
  expect(container.querySelector("[data-overload]")).not.toBeNull();

  await act(async () => setComposerSettings({ showOverloadNotice: false }));
  expect(container.querySelector("[data-overload]")).toBeNull();
});
