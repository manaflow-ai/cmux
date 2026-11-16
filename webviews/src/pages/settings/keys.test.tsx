// Settings > Keys (design/settings-keys.md): an agent's key request waits at the top with what it is
// for, who asked and the sites it may go to; Store sends the typed value to the host once and the
// field empties; Decline ends the request; below, every key with where it may go, where it went,
// who added it and its state, never a value; Revoke asks first. No keys: one line naming the command.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockSettingsProvider } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, changeValue, fire } = await import("./testing");
const { keyRows, keyRequestRows, actorLabel } = await import("./keys");
const { mockKeys } = await import("./mockProvider");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="keys"]')!;
const asks = () => page!.container.querySelector<HTMLElement>('[data-card="keyRequests"]');
const keyIds = () => [...card().querySelectorAll<HTMLElement>("[data-key]")].map((row) => row.dataset.key);
const field = () => page!.container.querySelector<HTMLInputElement>("[data-key-request-field]")!;

async function open(setup?: (provider: MockSettingsProvider) => void) {
  page = await renderPage({ path: "/settings/keys", setup });
  await settle();
  return page;
}

test("rows: live first, then expired, then revoked; a record without the newer fields still reads", () => {
  const now = Date.UTC(2026, 10, 15, 12);
  const rows = keyRows(mockKeys(now), now);
  expect(rows.map((row) => [row.id, row.state])).toEqual([
    ["local-search_api_key", "live"],
    ["cf-7d1e", "expired"],
    ["local-publish_token", "revoked"],
  ]);
  expect(rows[0]).toMatchObject({
    hosts: ["search.example.com"],
    places: ["gh-secret:example/search:SEARCH_API_KEY", "search.example.com ×12"],
    by: "Claude Code · 9b1c2d3e",
  });
  // An older Cloudflare record: no label, no state, no hosts; past its expiry it reads expired.
  const old = keyRows(
    {
      requests: [],
      keys: [{ id: "cf-1", bucket: "handoff", provider: "cloudflare", expires_at: "2026-11-01T00:00:00Z" }],
    },
    now,
  );
  expect(old[0]).toMatchObject({ label: "handoff", state: "expired", hosts: [], places: [] });
  expect(actorLabel("user=you")).toBe("you");
  expect(keyRequestRows(mockKeys(now))[0]).toMatchObject({
    name: "DEPLOY_TOKEN",
    requester: "Claude Code · 4f2a9c1e",
  });
});

test("the card shows the waiting request and every key, never a value", async () => {
  await open();
  const request = asks()!.querySelector<HTMLElement>('[data-key-request="kr_0001"]')!;
  expect(request.textContent).toContain("DEPLOY_TOKEN");
  expect(request.querySelector("[data-key-request-purpose]")!.textContent).toContain("staging site");
  expect(request.querySelector("[data-key-request-detail]")!.textContent).toBe("Asked by Claude Code · 4f2a9c1e");
  // The sites and the agent's words are values (copyable); the description lines stay short.
  expect(request.querySelector("[data-key-request-hosts]")!.textContent).toBe("For api.example.com");
  expect(request.querySelector("[data-key-request-hosts]")!.classList.contains("selectable")).toBe(true);
  expect(field().type).toBe("password");
  expect(field().getAttribute("autocomplete")).toBe("off");
  expect(field().getAttribute("spellcheck")).toBe("false");
  expect(keyIds()).toEqual(["local-search_api_key", "cf-7d1e", "local-publish_token"]);
  const live = card().querySelector<HTMLElement>('[data-key="local-search_api_key"]')!;
  expect(live.querySelector("[data-key-detail]")!.textContent).toContain(
    "Used in gh-secret:example/search:SEARCH_API_KEY",
  );
  expect(live.querySelector("[data-key-added]")!.textContent).toBe("Added by Claude Code · 9b1c2d3e");
  expect(live.querySelector("[data-key-status]")!.textContent).toBe("Active");
  // A revoked key has nothing left to revoke.
  expect(card().querySelector('[data-key="local-publish_token"] [data-key-action="revoke"]')).toBeNull();
});

