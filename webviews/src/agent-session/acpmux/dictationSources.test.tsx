// The mic's hand-off (dictationSources.ts): with a dictation app picked, a press asks the host to
// hand off (`dictation.handoff`, no keys from the page) instead of starting cmux's own dictation,
// and a refusal shows why, naming the app.
import { afterEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setComposerSettings } from "./composerSettings";
import { deliverHandoffFailure, useDictation, type Dictation, type DictationField } from "./dictation";
import { dictationSourceName, handoffFailure } from "./dictationSources";
import { NativeError } from "./nativeError";
import { translate } from "./i18n";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

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
  setComposerSettings({ dictationSource: "cmux" });
});

async function mount(call: (method: string) => Promise<unknown>): Promise<{ current: Dictation | null }> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
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
  const out: { current: Dictation | null } = { current: null };
  function Probe() {
    const field = useRef<DictationField | null>(null);
    out.current = useDictation(field, call);
    return null;
  }
  await act(async () => {
    root = createRoot(dom!.window.document.getElementById("root")!);
    root.render(<Probe />);
  });
  return out;
}

test("with ChatGPT picked, the mic asks the host to hand off, not to start cmux's dictation", async () => {
  setComposerSettings({ dictationSource: "chatgpt" });
  const calls: string[] = [];
  const dictation = await mount(async (method) => calls.push(method));
  await act(async () => dictation.current!.toggle());
  expect(calls.filter((method) => method.startsWith("dictation.") && method !== "dictation.audio")).toEqual([
    "dictation.handoff",
  ]);
});

test("cmux's own source still toggles cmux's dictation", async () => {
  const calls: string[] = [];
  const dictation = await mount(async (method) => calls.push(method));
  await act(async () => dictation.current!.toggle());
  expect(calls).toContain("dictation.toggle");
  expect(calls).not.toContain("dictation.handoff");
});

test("a refused hand-off says why, naming the app", async () => {
  setComposerSettings({ dictationSource: "wisprFlow" });
  const dictation = await mount(async (method) => {
    if (method === "dictation.handoff") throw new NativeError({ code: "dictation.app_not_installed" });
    return undefined;
  });
  await act(async () => dictation.current!.toggle());
  expect(dictation.current!.notice?.state).toBe("failed");
  expect(dictation.current!.notice?.message).toBe(
    handoffFailure("dictation.app_not_installed", "wisprFlow", translate),
  );
  expect(dictation.current!.notice?.message).toContain("Wispr Flow");
});

test("each source has a name", () => {
  expect(dictationSourceName("chatgpt", translate)).toBe("ChatGPT");
  expect(dictationSourceName("cmux", translate)).toBe("cmux");
  expect(dictationSourceName("macos", translate).length).toBeGreaterThan(0);
});

test("a hand-off the shortcut asked for and the host refused shows the same notice", async () => {
  setComposerSettings({ dictationSource: "chatgpt" });
  const dictation = await mount(async () => undefined);
  await act(async () => deliverHandoffFailure({ code: "dictation.accessibility" }));
  expect(dictation.current!.notice?.message).toBe(handoffFailure("dictation.accessibility", "chatgpt", translate));
});
