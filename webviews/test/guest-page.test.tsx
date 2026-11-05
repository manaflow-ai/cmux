// l10n-allow-file: test fixtures.
// The guest page (agent-session/guest/GuestPage.tsx) against a fake room: Join waits for a valid
// name and retries with the same attempt, a share that is over ends the page, and the shared chat
// draws the owner's transcript read only, an ask showing who it waits on and no answer buttons.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
// jsdom has no layout. A tall viewport mounts every row of the small chat.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { GuestPage, endedBy } = await import("../src/agent-session/guest/GuestPage");
const { attemptId } = await import("../src/agent-session/guest/redeem");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { askingRecords, fakeRoom, joinFrames, memoryStorage, workingRecords } =
  await import("../src/agent-session/guest/fixtures/liveChat");
type Props = Parameters<typeof GuestPage>[0];
type RedeemRequest = Parameters<Props["redeem"]>[1];
type AcceptRequest = Parameters<NonNullable<Props["accept"]>>[1];

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const SHARE = "c2hhcmUtMTIzNDU2Nzg";
const doc = () => dom.window.document;
const text = () => doc().body.textContent ?? "";

async function mount(props: Partial<Props>) {
  const host = doc().createElement("div");
  doc().body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <GuestPage
        shareId={SHARE}
        secret="c2VjcmV0LWFiY2RlZmdo"
        redeem={() => new Promise(() => undefined)}
        attempt={() => "a".repeat(32)}
        socketUrl="wss://room.test/guest"
        storage={memoryStorage()}
        {...props}
      />,
    ),
  );
  return {
    host,
    unmount: () => act(async () => root.unmount()).then(() => host.remove()),
  };
}

async function typeName(host: HTMLElement, value: string) {
  const input = host.querySelector("input")!;
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(input, value);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}
/** Lets the fake room's frames (one microtask after the socket opens) land and draw. */
const roomFrames = () =>
  act(async () => {
    for (let tick = 0; tick < 8; tick += 1) await Promise.resolve();
  });
const joinButton = (host: HTMLElement) => host.querySelector("button[type=submit]") as HTMLButtonElement;
const submit = (host: HTMLElement) =>
  act(async () => {
    host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
  });

test("the join page shows nothing of the chat, and Join waits for a valid name", async () => {
  const page = await mount({});
  expect(page.host.textContent).toContain(translate("guest.join.title"));
  expect(page.host.textContent).toContain(translate("guest.join.detail"));
  expect(joinButton(page.host).disabled).toBe(true);
  await typeName(page.host, "   ");
  expect(joinButton(page.host).disabled).toBe(true);
  await typeName(page.host, "Ana\u200bLee");
  expect(joinButton(page.host).disabled).toBe(true);
  await typeName(page.host, "Ana");
  expect(joinButton(page.host).disabled).toBe(false);
  await page.unmount();
});

test("a link without its secret says so and keeps Join off", async () => {
  const page = await mount({ secret: undefined });
  expect(page.host.textContent).toContain(translate("guest.join.badLink"));
  expect(joinButton(page.host).disabled).toBe(true);
  await page.unmount();
});

test("the owner offline: the page says so, and Join again is the same attempt", async () => {
  const storage = new Map<string, string>();
  const tab = {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => void storage.set(key, value),
    removeItem: (key: string) => void storage.delete(key),
  } as unknown as Storage;
  const asked: RedeemRequest[] = [];
  const page = await mount({
    attempt: () => attemptId(SHARE, tab),
    redeem: async (_, request) => {
      asked.push(request);
      return { ok: false, error: "share.host_offline" };
    },
  });
  await typeName(page.host, "Ana");
  await submit(page.host);
  expect(page.host.querySelector("[role=alert]")?.textContent).toBe(translate("guest.join.hostOffline"));
  await submit(page.host);
  expect(asked.length).toBe(2);
  expect(asked[0]).toEqual({ attempt_id: asked[1]!.attempt_id, secret: "c2VjcmV0LWFiY2RlZmdo", name: "Ana" });
  await page.unmount();
});

for (const [error, shown] of [
  ["share.expired", "guest.ended.expired"],
  ["share.revoked", "guest.ended.revoked"],
  ["share.kicked", "guest.ended.kicked"],
  ["share.used", "guest.ended.used"],
] as const)
  test(`redeem answered ${error}: the ended page, with no way to retry`, async () => {
    const page = await mount({ redeem: async () => ({ ok: false, error }) });
    await typeName(page.host, "Ana");
    await submit(page.host);
    expect(page.host.textContent).toBe(translate(shown));
    expect(page.host.querySelector("button, input")).toBeNull();
    await page.unmount();
  });

test("joined, the owner's transcript draws read only; an ask shows who it waits on, with no answers", async () => {
  const page = await mount({ guestId: "g1", openSocket: fakeRoom(joinFrames(askingRecords())) });
  await roomFrames();
  expect(page.host.textContent).toContain("Fix the flaky upload retry test");
  expect(page.host.textContent).toContain(translate("guest.live.sharedBy", { owner: "Sam Rivera" }));
  expect(page.host.textContent).toContain("bun test src/upload.test.ts --rerun-each 5");
  expect(page.host.textContent).toContain(translate("guest.live.waitingAnswer", { owner: "Sam Rivera" }));
  // Who else is here: the owner, never this guest.
  expect(page.host.querySelector(".cv-presence__label")?.textContent).toBe(
    translate("multiplayer.viewing", { names: "Sam Rivera" }),
  );
  const labels = [...page.host.querySelectorAll("button")].map((button) => button.textContent ?? "");
  expect(labels.some((label) => /^(Allow|Reject)$/.test(label))).toBe(false);
  // The only field is the guest's own composer, never the owner's.
  expect(
    page.host.querySelector(".guest-live__transcript textarea, .guest-live__transcript [contenteditable='true']"),
  ).toBeNull();
  await page.unmount();
});

