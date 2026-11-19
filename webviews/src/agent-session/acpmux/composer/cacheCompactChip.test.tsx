// The composer's cache chip (CacheCompactChip.tsx, cacheCompactChipModel.ts): it shows only once
// acpmux will compact on return, the cache has expired, the chat is idle and there is text; a click
// flips Compact and Keep; the send carries the choice as `_meta.acpmux.cacheCompact` only while the
// chip shows. The client keeps acpmux's flag from the usage report and drops it after a compaction.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { settleReact } from "../../../../test/support/domTeardown";
import { translate } from "../i18n";
import type { AcpmuxSnapshot } from "../model";
import { CacheCompactChip, useCacheCompactChip, type CacheCompactChipControl } from "./CacheCompactChip";
import { cacheCompactChipShown, cacheCompactMeta, toggleCacheCompact } from "./cacheCompactChipModel";

const shownWith = (over: Partial<Parameters<typeof cacheCompactChipShown>[0]> = {}) =>
  cacheCompactChipShown({
    compactOnReturn: true,
    cacheExpiresAt: 1,
    expired: true,
    idle: true,
    hasText: true,
    ...over,
  });

test("the chip shows only when acpmux compacts on return, the cache expired, the chat is idle and has text", () => {
  expect(shownWith()).toBe(true);
  expect(shownWith({ compactOnReturn: undefined })).toBe(false);
  expect(shownWith({ compactOnReturn: false })).toBe(false);
  expect(shownWith({ cacheExpiresAt: undefined })).toBe(false);
  expect(shownWith({ expired: false })).toBe(false);
  expect(shownWith({ idle: false })).toBe(false);
  expect(shownWith({ hasText: false })).toBe(false);
});

test("a click flips Compact and Keep, and the send carries the choice only while the chip shows", () => {
  expect(toggleCacheCompact("compact")).toBe("keep");
  expect(toggleCacheCompact("keep")).toBe("compact");
  expect(cacheCompactMeta(true, "compact")).toBe("compact");
  expect(cacheCompactMeta(true, "keep")).toBe("keep");
  expect(cacheCompactMeta(false, "keep")).toBeUndefined();
});

// The hook and chip on a DOM.
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
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

type HarnessProps = Parameters<typeof useCacheCompactChip>[0];
let control: CacheCompactChipControl | undefined;
function Harness(props: HarnessProps) {
  const chipControl = useCacheCompactChip(props);
  // Kept for the test to read once React commits, outside render.
  useEffect(() => {
    control = chipControl;
  });
  return <CacheCompactChip control={chipControl} />;
}

async function render(props: HarnessProps) {
  if (!root) root = createRoot(installDom());
  await act(async () => root!.render(<Harness {...props} />));
}

const chip = () => document.querySelector<HTMLButtonElement>(".acpmux-cache-compact");
const tokens = (n: number) =>
  new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 0 }).format(n);

test("expired: Compact with the token count; a click flips it to Keep and back; a send resets it", async () => {
  const now = () => 2_000;
  const usage = { used: 312_400, compactOnReturn: true, cacheExpiresAt: 1_000 };
  await render({ usage, idle: true, hasText: true, now });
  expect(chip()!.textContent).toBe(translate("composer.cacheCompact", { tokens: tokens(312_400) }));
  expect(chip()!.title).toBe(translate("composer.cacheCompactTooltip"));
  expect(control!.meta).toBe("compact");
  await act(async () => chip()!.click());
  expect(chip()!.textContent).toBe(translate("composer.cacheKeep"));
  expect(chip()!.title).toBe(translate("composer.cacheKeepTooltip"));
  expect(control!.meta).toBe("keep");
  await act(async () => chip()!.click());
  expect(control!.meta).toBe("compact");
  await act(async () => chip()!.click());
  await act(async () => control!.sent());
  expect(control!.meta).toBe("compact");
});

