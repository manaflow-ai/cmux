import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { ChiefContactStatus } from "./chiefContact";

const restore = installDom();
afterAll(restore);
const { createRoot } = await import("react-dom/client");
const { ChiefContactSheet } = await import("./components/ChiefContactSheet");
const { MockChiefContact } = await import("./mockChiefContact");
const { contactHandle, contactError } = await import("./chiefContact");
const { changeValue, settle } = await import("./testing");

async function render(client = new MockChiefContact()) {
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  await act(async () =>
    root.render(<ChiefContactSheet service={client} mascot="data:image/png;base64," onClose={() => {}} />),
  );
  await settle();
  const dialog = document.querySelector<HTMLElement>('[role="dialog"]')!;
  return {
    client,
    dialog,
    input: dialog.querySelector<HTMLInputElement>("input")!,
    async submit() {
      await act(async () =>
        dialog.querySelector("form")!.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true })),
      );
      await settle();
    },
    close() {
      act(() => root.unmount());
      element.remove();
    },
  };
}

test("opening is read-only, unavailable channels stay disabled, a request waits for confirmation", async () => {
  const page = await render();
  expect(page.client.requests).toEqual([]);
  expect(page.dialog.querySelector<HTMLButtonElement>('[aria-label="Call"]')!.disabled).toBe(true);
  expect(page.dialog.querySelector<HTMLButtonElement>('[aria-label="Slack"]')!.disabled).toBe(true);
  expect(page.dialog.querySelector('[aria-label="Text"]')!.getAttribute("aria-pressed")).toBe("true");
  await changeValue(page.input, "+1 (555) 555-0123");
  await page.submit();
  expect(page.client.requests).toEqual(["+15555550123"]);
  expect(page.dialog.textContent).toContain("Waiting for confirmation.");
  await act(async () => page.client.publish({ state: "linked", handle: "+15555550123" }));
  expect(page.dialog.textContent).toContain("Your Chief is linked to this conversation.");
  const unlink = [...page.dialog.querySelectorAll("button")].find((node) => node.textContent === "Unlink")!;
  await act(async () => unlink.click());
  expect(page.client.unlinks).toBe(1);
  expect(page.input.disabled).toBe(false);
  page.close();
  expect(page.client.listeners.size).toBe(0);
});

test("invalid input never requests, and a sending request cannot be duplicated", async () => {
  const client = new MockChiefContact();
  client.holdRequest = true;
  const page = await render(client);
  await changeValue(page.input, "not an address");
  await page.submit();
  expect(client.requests).toEqual([]);
  await changeValue(page.input, "owner@example.com");
  await page.submit();
  await page.submit();
  expect(client.requests).toEqual(["owner@example.com"]);
  expect(page.dialog.textContent).toContain("Sending…");
  page.close();
});

test.each([
  ["link.rate_limited", "Too many confirmation requests. Try again later."],
  ["link.bound_elsewhere", "This address is already linked to another account."],
] as const)("%s preserves the owner's error without pretending a link was made", async (code, text) => {
  const client = new MockChiefContact();
  client.requestError = code;
  const page = await render(client);
  await changeValue(page.input, "owner@example.com");
  await page.submit();
  expect(page.dialog.querySelector('[role="alert"]')!.textContent).toBe(text);
  expect(page.input.disabled).toBe(false);
  expect(client.value.state).toBe("idle");
  page.close();
});

test("a late initial status never overwrites a confirmed push, and STOP unlinks the view", async () => {
  const client = new MockChiefContact();
  let resolve!: (value: ChiefContactStatus) => void;
  client.status = () =>
    new Promise((done) => {
      resolve = done;
    });
  const page = await render(client);
  await act(async () => client.publish({ state: "linked", handle: "owner@example.com" }));
  await act(async () => resolve({ state: "idle" }));
  expect(page.dialog.textContent).toContain("Your Chief is linked to this conversation.");
  await act(async () => client.publish({ state: "stopped" }));
  expect(page.dialog.textContent).toContain("Disconnected after STOP.");
  expect(page.input.disabled).toBe(false);
  page.close();
});

test("canonical handles and existing link error codes", () => {
  expect(contactHandle(" owner@example.com ")).toBe("owner@example.com");
  expect(contactHandle("5555550123")).toBeNull();
  expect(contactError({ code: "link.expired" })).toBe("expired");
  expect(contactError({ code: "link.none" })).toBe("expired");
  expect(contactError({ code: "link.wrong_account" })).toBe("wrongAccount");
  expect(contactError({ code: "link.invalid" })).toBe("invalidLink");
});

test("status waits for subscription setup and late subscriptions are cleaned up", async () => {
  const client = new MockChiefContact();
  let install!: () => void;
  let reads = 0;
  client.status = async () => {
    reads++;
    return client.value;
  };
  client.subscribe = (listener) =>
    new Promise((done) => {
      install = () => {
        client.listeners.add(listener);
        done(() => {
          client.listeners.delete(listener);
        });
      };
    });
  const page = await render(client);
  expect(reads).toBe(0);
  client.value = { state: "linked", handle: "owner@example.com" };
  await act(async () => install());
  expect(reads).toBe(1);
  expect(page.dialog.textContent).toContain("Your Chief is linked to this conversation.");
  page.close();
  const late = await render(client);
  late.close();
  await act(async () => install());
  expect(client.listeners.size).toBe(0);
  expect(reads).toBe(1);
});
