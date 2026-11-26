// l10n-allow-file: assertions use the localized builder output, not shipped copy.
// An MCP server the harness is still connecting says nothing for the shared bound (lasting.ts
// `CONNECTION_QUIET_MS`, 10 s): before, every launch drew "Connecting" on each server's row and in the
// section's head for the second or two they took to come up (scripts/cmux-next/check-connection-notices.py:
// a waiting state needs a bound).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { translate, type Translate } from "../src/agent-session/acpmux/i18n";
import { summarizeConnectors } from "../src/agent-session/acpmux/session-info/connectorState";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import { connectorsSection } from "../src/agent-session/acpmux/session-info/native/connectors";
import { teardownDom } from "./support/domTeardown";

const t: Translate = (key, values) => translate(key, values, "en");
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
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

afterAll(async () => {
  await teardownDom(saved, { scope });
});

test("a pending server that has not lasted the bound counts as loaded in the summary", () => {
  const servers = [{ status: "connected" as const }, { status: "pending" as const }];
  expect(summarizeConnectors(servers, false)).toEqual({ kind: "loaded", count: 2 });
  expect(summarizeConnectors(servers, true)).toEqual({ kind: "connecting", count: 1 });
});

test("native Connectors: a pending row says nothing until it has lasted, then Connecting", () => {
  const servers = [{ name: "github", status: "pending" as const }];
  const quiet = connectorsSection({ servers, open: true, pendingShown: false }, new NativeInfoActions(), t)!;
  expect(quiet.meta).toBe(t("sessionInfo.connectors.loaded", { count: 1 }));
  expect(quiet.rows[0]!.trailing).toBeUndefined();
  const lasting = connectorsSection({ servers, open: true, pendingShown: true }, new NativeInfoActions(), t)!;
  expect(lasting.meta).toBe(t("sessionInfo.connectors.connecting", { count: 1 }));
  expect(lasting.rows[0]!.trailing).toBe(t("rail.connectorPending"));
});

test("web Connectors: a server that just turned pending draws no Connecting", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ConnectorsSection } = await import("../src/agent-session/acpmux/session-info/ConnectorsSection");
  const root = createRoot(host);
  act(() => root.render(<ConnectorsSection servers={[{ name: "github", status: "pending" }]} />));
  expect(host.textContent).toContain("github");
  expect(host.textContent).not.toContain(t("rail.connectorPending"));
  expect(host.querySelector('[data-state="pending"]')).not.toBeNull();
  act(() => root.unmount());
});
