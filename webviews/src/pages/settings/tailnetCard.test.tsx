// Settings > Server > This Mac on Your Tailnet: the card shows acpmux's tailnet state and walks a sign-in
// through the app's relay. Sign In starts the node and offers its sign-in page as a link; Cancel and Sign
// Out sign out; a sign-in waiting on the browser is read again when the window comes back; a step the app's
// relay got no answer for says so; an acpmux with no tailnet draws no card.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockSettingsProvider } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");
const { tailnetView } = await import("./tailnet");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="tailnet"]');

async function open(setup?: (provider: MockSettingsProvider) => void) {
  page = await renderPage({ path: "/settings/server", setup });
  await settle();
  return page;
}

test("view: each acpmux state maps to one row, and only an https sign-in page is offered", () => {
  expect(tailnetView({ state: "stopped" })).toEqual({ kind: "signedOut" });
  expect(tailnetView({ state: "in_use_other_user" })).toEqual({ kind: "signedOut" });
  expect(tailnetView({ state: "starting" })).toEqual({ kind: "starting" });
  expect(tailnetView({ state: "needs_machine_auth" })).toEqual({ kind: "approval" });
  expect(tailnetView({ state: "needs_login", browse_to_url: "https://login.tailscale.com/a/x" })).toEqual({
    kind: "needsLogin",
    url: "https://login.tailscale.com/a/x",
  });
  expect(tailnetView({ state: "needs_login", browse_to_url: "javascript:alert(1)" })).toEqual({
    kind: "needsLogin",
    url: null,
  });
  expect(tailnetView({ state: "running", dns_name: "mac.ts.net", ips: ["fd7a::1", "100.64.0.9"] })).toEqual({
    kind: "signedIn",
    address: "mac.ts.net · 100.64.0.9",
  });
  expect(tailnetView({ state: "error", error: "boom" })).toEqual({ kind: "error", message: "boom" });
});

test("Sign In starts the node and offers the sign-in page; Cancel signs out", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
  });
  expect(card()!.dataset.tailnetState).toBe("signedOut");
  // acpmux answers `starting`; the card reads the state again, which brings the sign-in page.
  const reread = new Promise<void>((resolve) => {
    provider.onTailnetRead = resolve;
  });
  await click(card()!.querySelector<HTMLElement>('[data-tailnet-action="start"]')!);
  await reread;
  await settle();
  expect(provider.tailnetSteps).toEqual(["start"]);
  expect(card()!.dataset.tailnetState).toBe("needsLogin");
  const link = card()!.querySelector<HTMLAnchorElement>("[data-tailnet-sign-in-page]")!;
  expect(link.getAttribute("href")).toBe("https://login.tailscale.com/a/1a2b3c4d5e");
  await click(card()!.querySelector<HTMLElement>('[data-tailnet-action="logout"]')!);
  await settle();
  expect(provider.tailnetSteps).toEqual(["start", "logout"]);
  expect(card()!.dataset.tailnetState).toBe("signedOut");
});

test("a sign-in waiting on the browser is read again when the window comes back", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.tailnet = { state: "needs_login", browse_to_url: "https://login.tailscale.com/a/1" };
  });
  expect(card()!.dataset.tailnetState).toBe("needsLogin");
  provider.tailnet = { state: "running", dns_name: "studio.ts.net", ips: ["100.64.0.2"] };
  globalThis.window.dispatchEvent(new globalThis.window.Event("focus"));
  await settle();
  expect(card()!.dataset.tailnetState).toBe("signedIn");
  expect(card()!.textContent).toContain("studio.ts.net · 100.64.0.2");
  expect(card()!.querySelector('[data-tailnet-action="logout"]')).not.toBeNull();
});

test("an acpmux with no tailnet draws no card", async () => {
  await open((p) => {
    p.tailnet = null;
  });
  expect(card()).toBeNull();
});

test("Sign In with no answer keeps the card and says the agent service did not answer", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
  });
  provider.tailnetRefuses = true;
  await click(card()!.querySelector<HTMLElement>('[data-tailnet-action="start"]')!);
  await settle();
  expect(card()!.dataset.tailnetState).toBe("signedOut");
  expect(card()!.textContent).toContain("cmux’s agent service didn’t answer. Try again.");
});

test("a failed Sign In shows acpmux's own reason and Try Again", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
  });
  provider.tailnetFails = "tailnet start was superseded";
  await click(card()!.querySelector<HTMLElement>('[data-tailnet-action="start"]')!);
  await settle();
  expect(card()!.dataset.tailnetState).toBe("error");
  expect(card()!.textContent).toContain("tailnet start was superseded");
  expect(card()!.textContent).not.toContain("didn’t answer");
  expect(card()!.querySelector('[data-tailnet-action="start"]')).not.toBeNull();
});

test("Sign Out with no answer says so instead of showing the old state", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.tailnet = { state: "running", dns_name: "studio.ts.net", ips: ["100.64.0.2"] };
  });
  provider.tailnetRefuses = true;
  provider.tailnet = { state: "stopped" };
  await click(card()!.querySelector<HTMLElement>('[data-tailnet-action="logout"]')!);
  await settle();
  expect(card()!.textContent).toContain("cmux’s agent service didn’t answer. Try again.");
});

test("a dropped read after Sign In keeps going and still reaches the sign-in page", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
  });
  provider.tailnetDropReads = 1;
  let reads = 0;
  const second = new Promise<void>((resolve) => {
    provider.onTailnetRead = () => {
      reads += 1;
      if (reads === 2) resolve();
    };
  });
  await click(card()!.querySelector<HTMLElement>('[data-tailnet-action="start"]')!);
  await second;
  await settle();
  expect(card()!.dataset.tailnetState).toBe("needsLogin");
  expect(card()!.textContent).not.toContain("didn’t answer");
});
