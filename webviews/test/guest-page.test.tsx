// l10n-allow-file: test fixtures.
// The guest page (agent-session/guest/GuestPage.tsx) against a fake room: Join waits for a valid
// name and retries with the same attempt, a share that is over ends the page, and the shared chat
// draws the owner's transcript read only, an ask showing who it waits on and no answer buttons.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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
const { GuestPage, loadGuestTranscript, endedBy } = await import("../src/agent-session/guest/GuestPage");
// The transcript is its own chunk (GuestTranscript.tsx); load it once so the room's frames draw at once.
await loadGuestTranscript();
const { attemptId } = await import("../src/agent-session/guest/redeem");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { askingRecords, fakeRoom, joinFrames, memoryStorage, workingRecords } =
  await import("../src/agent-session/guest/fixtures/liveChat");
type Props = Parameters<typeof GuestPage>[0];
type RedeemRequest = Parameters<Props["redeem"]>[1];
type AcceptRequest = Parameters<NonNullable<Props["accept"]>>[1];

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
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
  // A link guest watches only: the page never promises it may send (sending takes an invite).
  expect(page.host.textContent).toContain(translate("guest.live.viewOnly"));
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
  // The owner's `bun test src/upload.test.ts --rerun-each 5` failed, so its row keeps the command
  // line: a failed call never reads as what it would have done (commandActions.ts).
  expect(page.host.textContent).toContain("Ran bun test src/upload.test.ts --rerun-each 5");
  expect(page.host.textContent).not.toContain("Ran tests in upload.test.ts");
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

