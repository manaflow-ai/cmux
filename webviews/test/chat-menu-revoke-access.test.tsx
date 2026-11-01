// l10n-allow-file: test fixture folder names, not shipped UI.
// A granted folder trust stays revocable with default settings (the #28617 review's P1). The
// composer's mode menu no longer lists grants (Leo, 2026-10-29: "What is this bottom fucking
// bullshit?"), Session Info shows only with Debug Settings `agent.inspector` on (off by default), and
// once trust is decided the trust bar is gone. The chat menu (…), in every chat, keeps the way back:
// Revoke Granted Access names each grant, and picking one revokes it.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { chatAccessGrants, revokeAccessRows } from "../src/agent-session/acpmux/header/grantsMenu";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { configureQuickActions } from "../src/agent-session/acpmux/header/quickActions";
import { translate } from "../src/agent-session/acpmux/i18n";
import { resetSessionInfoState } from "../src/agent-session/acpmux/session-info/sessionInfoState";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  // Debug Settings `agent.inspector` at its default: off, so Session Info never shows.
  setHeaderState({ inspector: false });
  class FakeResizeObserver {
    observe() {}
    disconnect() {}
  }
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: FakeResizeObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetSessionInfoState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetSessionInfoState();
  configureQuickActions({});
  setHeaderState({ inspector: false });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const noop = () => undefined;

/// The App's grants for a chat whose folder trust was decided (trusted) and that holds no allowance.
function decidedTrust(untrust: () => void) {
  return chatAccessGrants({
    trusted: true,
    trustLabel: "Trusted atlas",
    untrust,
    chatAllowance: false,
    allowanceUnread: false,
    revokeAllowance: noop,
  });
}

const items = (container: HTMLElement) =>
  [...container.ownerDocument.querySelectorAll<HTMLElement>('[role="menuitem"]')].map((item) => item.textContent);

test("with Session Info off and a decided trust grant, the chat menu revokes it", async () => {
  const container = installDom();
  let untrusted = 0;
  const grants = decidedTrust(() => untrusted++);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ChatHeaderTools
        onTerminal={noop}
        onBrowser={noop}
        summary={null}
        menu={() => [
          { key: "rename", label: "Rename", icon: "action.edit", onSelect: noop },
          "separator",
          ...revokeAccessRows(grants),
        ]}
      />,
    );
  });
  const document = container.ownerDocument;
  // Session Info is off: nothing else on screen lists the grant.
  expect(document.querySelector("aside.acpmux-session-info")).toBeNull();
  expect(document.querySelector("[data-grant]")).toBeNull();

  const menuButton = [...container.querySelectorAll<HTMLElement>("button")].find(
    (button) => button.getAttribute("aria-label") === translate("chatMenu.open"),
  )!;
  expect(menuButton).toBeDefined();
  await act(async () => menuButton.click());
  await act(async () => undefined);
  const revoke = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === translate("chatMenu.revokeAccess"),
  );
  expect(items(container)).toContain(translate("chatMenu.revokeAccess"));
  expect(revoke).toBeDefined();

  // Its submenu names the grant; picking it revokes the trust.
  await act(async () => {
    revoke!.focus();
    revoke!.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  });
  await act(async () => undefined);
  const grant = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === "Trusted atlas",
  );
  expect(grant).toBeDefined();
  await act(async () => grant!.click());
  expect(untrusted).toBe(1);
});

test("the chat menu has no Revoke Granted Access row when nothing is granted", () => {
  const none = chatAccessGrants({
    trusted: false,
    untrust: noop,
    chatAllowance: false,
    allowanceUnread: false,
    revokeAllowance: noop,
  });
  expect(revokeAccessRows(none)).toEqual([]);
});

test("each grant is its own submenu row, and an unread allowance is not revoked yet", () => {
  const calls: string[] = [];
  const grants = (unread: boolean) =>
    chatAccessGrants({
      trusted: true,
      trustLabel: "Trusted atlas",
      untrust: () => calls.push("untrust"),
      chatAllowance: true,
      allowanceUnread: unread,
      revokeAllowance: () => calls.push("revoke"),
    });
  const [row] = revokeAccessRows(grants(false));
  expect(row?.label).toBe(translate("chatMenu.revokeAccess"));
  expect(row?.children?.map((child) => child.label)).toEqual(["Trusted atlas", translate("permission.allowChat")]);
  row?.children?.[1]?.onSelect();
  revokeAccessRows(grants(true))[0]?.children?.[1]?.onSelect();
  expect(calls).toEqual(["revoke"]);
});
