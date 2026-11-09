// The one-time Cloud hint over a new chat's composer (CloudChatHint.tsx, cloudChatHintModel.ts). Leo,
// 2026-11-08, on teammates starting a Cloud chat: "how would they know?". It shows only while its
// record in the app is open, tips are on and Cloud is offered to a new chat that has not picked it;
// Use Cloud is the Where menu's own pick, and the X or any Cloud pick closes it for the install.
// Leo, 2026-11-06, on tips and guides: far too many, far too often. It shows at most once per
// install (the app's claim) and spends the tips' one 14-day budget.
import { afterEach, expect, test } from "bun:test";
import { act, useEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { memoryTipHost, type TipHost } from "../../ui/featureTips/store";
import { CloudChatHint } from "./CloudChatHint";
import {
  CLOUD_CHAT_HINT_ID,
  cloudChatHintDue,
  cloudChatHintRecord,
  cloudChatHintShown,
  useCloudChatHint,
  type CloudChatHintState,
} from "./cloudChatHintModel";

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
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const shownFacts = { record: "shown", tipsOn: true, cloudOffered: true, cloudPicked: false, started: false } as const;

test("the hint shows only on a new chat that has not picked Cloud, once the app granted it and tips are on", () => {
  expect(cloudChatHintShown(shownFacts)).toBe(true);
  expect(cloudChatHintShown({ ...shownFacts, record: "unknown" })).toBe(false);
  expect(cloudChatHintShown({ ...shownFacts, record: "open" })).toBe(false);
  expect(cloudChatHintShown({ ...shownFacts, record: "done" })).toBe(false);
  // Due: the page asks the app for it only while its record is open and the same facts hold.
  expect(cloudChatHintDue({ ...shownFacts, record: "open" })).toBe(true);
  expect(cloudChatHintDue(shownFacts)).toBe(false);
  expect(cloudChatHintDue({ ...shownFacts, record: "open", started: true })).toBe(false);
  expect(cloudChatHintDue({ ...shownFacts, record: "open", tipsOn: false })).toBe(false);
  expect(cloudChatHintShown({ ...shownFacts, tipsOn: false })).toBe(false);
  expect(cloudChatHintShown({ ...shownFacts, cloudOffered: false })).toBe(false);
  expect(cloudChatHintShown({ ...shownFacts, cloudPicked: true })).toBe(false);
  expect(cloudChatHintShown({ ...shownFacts, started: true })).toBe(false);
});

test("any record of the hint closes it for good, and an app that keeps no records shows none", () => {
  expect(cloudChatHintRecord({})).toBe("open");
  expect(cloudChatHintRecord({ "agents-drive-visible-browser-tabs": "shown" })).toBe("open");
  expect(cloudChatHintRecord({ [CLOUD_CHAT_HINT_ID]: "closed" })).toBe("done");
  expect(cloudChatHintRecord({ [CLOUD_CHAT_HINT_ID]: "used" })).toBe("done");
  expect(cloudChatHintRecord(undefined)).toBe("done");
});

async function mountHint(
  host: TipHost,
): Promise<{ current: () => CloudChatHintState; newChat: (generation: number) => Promise<void> }> {
  const container = installDom();
  let latest: CloudChatHintState | undefined;
  function Probe({ generation }: { generation: number }) {
    const state = useCloudChatHint(host, generation);
    useEffect(() => {
      latest = state;
    });
    return null;
  }
  root = createRoot(container);
  await act(async () => root!.render(<Probe generation={0} />));
  await act(async () => undefined);
  return {
    current: () => latest!,
    newChat: async (generation) => {
      await act(async () => root!.render(<Probe generation={generation} />));
      await act(async () => undefined);
    },
  };
}

test("the X keeps `closed` in the app's records once, and the hint is done at once", async () => {
  const host = memoryTipHost();
  let writes = 0;
  const counted: TipHost = { ...host, write: (id, record) => (writes++, host.write(id, record)) };
  const hint = await mountHint(counted);
  expect(hint.current().record).toBe("open");
  await act(async () => hint.current().close());
  expect(hint.current().record).toBe("done");
  expect(host.records[CLOUD_CHAT_HINT_ID]).toBe("closed");
  await act(async () => hint.current().used());
  expect(writes).toBe(1);
  expect(host.records[CLOUD_CHAT_HINT_ID]).toBe("closed");
});

test("a Cloud pick keeps `used`; an install that already answered never sees the hint", async () => {
  const fresh = memoryTipHost();
  const hint = await mountHint(fresh);
  await act(async () => hint.current().used());
  expect(fresh.records[CLOUD_CHAT_HINT_ID]).toBe("used");
  if (root) await act(async () => root!.unmount());
  root = undefined;
  const answered = await mountHint(memoryTipHost({ [CLOUD_CHAT_HINT_ID]: "closed" }));
  expect(answered.current().record).toBe("done");
});

test("another pane's answer reaches this one's next new chat", async () => {
  const shared = memoryTipHost();
  const hint = await mountHint(shared);
  expect(hint.current().record).toBe("open");
  await shared.write(CLOUD_CHAT_HINT_ID, "closed");
  await hint.newChat(1);
  expect(hint.current().record).toBe("done");
});

test("it shows once: the app's claim records it, and the next new chat has none without an X", async () => {
  const host = memoryTipHost();
  const hint = await mountHint(host);
  expect(hint.current().record).toBe("open");
  await act(async () => hint.current().claim());
  await act(async () => undefined);
  expect(hint.current().record).toBe("shown");
  expect(host.records[CLOUD_CHAT_HINT_ID]).toBe("shown");
  expect(host.lastShownAt).not.toBeNull();
  await hint.newChat(1);
  expect(hint.current().record).toBe("done");
});

test("within 14 days of another tip the app refuses it, and it never shows", async () => {
  const host = memoryTipHost();
  host.lastShownAt = host.now() - 86_400_000;
  const hint = await mountHint(host);
  await act(async () => hint.current().claim());
  await act(async () => undefined);
  expect(hint.current().record).toBe("done");
  expect(host.records[CLOUD_CHAT_HINT_ID]).toBeUndefined();
});

test("an older app that refuses `tips.state` shows no hint", async () => {
  const refusing: TipHost = {
    read: () => Promise.reject(new Error("unsupported")),
    write: () => Promise.reject(new Error("unsupported")),
    claim: async () => false,
  };
  const hint = await mountHint(refusing);
  expect(hint.current().record).toBe("done");
});

test("Use Cloud and the X answer once each; the X has an accessible name", async () => {
  const container = installDom();
  // Motion off: the answer comes at once, with no fold to wait for.
  dom!.window.document.documentElement.dataset.cmuxMotion = "off";
  let used = 0;
  let closed = 0;
  root = createRoot(container);
  await act(async () => root!.render(<CloudChatHint onUse={() => used++} onClose={() => closed++} />));
  expect(container.textContent).toContain("Cloud chats keep working while your Mac sleeps.");
  const use = container.querySelector<HTMLButtonElement>('[data-testid="cloud-hint-use"]')!;
  expect(use.textContent).toBe("Use Cloud");
  await act(async () => use.click());
  expect(used).toBe(1);
  const close = container.querySelector<HTMLButtonElement>('[data-testid="cloud-hint-close"]')!;
  expect(close.getAttribute("aria-label")).toBe("Don’t show again");
  await act(async () => close.click());
  expect(closed).toBe(1);
});

test("the hint is borderless and moves on the house settle", () => {
  const css = readFileSync(new URL("./cloudChatHint.css", import.meta.url), "utf8");
  expect(css).not.toMatch(/\bborder\s*:\s*(?!0\b)[^;]*solid/);
  expect(css).toContain("var(--cmux-motion-settle, 180ms) var(--cmux-ease-settle, cubic-bezier(0.16, 1, 0.3, 1))");
});