test("hidden while warm, mid-turn, with nothing typed, or without acpmux's flag; no meta then", async () => {
  const now = () => 2_000;
  for (const props of [
    { usage: { used: 312_400, compactOnReturn: true, cacheExpiresAt: 60_000 }, idle: true, hasText: true },
    { usage: { used: 312_400, compactOnReturn: true, cacheExpiresAt: 1_000 }, idle: false, hasText: true },
    { usage: { used: 312_400, compactOnReturn: true, cacheExpiresAt: 1_000 }, idle: true, hasText: false },
    { usage: { used: 312_400, cacheExpiresAt: 1_000 }, idle: true, hasText: true },
    { usage: undefined, idle: true, hasText: true },
  ]) {
    await render({ ...props, now });
    expect(chip()).toBeNull();
    expect(control!.meta).toBeUndefined();
  }
});

test("the chip appears when the cache lapses, with no new usage report", async () => {
  let clock = 1_000;
  const now = () => clock;
  // The hook's once-a-second tick, run by the test instead of the wall clock.
  const ticks: (() => void)[] = [];
  root = createRoot(installDom());
  dom!.window.setInterval = ((tick: () => void) => ticks.push(tick)) as unknown as typeof setInterval;
  dom!.window.clearInterval = (() => {}) as typeof clearInterval;
  await render({
    usage: { used: 312_400, compactOnReturn: true, cacheExpiresAt: 1_500 },
    idle: true,
    hasText: true,
    now,
  });
  expect(chip()).toBeNull();
  expect(ticks.length).toBeGreaterThan(0);
  clock = 2_000;
  await act(async () => ticks.forEach((tick) => tick()));
  expect(chip()).not.toBeNull();
});

// The client: the flag from usage_update, its drop on a finished compaction, and the send's meta.
async function connect() {
  installDom();
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const sent: any[] = [];
  let emit: ((target: string, step: any) => void) | undefined;
  class Host extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as {
        answer: (method: string, params: any) => Promise<unknown>;
        emit: (target: string, step: any) => void;
      };
      emit = hooks.emit.bind(this);
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method === "session/prompt") {
          sent.push(params);
          return { stopReason: "end_turn" };
        }
        return answer(method, params);
      };
    }
  }
  let snapshot: AcpmuxSnapshot | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      snapshot = next;
    },
    undefined,
    () => new Host() as unknown as WebSocket,
  );
  return { client, sent, emit: (target: string, step: any) => emit!(target, step), snapshot: () => snapshot };
}

const until = async (done: () => boolean) => {
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

test("the client keeps acpmux's cache fields and drops compactOnReturn after a compaction", async () => {
  const io = await connect();
  try {
    await io.client.send("hello");
    const sessionId = io.sent[0].sessionId;
    io.emit(sessionId, {
      update: {
        sessionUpdate: "usage_update",
        used: 312_400,
        size: 1_000_000,
        _meta: {
          acpmux: {
            cacheExpiresAt: 5_000,
            compactOnReturn: true,
            cacheHit: 0.25,
            cacheMiss: { cause: "expired", at: 4_000 },
          },
        },
      },
    });
    await until(() => io.snapshot()?.summary?.usage?.compactOnReturn === true);
    expect(io.snapshot()!.summary!.usage).toMatchObject({
      used: 312_400,
      cacheExpiresAt: 5_000,
      cacheHit: 0.25,
      cacheMiss: { cause: "expired", at: 4_000 },
    });
    io.emit(sessionId, { update: { sessionUpdate: "compaction", state: "completed" } });
    await until(() => io.snapshot()?.summary?.usage?.compactOnReturn === undefined);
    expect(io.snapshot()!.summary!.usage!.cacheExpiresAt).toBeUndefined();
    expect(io.snapshot()!.summary!.usage!.cacheHit).toBe(0.25);
  } finally {
    io.client.close();
  }
});

test("a send carries the chip's choice once, and nothing without it", async () => {
  const io = await connect();
  try {
    io.client.chooseCacheCompact("keep");
    await io.client.send("cold");
    expect(io.sent[0]._meta.acpmux.cacheCompact).toBe("keep");
    await io.client.send("next");
    expect("cacheCompact" in io.sent[1]._meta.acpmux).toBe(false);
    io.client.chooseCacheCompact("compact");
    await io.client.send("compact first");
    expect(io.sent[2]._meta.acpmux.cacheCompact).toBe("compact");
    io.client.chooseCacheCompact(undefined);
    await io.client.send("plain");
    expect("cacheCompact" in io.sent[3]._meta.acpmux).toBe(false);
  } finally {
    io.client.close();
  }
});