test("the room ends the share: the ended page replaces the chat", async () => {
  const frames = [...joinFrames(askingRecords()), { v: 1, t: "end", reason: "revoked" }];
  const page = await mount({ guestId: "g1", openSocket: fakeRoom(frames) });
  await roomFrames();
  expect(text()).toContain(translate("guest.ended.revoked"));
  expect(page.host.textContent).toBe(translate("guest.ended.revoked"));
  await page.unmount();
});

test("only a share that is over ends the page; offline and network failures may be retried", () => {
  expect(endedBy("share.expired")).toBe("expired");
  expect(endedBy("share.revoked")).toBe("revoked");
  expect(endedBy("share.closed")).toBe("closed");
  expect(endedBy("share.kicked")).toBe("kicked");
  expect(endedBy("share.used")).toBe("used");
  expect(endedBy("share.left")).toBe("used");
  expect(endedBy("share.host_offline")).toBeUndefined();
  expect(endedBy("failed")).toBeUndefined();
});

test("an invite joins as the signed-in account: no name field, and Join accepts this tab's attempt", async () => {
  const asked: AcceptRequest[] = [];
  const joined: unknown[] = [];
  const page = await mount({
    secret: undefined,
    invite: true,
    accept: async (_, request) => {
      asked.push(request);
      return { ok: true, guestId: "g1", role: "talk" };
    },
    onJoined: (...args) => void joined.push(args),
    openSocket: fakeRoom(joinFrames(askingRecords())),
  });
  expect(page.host.textContent).toContain(translate("guest.join.title"));
  expect(page.host.textContent).toContain(translate("guest.invite.detail"));
  expect(page.host.querySelector("input")).toBeNull();
  expect(joinButton(page.host).disabled).toBe(false);
  await submit(page.host);
  expect(asked).toEqual([{ attempt_id: "a".repeat(32) }]);
  expect(joined).toEqual([["g1", undefined, "talk", "invite"]]);
  await roomFrames();
  expect(page.host.textContent).toContain("Fix the flaky upload retry test");
  expect(page.host.querySelector(".guest-live__dock textarea")).not.toBeNull();
  await page.unmount();
});

for (const [error, shown] of [
  ["share.not_invited", "guest.invite.notInvited"],
  ["share.unverified", "guest.invite.unverified"],
  ["share.unauthorized", "guest.invite.signIn"],
  ["share.host_offline", "guest.join.hostOffline"],
] as const)
  test(`an invite accept answered ${error} says so, and Join stays to try again`, async () => {
    const page = await mount({ secret: undefined, invite: true, accept: async () => ({ ok: false, error }) });
    await submit(page.host);
    expect(page.host.querySelector("[role=alert]")?.textContent).toContain(translate(shown));
    expect(joinButton(page.host).disabled).toBe(false);
    if (error === "share.unauthorized")
      expect(page.host.querySelector("[role=alert] a")?.getAttribute("href")).toBe(`/i/${SHARE}`);
    await page.unmount();
  });

test("a view invitee watches: no composer, and the page says it can only watch", async () => {
  const page = await mount({ guestId: "g1", role: "view", openSocket: fakeRoom(joinFrames(workingRecords())) });
  await roomFrames();
  expect(page.host.textContent).toContain(translate("guest.live.viewOnly"));
  expect(page.host.querySelector("textarea, [contenteditable='true']")).toBeNull();
  await page.unmount();
});

// The role is known only after accept, so the invite's join text never promises a view invitee
// that the owner approves its messages (#33925).
test("the invite join text hedges message approval in every app locale", () => {
  expect(translate("guest.invite.detail", {}, "en")).toContain("If you can send messages");
  for (const lang of ["en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"] as const)
    expect(translate("guest.invite.detail", {}, lang)).not.toContain(translate("guest.join.detail", {}, lang));
});

// The owner's thread rail is pane chrome: on the guest page it drew a lone tick at the left edge (#33925).
for (const role of ["view", "talk"] as const)
  test(`the guest page draws no thread rail (${role})`, async () => {
    const page = await mount({ guestId: "g1", role, openSocket: fakeRoom(joinFrames(workingRecords())) });
    await roomFrames();
    expect(page.host.textContent).toContain("Fix the flaky upload retry test");
    expect(page.host.querySelector(".acpmux-minimap, .acpmux-minimap__tick")).toBeNull();
    await page.unmount();
  });

test("an invitee the owner removes (uninvite) ends on You were removed", async () => {
  const frames = [...joinFrames(askingRecords()), { v: 1, t: "kicked" }];
  const page = await mount({ guestId: "g1", role: "talk", openSocket: fakeRoom(frames) });
  await roomFrames();
  expect(page.host.textContent).toBe(translate("guest.ended.kicked"));
  const removed = await mount({
    secret: undefined,
    invite: true,
    accept: async () => ({ ok: false, error: "share.kicked" }),
  });
  await submit(removed.host);
  expect(removed.host.textContent).toBe(translate("guest.ended.kicked"));
  await removed.unmount();
  await page.unmount();
});
