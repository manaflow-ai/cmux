// Settings > Mobile: its own category with the schema switch mobile.allowIPhoneConnections and the
// host's iPhone card (host lists `iphone`), which follows the host live; Accounts no longer has it.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { IPhoneHostState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="mobile"]');
const state: IPhoneHostState = {
  title: "Connection",
  allowed: true,
  status_title: "Status",
  status: "Online · Phones connected: 1",
  phase: "online",
  account_title: "Account",
  account: "Registered as me@example.com",
  space_title: "Space",
  space: "Personal",
  how_title: "How to Connect",
  how: "Install cmux on your iPhone",
  phones_title: "Connected Phones",
  phones_empty: "No phones are connected.",
  phones: [
    {
      id: "p1",
      title: "Aziz's iPhone",
      subtitle: "WireGuard · Relayed",
      connected: true,
      removable: true,
      transport: "wireguard",
      path: "relay",
    },
    {
      id: "p2",
      title: "Old iPhone",
      subtitle: "Not connected",
      connected: false,
      removable: true,
      transport: null,
      path: null,
    },
    {
      id: "s9",
      title: "iPhone 9f3c",
      subtitle: "WebRTC · Direct",
      connected: true,
      removable: false,
      transport: "webrtc",
      path: "direct",
    },
  ],
  phones_error: null,
  remove_title: "Remove",
  remove_help: "Removes this phone",
};

test("Mobile is its own category with the allow switch; Accounts has no iPhone card", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: state }));
  await settle();
  expect(page.container.querySelector('[data-row-key="mobile.allowIPhoneConnections"]')).not.toBeNull();
  // The terminal sizing policy row; its priority order is set on the phone and stays hidden here.
  expect(page.container.querySelector('[data-row-key="mobile.terminalSizing"]')).not.toBeNull();
  expect(page.container.querySelector('[data-row-key="mobile.terminalSizingOrder"]')).toBeNull();
  expect(card(page.container)).not.toBeNull();
  page.unmount();
  const accounts = await renderPage({ path: "/settings/accounts" });
  await act(async () => accounts.provider.setHost({ ...accounts.provider.host, iphone: state }));
  await settle();
  expect(card(accounts.container)).toBeNull();
  accounts.unmount();
});

test("the card shows status, space and phones with their transport, and follows the host", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: state }));
  await settle();
  const element = card(page.container)!;
  expect(element.dataset.phase).toBe("online");
  expect(element.textContent).toContain("Online · Phones connected: 1");
  expect(element.textContent).toContain("Personal");
  expect(element.textContent).toContain("Registered as me@example.com");
  const phone = element.querySelector<HTMLElement>("[data-mobile-phone]")!;
  expect([phone.dataset.transport, phone.dataset.path, phone.dataset.connected]).toEqual([
    "wireguard",
    "relay",
    "true",
  ]);
  expect(element.querySelectorAll("[data-remove-phone]").length).toBe(2);
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: { ...state, phones: [] } }));
  await settle();
  expect(card(page.container)!.textContent).toContain("No phones are connected.");
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      // Off and signed out with no phones left; trusted phones stay listed while off (next test).
      iphone: { ...state, allowed: false, account: null, space: null, phase: "off", phones: [] },
    }),
  );
  await settle();
  expect(card(page.container)!.querySelector("[data-mobile-phones]")).toBeNull();
  expect(card(page.container)!.textContent).not.toContain("Personal");
  page.unmount();
});

test("Phone Access rows remain visible and removable when the legacy host is off", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      iphone: {
        ...state,
        allowed: false,
        account: null,
        space: null,
        phase: "off",
        phones: [
          {
            id: "iroh:peer",
            title: "Demo iPhone · cmux next",
            subtitle: "Device key demo",
            connected: false,
            removable: true,
            transport: "iroh",
            path: null,
          },
        ],
      },
    }),
  );
  await settle();
  const element = card(page.container)!;
  expect(element.querySelector('[data-mobile-phone="iroh:peer"]')).not.toBeNull();
  await act(async () => element.querySelector<HTMLButtonElement>('[data-remove-phone="iroh:peer"]')!.click());
  await settle();
  expect(page.provider.log.some((entry) => entry.op === "cmux.settings.mobile.remove_phone")).toBe(true);
  page.unmount();
});

