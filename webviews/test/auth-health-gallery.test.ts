import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import strings from "../src/agent-session/acpmux/generated/strings.json";
import type { PlayContext } from "../src/gallery/play";
import fixture from "../src/agent-session/acpmux/AuthHealth.gallery";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: scope.window,
  document: scope.document,
  native: scope.cmuxAcpmuxMockNative,
  health: scope.cmuxAcpmuxMockHarnessHealth,
  auth: scope.cmuxAcpmuxMockSessionAuth,
};
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const [key, value] of Object.entries({
    window: saved.window,
    document: saved.document,
    cmuxAcpmuxMockNative: saved.native,
    cmuxAcpmuxMockHarnessHealth: saved.health,
    cmuxAcpmuxMockSessionAuth: saved.auth,
  }))
    if (value === undefined) delete scope[key];
    else scope[key] = value;
});

async function connected() {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  return AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
}

test("default mock health remains signed in without any gallery override", async () => {
  delete scope.cmuxAcpmuxMockNative;
  delete scope.cmuxAcpmuxMockHarnessHealth;
  delete scope.cmuxAcpmuxMockSessionAuth;
  const client = await connected();
  try {
    const rows = await client.harnessHealthRows();
    expect(rows).toContainEqual({ id: "claude", auth: "signedIn" });
    expect(rows).toContainEqual({ id: "codex", auth: "signedIn" });
  } finally {
    client.close();
  }
});

test("whole-page signed-out fixture's native health answer reaches direct client", async () => {
  scope.cmuxAcpmuxMockNative = fixture.variants["signed-out"]!.native;
  delete scope.cmuxAcpmuxMockHarnessHealth;
  const client = await connected();
  try {
    const rows = await client.harnessHealthRows();
    expect(rows).toContainEqual({ id: "claude", auth: "signedOut", login: "claude login" });
    expect(rows).toContainEqual({ id: "codex", auth: "signedIn" });
  } finally {
    client.close();
  }
});

test("expired fixture remains session-scoped and never becomes harness-wide signedOut", async () => {
  const expired = fixture.variants.expired!;
  scope.cmuxAcpmuxMockNative = expired.native;
  scope.cmuxAcpmuxMockHarnessHealth = expired.mockHarnessHealth;
  scope.cmuxAcpmuxMockSessionAuth = expired.mockSessionAuth;
  const client = await connected();
  try {
    expect(await client.harnessHealthRows()).toContainEqual({ id: "claude", auth: "unknown" });
    const request = client as unknown as { request(method: string, params: object): Promise<unknown> };
    expect(await request.request("_acpmux/session/auth", { target: { harness: "claude" } })).toEqual(
      expired.mockSessionAuth,
    );
  } finally {
    client.close();
  }
});

test("unknown target stays unknown, then a new socket without override restores signed-in default", async () => {
  scope.cmuxAcpmuxMockHarnessHealth = fixture.variants.unknown!.mockHarnessHealth;
  scope.cmuxAcpmuxMockSessionAuth = fixture.variants.unknown!.mockSessionAuth;
  const unknown = await connected();
  try {
    expect(await unknown.harnessHealthRows()).toContainEqual({ id: "claude", auth: "unknown" });
    const request = unknown as unknown as { request(method: string, params: object): Promise<unknown> };
    expect(await request.request("_acpmux/session/auth", { target: { harness: "claude" } })).toEqual(
      fixture.variants.unknown!.mockSessionAuth,
    );
  } finally {
    unknown.close();
  }
  delete scope.cmuxAcpmuxMockNative;
  delete scope.cmuxAcpmuxMockHarnessHealth;
  delete scope.cmuxAcpmuxMockSessionAuth;
  const reset = await connected();
  try {
    expect(await reset.harnessHealthRows()).toContainEqual({ id: "claude", auth: "signedIn" });
  } finally {
    reset.close();
  }
});

test("signed-out gallery play reaches the translated Log In row in Japanese", async () => {
  const oldStrings = scope.__cmuxPaneStrings;
  const oldLog = (dom.window as unknown as { cmuxGalleryLog?: unknown }).cmuxGalleryLog;
  scope.__cmuxPaneStrings = strings;
  const { setPaneLanguage, translate } = await import("../src/agent-session/acpmux/i18n");
  setPaneLanguage("ja");
  (dom.window as unknown as { cmuxGalleryLog?: unknown }).cmuxGalleryLog = [{ method: "acpmux health resolved" }];
  const japaneseLogin = translate("harness.logIn");
  expect(japaneseLogin).not.toBe("Log In");
  dom.window.document.body.innerHTML = `<div class="nt-screen"><span class="acpmux-model"><button class="acpmux-picker-button"></button></span></div>
     <div class="acpmux-quick-menu"><button class="acpmux-quick-item">${japaneseLogin}</button></div>`;
  let clicked = false;
  const ctx = {
    document: dom.window.document,
    click: async () => {
      clicked = true;
    },
    waitFor: async (condition: () => boolean | Element | null | undefined) => {
      expect(condition()).toBeTruthy();
    },
  } as unknown as PlayContext;
  try {
    await fixture.variants["signed-out"]!.play!(ctx);
    expect(clicked).toBe(true);
  } finally {
    setPaneLanguage("en");
    dom.window.document.body.innerHTML = "";
    if (oldStrings === undefined) delete scope.__cmuxPaneStrings;
    else scope.__cmuxPaneStrings = oldStrings;
    if (oldLog === undefined) delete (dom.window as unknown as { cmuxGalleryLog?: unknown }).cmuxGalleryLog;
    else (dom.window as unknown as { cmuxGalleryLog?: unknown }).cmuxGalleryLog = oldLog;
  }
});

test("the four whole-page New Tab fixture IDs and scope are stable", () => {
  expect(Object.keys(fixture.variants)).toEqual(["signed-in", "signed-out", "expired", "unknown"]);
  for (const variant of Object.values(fixture.variants)) {
    expect(variant.ready?.newSession).toBe(true);
    expect(variant.ready?.newTab).toBeTruthy();
    expect(variant.mockSessionAuth?.fromSessionId).toBeNull();
    expect(variant.mockSessionAuth?.host).toBeNull();
    expect(variant.mockSessionAuth?.routeId).toBeNull();
  }
  // The production client has no testing-global branch. Only the mock transport reads overrides.
  const direct = readFileSync(new URL("../src/agent-session/acpmux/direct.ts", import.meta.url), "utf8");
  expect(direct).not.toContain("cmuxAcpmuxMockHarnessHealth");
  expect(direct).not.toContain("cmuxAcpmuxMockSessionAuth");
});