test("a link guest watches unless the redeem names talk (a signed-in account on a talk link)", async () => {
  for (const answered of [undefined, "view", "talk"] as const) {
    const joined: unknown[] = [];
    const page = await mount({
      redeem: async () => ({ ok: true, guestId: "g1", ...(answered ? { role: answered } : {}) }),
      onJoined: (...args) => void joined.push(args),
      openSocket: fakeRoom(joinFrames(workingRecords())),
    });
    await typeName(page.host, "Ana");
    await submit(page.host);
    await roomFrames();
    const role = answered ?? "view";
    expect(joined).toEqual([["g1", "Ana", role, "link"]]);
    expect(page.host.textContent?.includes(translate("guest.live.viewOnly"))).toBe(role === "view");
    expect(page.host.querySelector("textarea, [contenteditable='true']") === null).toBe(role === "view");
    await page.unmount();
  }
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
    expect(translate("guest.invite.detail", {}, lang)).not.toBe(translate("guest.live.viewOnly", {}, lang));
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

// The transcript is its own chunk (GuestTranscript.tsx). A load that fails (a dropped connection)
// says so with Retry, keeps the composer where it is, and the snapshot that came meanwhile draws
// once Retry loads it.
test("a transcript chunk that fails to load says so; Retry loads it and the chat draws", async () => {
  let fail = true;
  let asked = 0;
  const loadTranscript = () => {
    asked += 1;
    return fail ? Promise.reject(new Error("offline")) : loadGuestTranscript();
  };
  const page = await mount({
    guestId: "g1",
    role: "talk",
    openSocket: fakeRoom(joinFrames(workingRecords())),
    loadTranscript,
  });
  await roomFrames();
  const alert = page.host.querySelector(".guest-live__transcript [role=alert]");
  expect(alert?.textContent).toContain(translate("guest.live.loadFailed"));
  expect(page.host.textContent).not.toContain("bun test src/upload.test.ts --rerun-each 5");
  expect(page.host.querySelector(".guest-live__dock textarea")).not.toBeNull();
  fail = false;
  await act(async () => {
    alert!.querySelector("button")!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  await roomFrames();
  expect(asked).toBe(2);
  expect(page.host.querySelector(".guest-live__transcript [role=alert]")).toBeNull();
  expect(page.host.textContent).toContain("bun test src/upload.test.ts --rerun-each 5");
  await page.unmount();
});

// The browser may keep a failed module fetch for the page's life (#38101 F1): a Retry whose load
// fails too reloads the page instead of asking the same failed import again.
test("a Retry whose load fails too reloads the page", async () => {
  let reloads = 0;
  const page = await mount({
    guestId: "g1",
    role: "talk",
    openSocket: fakeRoom(joinFrames(workingRecords())),
    loadTranscript: () => Promise.reject(new Error("offline")),
    reloadPage: () => void (reloads += 1),
  });
  await roomFrames();
  const alert = page.host.querySelector(".guest-live__transcript [role=alert]");
  expect(alert?.textContent).toContain(translate("guest.live.loadFailed"));
  expect(reloads).toBe(0);
  await act(async () => {
    alert!.querySelector("button")!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  await roomFrames();
  expect(reloads).toBe(1);
  await page.unmount();
});

const signedIn = (avatarUrl?: string) => async () =>
  ({ signedIn: true, name: "Priya Raman", ...(avatarUrl ? { avatarUrl } : {}) }) as const;

test("a link opened signed in: Join as the account with its picture, no name field, and a body with no account", async () => {
  const requests: RedeemRequest[] = [];
  const asked: string[] = [];
  const page = await mount({
    whoami: async (share) => {
      asked.push(share);
      return signedIn("https://avatars.example.com/priya.png")();
    },
    redeem: async (_share, request) => {
      requests.push(request);
      return { ok: true, guestId: "g1", role: "talk" };
    },
    openSocket: fakeRoom(joinFrames(workingRecords())),
  });
  await roomFrames();
  expect(asked).toEqual([SHARE]);
  expect(page.host.querySelector("input")).toBeNull();
  expect(joinButton(page.host).textContent).toBe(translate("guest.join.as", { name: "Priya Raman" }));
  expect(joinButton(page.host).querySelector("img")?.getAttribute("src")).toBe("https://avatars.example.com/priya.png");
  expect(page.host.textContent).toContain(translate("guest.join.editName"));
  await submit(page.host);
  await roomFrames();
  // The page sends only the attempt, the secret and the shown name: the room adds the account.
  expect(requests).toEqual([{ attempt_id: "a".repeat(32), secret: "c2VjcmV0LWFiY2RlZmdo", name: "Priya Raman" }]);
  // A talk redeem shows the composer.
  expect(page.host.querySelector("textarea, [contenteditable='true']")).not.toBeNull();
  await page.unmount();
});

test("Edit name opens the field filled with the account's name, and Join joins with the edit", async () => {
  const requests: RedeemRequest[] = [];
  const page = await mount({
    whoami: signedIn(),
    redeem: async (_share, request) => {
      requests.push(request);
      return new Promise(() => undefined);
    },
  });
  await roomFrames();
  // No picture: the initials.
  expect(joinButton(page.host).querySelector("img")).toBeNull();
  expect(joinButton(page.host).textContent).toContain("P");
  const edit = [...page.host.querySelectorAll("button")].find(
    (button) => button.textContent === translate("guest.join.editName"),
  )!;
  await act(async () => edit.click());
  expect(page.host.querySelector("input")?.value).toBe("Priya Raman");
  await typeName(page.host, "Priya R.");
  await submit(page.host);
  expect(requests.map((request) => request.name)).toEqual(["Priya R."]);
  await page.unmount();
});

test("anonymous, an older room without whoami, or a failure: the name prompt as before", async () => {
  const answers: (() => Promise<{ signedIn: false }>)[] = [
    async () => ({ signedIn: false }),
    () => Promise.reject(new Error("offline")),
  ];
  for (const whoami of answers) {
    const page = await mount({ whoami });
    await roomFrames();
    expect(page.host.querySelector("input")).not.toBeNull();
    expect(page.host.textContent).toContain(translate("guest.live.viewOnly"));
    expect(page.host.querySelector("[data-testid=guest-join-as]")).toBeNull();
    await page.unmount();
  }
});

test("an invite or a tab that already joined never asks whoami", async () => {
  const asked: string[] = [];
  const whoami = async (share: string) => {
    asked.push(share);
    return { signedIn: false } as const;
  };
  const invite = await mount({ whoami, secret: undefined, invite: true, accept: () => new Promise(() => undefined) });
  const joined = await mount({ whoami, guestId: "g1", openSocket: fakeRoom(joinFrames(workingRecords())) });
  await roomFrames();
  expect(asked).toEqual([]);
  await invite.unmount();
  await joined.unmount();
});

test("another guest's message draws as a prompt under their picture and name", async () => {
  const records = workingRecords();
  const first = records[0]!;
  records[0] = {
    ...first,
    msg: {
      ...(first.msg as Record<string, unknown>),
      _meta: {
        provenance: {
          kind: "person_message",
          from: "guest:share.g2",
          fromName: "Priya Raman",
          fromAvatar: "https://avatars.example.com/priya.png",
        },
      },
    },
  };
  const page = await mount({ guestId: "g1", role: "talk", openSocket: fakeRoom(joinFrames(records)) });
  await roomFrames();
  const author = page.host.querySelector(".cv-author");
  expect(author?.textContent).toBe(translate("multiplayer.guestName", { name: "Priya Raman" }));
  expect(author?.querySelector("img")?.getAttribute("src")).toBe("https://avatars.example.com/priya.png");
  await page.unmount();
});

// The owner's own `acpmux send` at a plain terminal (acpmux `owner_terminal`, #38260) is recorded as
// their prompt: `_meta.origin` person with a CLI client. The shared chat draws it as the owner's
// prompt, never as a received card from the label its text starts with (#38260 F2).
test("the owner's terminal send of `[P1] fix the race` draws as the owner's prompt, not a card from P1", async () => {
  const records = workingRecords();
  const first = records[0]!;
  records[0] = {
    ...first,
    msg: {
      ...(first.msg as Record<string, unknown>),
      text: "[P1] fix the race",
      client: "acpmux-cli#01a2f3@my-mac",
      _meta: { origin: { actor: "person", verified: true } },
    },
  };
  const page = await mount({ guestId: "g1", openSocket: fakeRoom(joinFrames(records)) });
  await roomFrames();
  expect(page.host.textContent).toContain("[P1] fix the race");
  expect(page.host.querySelector(".cv-received__sender")).toBeNull();
  await page.unmount();
});

test("a signed-in link join keeps the daemon's talk: the composer shows, and again after a reload", async () => {
  const { joinedRole, rememberJoined } = await import("../src/agent-session/guest/redeem");
  const tab = memoryStorage();
  const page = await mount({
    storage: tab,
    whoami: signedIn(),
    redeem: async () => ({ ok: true, guestId: "g1", role: "talk" }),
    onJoined: (guestId, name, role, via) => rememberJoined(SHARE, guestId, tab, name, role, via),
    openSocket: fakeRoom(joinFrames(workingRecords())),
  });
  await roomFrames();
  await submit(page.host);
  await roomFrames();
  expect(page.host.querySelector("textarea, [contenteditable='true']")).not.toBeNull();
  await page.unmount();
  // A reload reads the kept role.
  expect(joinedRole(SHARE, tab)).toBe("talk");
  const reloaded = await mount({
    storage: tab,
    guestId: "g1",
    role: joinedRole(SHARE, tab),
    openSocket: fakeRoom(joinFrames(workingRecords())),
  });
  await roomFrames();
  expect(reloaded.host.querySelector("textarea, [contenteditable='true']")).not.toBeNull();
  await reloaded.unmount();
});

test("a joined page with no role watches: no composer", async () => {
  const page = await mount({ guestId: "g1", openSocket: fakeRoom(joinFrames(workingRecords())) });
  await roomFrames();
  expect(page.host.querySelector("textarea, [contenteditable='true']")).toBeNull();
  expect(page.host.textContent).toContain(translate("guest.live.viewOnly"));
  await page.unmount();
});
