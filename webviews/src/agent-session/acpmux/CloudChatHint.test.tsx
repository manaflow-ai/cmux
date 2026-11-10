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
import { installPageKey, pageIsKey, watchPageKey } from "./pageKey";
import {
  CLOUD_CHAT_HINT_ID,
  cloudChatHintDue,
  cloudChatHintRecord,
  cloudChatHintAfterRead,
  cloudChatHintShown,
  useCloudChatHint,
  useCloudChatHintClaim,
  type CloudChatHintState,
} from "./cloudChatHintModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
let pageCleanup: (() => void) | undefined;
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
  pageCleanup?.();
  pageCleanup = undefined;
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

test("within 14 days of another tip the app refuses it, and this page shows none", async () => {
  const host = memoryTipHost();
  host.lastShownAt = host.now() - 86_400_000;
  const hint = await mountHint(host);
  await act(async () => hint.current().claim());
  await act(async () => undefined);
  expect(hint.current().record).toBe("done");
  expect(host.records[CLOUD_CHAT_HINT_ID]).toBeUndefined();
});

// CMD-T BUDGET 3 (2026-11-10): a New Tab page changes hands. It loads as a spare nobody sees, Cmd-T
// gives it to a tab, Cmd-W gives it back to the pool for the next Cmd-T. Each spare asked for the
// hint by itself while nobody saw it; the app counted the ask as a touch and the pool refused every
// closed page of a default profile ("touched by featureTips", 5 of 5 Cmd-W).
async function mountPage(host: TipHost, parked: boolean) {
  const container = installDom();
  const doc = dom!.window.document;
  const view = dom!.window;
  // The page's own key state (pageKey.ts), as the app installs it. A parked spare has no keyboard.
  const uninstall = installPageKey(doc);
  pageCleanup = uninstall;
  view.dispatchEvent(new view.Event(parked ? "blur" : "focus"));
  const pageKey = { key: () => pageIsKey(doc), watch: (run: () => void) => watchPageKey(run, doc) };
  /// Each render of the page, `<adoptions>:<record>`.
  const renders: string[] = [];
  function Page({ adoptions }: { adoptions: number }) {
    const state = useCloudChatHint(host, adoptions);
    useCloudChatHintClaim(state.record === "open", state.claim, pageKey);
    renders.push(`${adoptions}:${state.record}`);
    return null;
  }
  root = createRoot(container);
  const adopt = async (adoptions: number) => {
    await act(async () => root!.render(<Page adoptions={adoptions} />));
    await act(async () => undefined);
  };
  await adopt(0);
  return {
    renders,
    record: () => renders.at(-1)!.split(":")[1],
    /// The page changes hands: the pool or a tab gives it a context (an adopt event).
    adopt,
    /// The page's web view takes or loses the keyboard.
    setKey: async (key: boolean) => {
      await act(async () => {
        view.dispatchEvent(new view.Event(key ? "focus" : "blur"));
      });
      await act(async () => undefined);
    },
  };
}

function countingHost() {
  const host = memoryTipHost();
  const calls = { read: 0, claim: 0, write: 0 };
  const counted: TipHost = {
    read: () => (calls.read++, host.read()),
    claim: (id, feature) => (calls.claim++, host.claim(id, feature)),
    write: (id, record) => (calls.write++, host.write(id, record)),
  };
  return { host, counted, calls };
}