test("the switch writes the setting through cmux.settings.set", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await settle();
  const toggle = page.container.querySelector<HTMLButtonElement>('[role="switch"]')!;
  await act(async () => toggle.click());
  await settle();
  const writes = page.provider.log.filter((entry) => entry.op === "cmux.settings.set");
  expect(writes.map((entry) => (entry.params as { key: string }).key)).toContain("mobile.allowIPhoneConnections");
  page.unmount();
});

test("Remove sends cmux.settings.mobile.remove_phone for that phone and the list drops it", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: state }));
  await settle();
  await act(async () => card(page.container)!.querySelector<HTMLButtonElement>('[data-remove-phone="p2"]')!.click());
  await settle();
  const sent = page.provider.log.filter((entry) => entry.op === "cmux.settings.mobile.remove_phone");
  expect(sent.map((entry) => (entry.params as { id: string }).id)).toEqual(["p2"]);
  expect(card(page.container)!.querySelector('[data-mobile-phone="p2"]')).toBeNull();
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      iphone: { ...state, phones_error: "Could not remove this phone." },
    }),
  );
  await settle();
  expect(card(page.container)!.querySelector("[data-mobile-error]")!.textContent).toBe("Could not remove this phone.");
  page.unmount();
});

test("a removed Mac says so and Allow Again sends cmux.settings.mobile.allow_again", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  const removed: IPhoneHostState = {
    ...state,
    phase: "removed",
    status: "This Mac was removed from your account's devices.",
    allow_again_title: "Allow Again",
    phones: [],
  };
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: removed }));
  await settle();
  const element = card(page.container)!;
  expect(element.dataset.phase).toBe("removed");
  expect(element.textContent).toContain("This Mac was removed");
  await act(async () => element.querySelector<HTMLButtonElement>("[data-allow-again]")!.click());
  await settle();
  expect(page.provider.log.some((entry) => entry.op === "cmux.settings.mobile.allow_again")).toBe(true);
  expect(card(page.container)!.querySelector("[data-allow-again]")).toBeNull();
  page.unmount();
});

test("a waiting pairing request has Allow and Don't Allow, and the blocked count shows quietly", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  const asking: IPhoneHostState = {
    ...state,
    pending_title: "Connection Requests",
    pending: [
      {
        id: "n1",
        title: "“New iPhone” wants to connect to this Mac",
        subtitle: "Signed in as me@example.com · Registered today",
      },
      { id: "n2", title: "“Other iPhone” wants to connect to this Mac", subtitle: "Signed in as me@example.com" },
    ],
    pair_allow_title: "Allow",
    pair_deny_title: "Don't Allow",
    blocked: null,
    blocked_help: "Ignored for 10 minutes",
  };
  await act(async () => page.provider.setHost({ ...page.provider.host, iphone: asking }));
  await settle();
  const element = card(page.container)!;
  expect(element.querySelectorAll("[data-pair-request]").length).toBe(2);
  expect(element.textContent).toContain("Registered today");
  expect(element.textContent).not.toContain("Blocked requests");
  await act(async () => element.querySelector<HTMLButtonElement>('[data-pair-allow="n1"]')!.click());
  await settle();
  await act(async () => card(page.container)!.querySelector<HTMLButtonElement>('[data-pair-deny="n2"]')!.click());
  await settle();
  const sent = page.provider.log.filter((entry) => entry.op === "cmux.settings.mobile.answer_pair");
  expect(sent.map((entry) => entry.params)).toEqual([
    { id: "n1", allow: true },
    { id: "n2", allow: false },
  ]);
  expect(card(page.container)!.querySelector("[data-mobile-pending]")).toBeNull();
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      iphone: { ...asking, pending: [], blocked: "Blocked requests: 3" },
    }),
  );
  await settle();
  expect(card(page.container)!.textContent).toContain("Blocked requests: 3");
  await act(async () =>
    page.provider.setHost({ ...page.provider.host, iphone: { ...asking, allowed: false, phase: "off" } }),
  );
  await settle();
  expect(card(page.container)!.querySelector("[data-pair-request]")).toBeNull();
  page.unmount();
});
