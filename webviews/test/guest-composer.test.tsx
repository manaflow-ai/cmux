// l10n-allow-file: test fixtures.
// The guest's composer (agent-session/guest/GuestComposer.tsx) against a fake room: a message goes
// as `prompt {client_id, text}`, shows the guest's chip and "Waiting for <owner>", then one quiet
// line from `prompt_state`; a message the room never acknowledged goes again, same client id, after
// a reconnect; typing is said once; a message over 32 KiB cannot be sent.
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
const { GuestPage } = await import("../src/agent-session/guest/GuestPage");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { joinFrames, memoryStorage, workingRecords } = await import("../src/agent-session/guest/fixtures/liveChat");
const { PROMPT_MAX_BYTES } = await import("../src/agent-session/guest/guestPrompts");
type Socket = import("../src/agent-session/guest/shareSocket").ShareSocketLike;

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const SHARE = "c2hhcmUtMTIzNDU2Nzg";

/** A room whose sockets the test drives: each records what the page sends. */
function room() {
  const sockets: (Socket & { sent: Record<string, unknown>[] })[] = [];
  // Waits on what the page does (a socket opened, a frame sent), never on a fixed time.
  const waiters = new Set<() => void>();
  const changed = () => {
    for (const waiter of waiters) waiter();
  };
  const until = (holds: () => boolean) =>
    act(
      () =>
        new Promise<void>((resolve) => {
          const check = () => {
            if (!holds()) return;
            waiters.delete(check);
            resolve();
          };
          waiters.add(check);
          check();
        }),
    );
  const open = () => {
    const socket = {
      sent: [] as Record<string, unknown>[],
      send(data: string) {
        socket.sent.push(JSON.parse(data));
        changed();
      },
      close() {},
      onopen: null,
      onmessage: null as Socket["onmessage"],
      onclose: null as Socket["onclose"],
    };
    sockets.push(socket);
    queueMicrotask(changed);
    return socket;
  };
  const last = () => sockets.at(-1)!;
  const frame = (value: object) =>
    act(async () => {
      last().onmessage?.({ data: JSON.stringify(value) });
    });
  const join = async (prompts: object[] = []) => {
    for (const each of joinFrames(workingRecords(), undefined, prompts as never)) await frame(each);
  };
  return { sockets, open, last, frame, join, until, prompts: () => last().sent.filter((each) => each.t === "prompt") };
}

async function mount(fake: ReturnType<typeof room>, storage = memoryStorage()) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <GuestPage
        shareId={SHARE}
        guestId="g1"
        name="Ana"
        storage={storage}
        redeem={() => new Promise(() => undefined)}
        attempt={() => "a".repeat(32)}
        socketUrl="wss://room.test/guest"
        openSocket={fake.open}
      />,
    ),
  );
  return { host, unmount: () => act(async () => root.unmount()).then(() => host.remove()) };
}

async function type(host: HTMLElement, value: string) {
  const field = host.querySelector("textarea")!;
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(field, value);
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
}
const enter = (host: HTMLElement) =>
  act(async () => {
    host
      .querySelector("textarea")!
      .dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
const mine = (host: HTMLElement) => host.querySelector(".guest-mine")?.textContent ?? "";

test("a message goes as prompt {client_id, text}, waits for the owner, then reads as decided", async () => {
  const fake = room();
  const page = await mount(fake);
  await fake.join();
  await type(page.host, "Use a fake clock");
  expect(fake.last().sent.filter((each) => each.t === "typing")).toEqual([{ v: 1, t: "typing", on: true }]);
  await enter(page.host);
  const [sent] = fake.prompts();
  expect(sent).toMatchObject({ v: 1, t: "prompt", text: "Use a fake clock" });
  expect(String(sent!.client_id)).toMatch(/^[0-9a-f]{32}$/);
  // Off on send, after the half second that keeps typing frames to two a second.
  await fake.until(() => fake.last().sent.some((each) => each.t === "typing" && each.on === false));
  expect(page.host.querySelector("textarea")!.value).toBe("");
  expect(mine(page.host)).toContain("Ana");
  expect(mine(page.host)).toContain(translate("guest.prompt.sending"));
  await fake.frame({
    v: 1,
    t: "prompt_state",
    guest_id: "g1",
    client_id: sent!.client_id,
    prompt_id: "g-x",
    state: "held",
  });
  expect(mine(page.host)).toContain(translate("guest.prompt.waiting", { owner: "Sam Rivera" }));
  await fake.frame({ v: 1, t: "prompt_state", guest_id: "g1", client_id: sent!.client_id, state: "approved" });
  expect(mine(page.host)).toBe(translate("guest.prompt.sent", { text: "Use a fake clock" }));
  await page.unmount();
});

test("declined and refused messages read as one quiet line, the reason said", async () => {
  const fake = room();
  const page = await mount(fake);
  await fake.join();
  for (const text of ["Skip the test", "Bump the timeout"]) {
    await type(page.host, text);
    await enter(page.host);
  }
  // The outbox paces rapid submits; observe the second frame instead of reading it
  // before the 600 ms queue timer fires.
  await fake.until(() => fake.prompts().length === 2);
  const [skip, bump] = fake.prompts();
  await fake.frame({ v: 1, t: "prompt_state", client_id: skip!.client_id, state: "declined" });
  await fake.frame({
    v: 1,
    t: "prompt_state",
    client_id: bump!.client_id,
    state: "refused",
    reason: "share.too_many_held",
  });
  expect(mine(page.host)).toBe(
    translate("guest.prompt.declined", { text: "Skip the test" }) +
      translate("guest.prompt.tooManyHeld", { text: "Bump the timeout" }),
  );
  await page.unmount();
});

test("a message sent while the room is away goes after the reconnect, with the same client id", async () => {
  const fake = room();
  const page = await mount(fake);
  await fake.join();
  await type(page.host, "Held across a drop");
  await enter(page.host);
  const [sent] = fake.prompts();
  await act(async () => fake.last().onclose?.());
  // The room heard nothing of it; the next snapshot says nothing about it, so it goes again.
  await fake.until(() => fake.sockets.length === 2);
  await fake.join();
  // Reconnect replay shares the outbox pacing; observe the frame after its gap.
  await fake.until(() => fake.prompts().length === 1);
  expect(fake.prompts()).toEqual([sent!]);
  await page.unmount();
});

test("a held message after a reload: the snapshot's state wins, unanswered ones are asked about", async () => {
  const tab = memoryStorage(SHARE, [
    { clientId: "c-held", text: "Still waiting", at: 1, state: "held" },
    { clientId: "c-gone", text: "Answered while away", at: 2, state: "held" },
  ]);
  const fake = room();
  const page = await mount(fake, tab);
  await fake.join([{ client_id: "c-gone", state: "approved" }]);
  expect(fake.last().sent).toContainEqual({ v: 1, t: "prompt_status", client_ids: ["c-held"] });
  expect(mine(page.host)).toContain(translate("guest.prompt.sent", { text: "Answered while away" }));
  expect(mine(page.host)).toContain("Still waiting");
  await page.unmount();
});

test("a message over 32 KiB cannot be sent", async () => {
  const fake = room();
  const page = await mount(fake);
  await fake.join();
  await type(page.host, "é".repeat(PROMPT_MAX_BYTES / 2 + 1));
  expect(page.host.querySelector("[role=alert]")?.textContent).toBe(translate("guest.composer.tooLong"));
  expect((page.host.querySelector(".guest-composer button") as HTMLButtonElement).disabled).toBe(true);
  await enter(page.host);
  expect(fake.prompts()).toEqual([]);
  await page.unmount();
});