test("a spare page nobody sees asks for nothing; the tab that takes it asks once it has the keyboard", async () => {
  const { host, counted, calls } = countingHost();
  const page = await mountPage(counted, true);
  // Parked in the pool: the hint is due, and the page sends no claim.
  expect(page.record()).toBe("open");
  expect(calls.claim).toBe(0);
  // The pool prepares it and Cmd-T adopts it (two adoptions), still before the page has the keyboard.
  await page.adopt(1);
  await page.adopt(2);
  expect(calls.claim).toBe(0);
  expect(host.records[CLOUD_CHAT_HINT_ID]).toBeUndefined();
  // The person is at it: one claim, and the hint shows.
  await page.setKey(true);
  expect(calls.claim).toBe(1);
  expect(page.record()).toBe("shown");
  expect(host.records[CLOUD_CHAT_HINT_ID]).toBe("shown");
  // A switch away and back asks nothing more.
  await page.setKey(false);
  await page.setKey(true);
  expect(calls.claim).toBe(1);
  expect(calls.read).toBe(3);
});

for (const pairs of [1, 3, 12]) {
  test(`a page that goes back to the pool shows its hint to no later tab and asks for none (${pairs} Cmd-W + Cmd-T pairs)`, async () => {
    const { host, counted, calls } = countingHost();
    const page = await mountPage(counted, false);
    expect(page.record()).toBe("shown");
    // Cmd-W: the pool gives the page the spare context (an adoption). Cmd-T: the next tab's context.
    for (let adoption = 1; adoption <= pairs * 2; adoption += 1) await page.adopt(adoption);
    const shownAgain = page.renders.filter((render) => !render.startsWith("0:") && render.endsWith(":shown"));
    expect(shownAgain).toEqual([]);
    expect(page.record()).toBe("done");
    expect(calls.claim).toBe(1);
    expect(calls.write).toBe(0);
    // One read at load, one at the first adoption after the hint showed; the record is done then: no more.
    expect(calls.read).toBe(2);
    expect(host.records[CLOUD_CHAT_HINT_ID]).toBe("shown");
  });
}

test("the next tab's first render has no hint of the tab before it, before the app answers", async () => {
  const host = memoryTipHost();
  // The app answers the first read; each later read waits until the test lets it go.
  const waiting: (() => void)[] = [];
  let reads = 0;
  const slow: TipHost = {
    ...host,
    read: () =>
      reads++ === 0 ? host.read() : new Promise((resolve) => waiting.push(() => void host.read().then(resolve))),
  };
  const page = await mountPage(slow, false);
  expect(page.record()).toBe("shown");
  await page.adopt(1);
  expect(waiting.length).toBe(1);
  expect(page.renders.filter((render) => render.startsWith("1:"))).toEqual(["1:done"]);
  await act(async () => waiting.forEach((answer) => answer()));
  await act(async () => undefined);
  expect(page.record()).toBe("done");
  expect(page.renders).not.toContain("1:shown");
});

test("a yes that comes after the tab's adoption is that tab's hint; after the page went back, no tab's", async () => {
  const host = memoryTipHost();
  // The app's answer to the claim waits until the test lets it go.
  let answer: (() => void) | undefined;
  const slow: TipHost = {
    ...host,
    claim: (id, feature) => new Promise((resolve) => (answer = () => void host.claim(id, feature).then(resolve))),
  };
  // The page takes the keyboard and asks while Cmd-T's adoption is still on its way.
  const page = await mountPage(slow, false);
  expect(page.record()).toBe("open");
  await page.adopt(1);
  await act(async () => answer!());
  await act(async () => undefined);
  expect(page.record()).toBe("shown");
  // Cmd-W gives the page back to the pool, then Cmd-T: the next tab has no hint.
  await page.adopt(2);
  await page.adopt(3);
  expect(page.renders.filter((render) => /^[23]:shown$/.test(render))).toEqual([]);
  expect(page.record()).toBe("done");
});

test("a read that answers after the claim does not take the granted hint away", () => {
  expect(cloudChatHintAfterRead("shown", "open")).toBe("shown");
  expect(cloudChatHintAfterRead("shown", "done")).toBe("done");
  expect(cloudChatHintAfterRead("unknown", "open")).toBe("open");
  expect(cloudChatHintAfterRead("open", "done")).toBe("done");
  expect(cloudChatHintAfterRead("done", "open")).toBe("done");
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
