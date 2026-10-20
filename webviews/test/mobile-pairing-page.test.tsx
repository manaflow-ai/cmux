// The Mobile Pairing page (cmux-page://cmux.mobile-pairing/) over a fake host: it loads the
// status, asks again on every change event, names the one missing step with its button, shows the
// QR code once the Mac is reachable, asks for a new code when the shown one expires, and a missing
// host says so instead of loading forever.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";
import type { MobilePairingStatus } from "../src/pages/mobile-pairing/types";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Call = { op: string; params: unknown };

/** A host whose status the test sets, recording every call and holding the change stream. */
function fakeHost(initial: MobilePairingStatus) {
  let status = initial;
  const calls: Call[] = [];
  let emit: (() => void) | undefined;
  let unsubscribed = 0;
  const client: PageClient = {
    call: async <R,>(op: string, params: unknown) => {
      calls.push({ op, params });
      if (op === "cmux.mobilePairing.status") return status as R;
      if (op === "cmux.mobilePairing.setAllowed") {
        status = { ...status, allowed: (params as { on: boolean }).on };
        return {} as R;
      }
      if (op === "cmux.app.action.run") return { ran: true } as R;
      throw pageError("cmux.op.unknown", op);
    },
    subscribe: async <E,>(stream: string, onEvent: (data: E, seq: number) => void) => {
      calls.push({ op: `sub:${stream}`, params: undefined });
      emit = () => onEvent({} as E, 1);
      return () => void unsubscribed++;
    },
    handle: () => () => {},
  };
  return {
    client,
    calls,
    set: (next: MobilePairingStatus) => void (status = next),
    emit: () => emit?.(),
    unsubscribed: () => unsubscribed,
  };
}

const BASE: MobilePairingStatus = { state: "signedOut", macName: "Studio", allowed: false, connectedPhones: 0 };

test("the store loads the status, follows change events and stops cleanly", async () => {
  const { MobilePairingStore } = await import("../src/pages/mobile-pairing/store");
  const fake = fakeHost(BASE);
  const store = new MobilePairingStore(fake.client);
  await store.start();
  expect(store.getSnapshot().status?.state).toBe("signedOut");
  expect(fake.calls.map((call) => call.op)).toEqual(["sub:cmux.mobilePairing.changes", "cmux.mobilePairing.status"]);

  fake.set({ ...BASE, state: "accessOff", account: "me@example.com" });
  fake.emit();
  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(store.getSnapshot().status?.state).toBe("accessOff");
  expect(store.getSnapshot().status?.account).toBe("me@example.com");

  store.stop();
  expect(fake.unsubscribed()).toBe(1);
});

test("turning phone access on writes the setting, then reads the status again", async () => {
  const { MobilePairingStore } = await import("../src/pages/mobile-pairing/store");
  const fake = fakeHost({ ...BASE, state: "accessOff", account: "me@example.com" });
  const store = new MobilePairingStore(fake.client);
  await store.start();
  await store.setAllowed(true);
  expect(fake.calls.filter((call) => call.op === "cmux.mobilePairing.setAllowed")).toEqual([
    { op: "cmux.mobilePairing.setAllowed", params: { on: true } },
  ]);
  expect(store.getSnapshot().status?.allowed).toBe(true);
});

test("sign in and Settings run the page's two actions", async () => {
  const { MobilePairingStore } = await import("../src/pages/mobile-pairing/store");
  const fake = fakeHost(BASE);
  const store = new MobilePairingStore(fake.client);
  await store.start();
  await store.signIn();
  await store.openAccounts();
  expect(fake.calls.filter((call) => call.op === "cmux.app.action.run").map((call) => call.params)).toEqual([
    { action: "palette.auth.signIn" },
    { action: "accounts.show" },
  ]);
});

test("an expired code is replaced: the store asks again once the shown one expires", async () => {
  const { MobilePairingStore } = await import("../src/pages/mobile-pairing/store");
  let now = 1_000;
  const ready: MobilePairingStatus = {
    ...BASE,
    state: "ready",
    allowed: true,
    account: "me@example.com",
    qr: { url: "cmux-dev://attach?t=1", image: "data:image/png;base64,AAAA", expiresAt: 2_000 },
  };
  const fake = fakeHost(ready);
  const store = new MobilePairingStore(fake.client, () => now);
  await store.start();
  const asked = () => fake.calls.filter((call) => call.op === "cmux.mobilePairing.status").length;
  expect(asked()).toBe(1);
  await store.refreshIfExpired();
  expect(asked()).toBe(1);
  now = 2_500;
  await store.refreshIfExpired();
  expect(asked()).toBe(2);
});

test("no host: the page says so instead of loading forever", async () => {
  const { MobilePairingStore } = await import("../src/pages/mobile-pairing/store");
  const store = new MobilePairingStore(null);
  await store.start();
  expect(store.getSnapshot()).toEqual({ loading: false, unavailable: true });
});

test("the page names the missing step and shows the code once ready", async () => {
  const { createRoot } = await import("react-dom/client");
  const { MobilePairingPage } = await import("../src/pages/mobile-pairing/MobilePairingPage");
  const { MobilePairingStore } = await import("../src/pages/mobile-pairing/store");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/mobile-pairing/generated/strings.json")).default;

  const fake = fakeHost(BASE);
  const store = new MobilePairingStore(fake.client);
  root = createRoot(host);
  act(() => root!.render(<MobilePairingPage store={store} strings={createStrings(table, ["en"])} />));
  await act(async () => await store.start());
  expect(host.querySelector("h1")?.textContent).toBe("Pair your iPhone");
  const signIn = host.querySelector<HTMLButtonElement>("[data-action=sign-in]");
  expect(signIn).not.toBeNull();
  await act(async () => signIn!.click());
  expect(fake.calls.some((call) => call.op === "cmux.app.action.run")).toBe(true);

  fake.set({ ...BASE, state: "accessOff", account: "me@example.com" });
  await act(async () => fake.emit());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(host.textContent).toContain("me@example.com");
  const allow = host.querySelector<HTMLButtonElement>("[data-action=allow]");
  expect(allow).not.toBeNull();
  await act(async () => allow!.click());
  expect(fake.calls.filter((call) => call.op === "cmux.mobilePairing.setAllowed").length).toBe(1);

  fake.set({
    ...BASE,
    state: "ready",
    allowed: true,
    account: "me@example.com",
    connectedPhones: 2,
    qr: { url: "cmux-dev://attach?t=1", image: "data:image/png;base64,AAAA", expiresAt: Date.now() + 600_000 },
  });
  await act(async () => fake.emit());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const qr = host.querySelector<HTMLImageElement>("img.pairing-qr");
  expect(qr?.getAttribute("src")).toBe("data:image/png;base64,AAAA");
  expect(host.textContent).toContain("Studio");
  expect(host.querySelector("[data-action=allow]")).toBeNull();
  expect(host.querySelector(".pairing-connected")?.textContent).toContain("2");

  fake.set({ ...BASE, state: "failed", allowed: true, account: "me@example.com", failure: "relay refused" });
  await act(async () => fake.emit());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(host.querySelector("img.pairing-qr")).toBeNull();
  expect(host.querySelector(".pairing-failure-detail")?.textContent).toBe("relay refused");
});