test("Store sends the typed value once, empties the field, and the request leaves", async () => {
  await open();
  const store = () => asks()!.querySelector<HTMLButtonElement>('[data-key-request-action="store"]')!;
  expect(store().disabled).toBe(true);
  await changeValue(field(), "example-value");
  expect(store().disabled).toBe(false);
  await fire(asks()!.querySelector("form")!, "submit");
  await settle();
  expect(page!.provider.keyAnswers).toEqual([{ request_id: "kr_0001", value: "example-value" }]);
  expect(asks()).toBeNull();
  expect(keyIds()).toContain("local-deploy_token");
  // The value is nowhere on the page.
  expect(page!.container.innerHTML).not.toContain("example-value");
});

test("a refused Store says why and puts the typed value back", async () => {
  await open((provider) => {
    provider.keyAnswerRefusal = "keychain locked";
  });
  await changeValue(field(), "example-value");
  await fire(asks()!.querySelector("form")!, "submit");
  await settle();
  expect(page!.provider.keyAnswers).toEqual([]);
  expect(asks()!.querySelector("[data-key-request-error]")!.textContent).toContain("Couldn’t store the key");
  expect(field().value).toBe("example-value");
});

test("Decline ends the request without a value", async () => {
  await open();
  await changeValue(field(), "typed-then-declined");
  await click(asks()!.querySelector<HTMLButtonElement>('[data-key-request-action="decline"]')!);
  await settle();
  expect(page!.provider.keyDeclines).toEqual(["kr_0001"]);
  expect(page!.provider.keyAnswers).toEqual([]);
  expect(asks()).toBeNull();
});

test("Revoke asks first; Cancel keeps the key, confirming revokes it", async () => {
  await open();
  const row = () => card().querySelector<HTMLElement>('[data-key="local-search_api_key"]')!;
  await click(row().querySelector<HTMLButtonElement>('[data-key-action="revoke"]')!);
  expect(row().querySelector("[data-key-confirm]")!.textContent).toContain("deleted from this Mac");
  await click(row().querySelector<HTMLButtonElement>('[data-key-action="cancel"]')!);
  expect(row().querySelector("[data-key-confirm]")).toBeNull();
  expect(page!.provider.keyRevokes).toEqual([]);
  await click(row().querySelector<HTMLButtonElement>('[data-key-action="revoke"]')!);
  await click(row().querySelector<HTMLButtonElement>('[data-key-action="confirmRevoke"]')!);
  await settle();
  expect(page!.provider.keyRevokes).toEqual(["local-search_api_key"]);
  expect(row().dataset.keyState).toBe("revoked");
});

test("no keys: one line naming cmux keys put; no list: one line", async () => {
  await open((provider) => {
    provider.keys = { available: true, requests: [], keys: [] };
  });
  expect(asks()).toBeNull();
  const empty = card().querySelector<HTMLElement>("[data-keys-empty]")!;
  expect(empty.textContent).toBe("No keys yet. An agent adds one with cmux keys put NAME.");
  expect(empty.querySelector("code")!.textContent).toBe("cmux keys put NAME");
  page!.unmount();
  await open((provider) => {
    provider.keys = { available: false, requests: [], keys: [] };
  });
  expect(card().querySelector("[data-keys-unavailable]")).not.toBeNull();
});

test("a request that arrives while Keys is open shows at once", async () => {
  await open((provider) => {
    provider.keys = { available: true, requests: [], keys: [] };
  });
  expect(asks()).toBeNull();
  const now = Date.now();
  page!.provider.setKeys({ ...mockKeys(now), keys: [] });
  await settle();
  await settle();
  expect(asks()!.querySelector('[data-key-request="kr_0001"]')).not.toBeNull();
});
