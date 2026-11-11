// A host part's card tells "not read yet" from "failed" from "the host has none" (ui-state-fixes
// M8): before its read answers a placeholder holds the card's place, a failed read shows an error
// with Try Again (which reads again and draws the card), and only a part the host does not have
// draws nothing. Settings > Devices and Settings > Mobile.
import { afterAll, describe, expect, test } from "bun:test";
import { installDom } from "./testDom";
import { partRead } from "./store";
import { TransportError } from "./transport";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");

const readState = (container: HTMLElement, card: string) =>
  container.querySelector<HTMLElement>(`[data-card-read="${card}"]`)?.dataset.read ?? null;

describe("partRead", () => {
  const error = (code: string) => ({ status: "error" as const, error: new TransportError({ code, message: code }) });
  test("no answer yet is pending, an answer is read, a failure is failed", () => {
    expect(partRead(undefined, false)).toBe("pending");
    expect(partRead({ status: "pending", error: null }, false)).toBe("pending");
    expect(partRead({ status: "success", error: null }, true)).toBe("read");
    expect(partRead(error("cmux.settings.devices.failed"), false)).toBe("failed");
  });
  test("a part with data stays read when a later re-read fails", () => {
    expect(partRead(error("cmux.settings.devices.failed"), true)).toBe("read");
  });
  test("a host without the op, or without the part, has none", () => {
    expect(partRead(error("cmux.op.unsupported"), false)).toBe("read");
    expect(partRead(error("cmux.page.unavailable"), false)).toBe("failed");
    expect(partRead(error("cmux.page.unavailable"), false, true)).toBe("read");
  });
});

test("Devices holds its place while its read is out", async () => {
  const page = await renderPage({
    path: "/settings/devices",
    // The device list's read never answers.
    setup: (provider) => void ((provider as unknown as { devices: unknown }).devices = new Promise(() => {})),
  });
  await settle();
  expect(readState(page.container, "devices")).toBe("pending");
  expect(page.container.querySelector('[data-card-read="devices"]')?.getAttribute("aria-busy")).toBe("true");
  expect(page.container.querySelector('[data-devices-group="this"]')).toBeNull();
  page.unmount();
});

test("a failed Devices read says so with Try Again, which reads again and draws the card", async () => {
  const failing: Record<string, string> = { "cmux.settings.devices.state": "cmux.settings.devices.failed" };
  const page = await renderPage({ path: "/settings/devices", mock: { failing } });
  await settle();
  expect(readState(page.container, "devices")).toBe("failed");
  // The error says what happened; the Try Again beside it is the only "try again" (round 2).
  expect(page.container.querySelector('[data-card-read="devices"] [role="alert"]')?.textContent).toBe(
    "cmux didn’t answer.",
  );
  expect(page.container.querySelector('[data-card-read="devices"]')?.textContent?.match(/try again/gi)?.length).toBe(1);
  delete failing["cmux.settings.devices.state"];
  await click(page.container.querySelector('[data-part-retry="devices"]')!);
  await settle();
  expect(readState(page.container, "devices")).toBeNull();
  expect(page.container.querySelector('[data-devices-group="this"]')).not.toBeNull();
  page.unmount();
});

test("a failed host read shows the Mobile card's error with Try Again, not a missing card", async () => {
  const failing: Record<string, string> = { "cmux.settings.host.lists": "cmux.settings.host.failed" };
  const page = await renderPage({ path: "/settings/mobile", mock: { failing } });
  await settle();
  expect(readState(page.container, "mobile")).toBe("failed");
  expect(page.container.querySelector('[data-part-retry="mobile"]')).not.toBeNull();
  page.unmount();
});

test("a host without an iPhone part draws no Mobile card", async () => {
  const page = await renderPage({ path: "/settings/mobile" });
  await settle();
  expect(page.provider.host.iphone ?? null).toBeNull();
  expect(readState(page.container, "mobile")).toBeNull();
  expect(page.container.querySelector('[data-card="mobile"]')).toBeNull();
  page.unmount();
});
