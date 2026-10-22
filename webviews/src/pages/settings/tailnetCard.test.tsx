// Settings > Accounts > This Mac on Your Tailnet (Labs): absent while Labs is off (the host sends
// null), unavailable on a daemon without the node, and the sign-in flow: Sign In, then Cancel and
// Reopen while the browser finishes, then the address with Copy and Pair (the cmux host join line).
// Limit access shows on and stays disabled until the node reads the choice.
import { afterAll, expect, test } from "bun:test";
import type { TailnetState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, ops } = await import("./testing");

const base: TailnetState = {
  title: "This Mac on Your Tailnet",
  phase: "signed_out",
  status_title: "Tailscale",
  status: "Reach this Mac from your other devices",
  busy: false,
  error: null,
  limited: true,
  limit_editable: false,
  limit_title: "Limit access to your Tailscale account",
  limit_help: "Only your Tailscale account can connect for now",
  sign_in_title: "Sign In…",
  reopen_title: "Reopen",
  cancel_title: "Cancel",
  sign_out_title: "Sign Out",
  address_title: "Remote Address",
  copy_title: "Copy",
  pair_title: "Pair…",
  done_title: "Done",
};

const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="tailnet"]');
const open = (tailnet: TailnetState | null) =>
  renderPage({ path: "/settings/accounts", setup: (provider) => provider.setHost({ ...provider.host, tailnet }) });

test("Labs off: no tailnet card", async () => {
  const page = await open(null);
  await settle();
  expect(page.container.querySelector('[data-section="accounts"]')).not.toBeNull();
  expect(card(page.container)).toBeNull();
  page.unmount();
});

test("a daemon without the node shows the card as unavailable, with no buttons or switch", async () => {
  const page = await open({ ...base, phase: "unavailable", status: "This cmux build can't join a tailnet" });
  await settle();
  expect(card(page.container)?.dataset.phase).toBe("unavailable");
  expect(card(page.container)?.querySelector("button")).toBeNull();
  page.unmount();
});

test("Sign In, then Cancel and Reopen while the browser finishes; Limit access is on and disabled", async () => {
  const page = await open(base);
  await settle();
  const limit = card(page.container)!.querySelector<HTMLButtonElement>('[role="switch"]')!;
  expect(limit.getAttribute("aria-checked")).toBe("true");
  expect(limit.disabled).toBe(true);
  await click(card(page.container)!.querySelector<HTMLButtonElement>("[data-tailnet-sign-in]")!);
  await settle();
  expect(ops(page.provider, "cmux.settings.tailnet.sign_in")).toEqual([{}]);
  expect(card(page.container)?.dataset.phase).toBe("waiting");
  expect(card(page.container)?.querySelector("[data-tailnet-reopen]")).not.toBeNull();
  await click(card(page.container)!.querySelector<HTMLButtonElement>("[data-tailnet-cancel]")!);
  await settle();
  expect(card(page.container)?.dataset.phase).toBe("signed_out");
  await click(card(page.container)!.querySelector<HTMLButtonElement>('[role="switch"]')!);
  await settle();
  expect(card(page.container)!.querySelector('[role="switch"]')?.getAttribute("aria-checked")).toBe("true");
  page.unmount();
});

test("signed in: the address with Copy and Pair; Pair shows the join line, Done closes it", async () => {
  const page = await open({
    ...base,
    phase: "signed_in",
    status: "Signed in as me@example.com",
    address: "https://mac-cmux.tail1.ts.net",
  });
  await settle();
  expect(card(page.container)?.querySelector("[data-tailnet-address]")?.textContent).toContain(
    "https://mac-cmux.tail1.ts.net",
  );
  await click(card(page.container)!.querySelector<HTMLButtonElement>("[data-tailnet-pair]")!);
  await settle();
  expect(card(page.container)?.querySelector("[data-tailnet-pair-command]")?.textContent).toStartWith(
    "cmux host join ",
  );
  await click(card(page.container)!.querySelector<HTMLButtonElement>("[data-tailnet-done]")!);
  await settle();
  expect(card(page.container)?.querySelector("[data-tailnet-pair]")).not.toBeNull();
  expect(card(page.container)?.querySelector("[data-tailnet-pair-command]")).toBeNull();
  page.unmount();
});
