// A teammate's machine refused the chat start: the card offers Share with Me beside New Cloud
// Machine and Retry, one share button at a time (Leo rejects bloated cards). A share starts the
// chat again and resends the refused prompt (#29563); a refusal because only the creator or an admin shares turns the button into Ask the
// Owner, which copies a request naming the machine.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NativeError } from "./nativeError";
import { SwitchNotice } from "./SwitchNotice";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const buttons = (container: HTMLElement) => [...container.querySelectorAll("button")].map((b) => b.textContent);
const press = async (container: HTMLElement, name: string) => {
  const button = [...container.querySelectorAll("button")].find((b) => b.textContent === name);
  if (!button) throw new Error(`no ${name} in ${buttons(container).join(", ")}`);
  await act(async () => button.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true })));
};

const teamRefusal = {
  harness: "claude",
  name: "Claude Code",
  phase: "failed" as const,
  error: "build-box is a teammate's machine, so its owner starts chats there.",
  code: "agent_session.team_vm_blocked",
};

async function render(
  container: HTMLElement,
  call: () => Promise<unknown>,
  ran: string[],
  switching = teamRefusal,
  resends = true,
) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <SwitchNotice
        switching={switching}
        onRetry={() => ran.push("retry")}
        {...(resends && { onShared: () => ran.push("shared") })}
        onAction={(action) => ran.push(action)}
        share={{ machine: "build-box", call }}
      />,
    );
  });
}

test("a teammate's machine offers Share with Me, and a share resends the refused start", async () => {
  const container = installDom();
  const ran: string[] = [];
  await render(container, async () => ({ shared: true }), ran);
  expect(buttons(container)).toEqual(["Share with Me", "New Cloud Machine", "Retry"]);
  await press(container, "Share with Me");
  expect(ran).toEqual(["shared"]);
});

test("without a resend handler, a share falls back to a plain retry", async () => {
  const container = installDom();
  const ran: string[] = [];
  await render(container, async () => ({ shared: true }), ran, teamRefusal, false);
  await press(container, "Share with Me");
  expect(ran).toEqual(["retry"]);
});

test("only the creator or an admin shares: the button becomes Ask the Owner, which copies the request", async () => {
  const container = installDom();
  const ran: string[] = [];
  const copied: string[] = [];
  Object.defineProperty(dom!.window.navigator, "clipboard", {
    value: { writeText: async (text: string) => void copied.push(text) },
    configurable: true,
  });
  await render(
    container,
    async () => {
      throw new NativeError({ code: "vm_chat_share_forbidden", userMessage: "no" });
    },
    ran,
  );
  await press(container, "Share with Me");
  expect(buttons(container)).toEqual(["Ask the Owner", "New Cloud Machine", "Retry"]);
  expect(container.textContent).toContain("Only the machine's creator or a team admin can share it.");
  await press(container, "Ask the Owner");
  expect(copied).toHaveLength(1);
  expect(copied[0]).toContain("build-box");
  expect(container.textContent).toContain("Copied a request for the owner.");
  expect(ran).toEqual([]);
});

test("once the owner was asked, Retry looks for their share before it starts again", async () => {
  const container = installDom();
  const ran: string[] = [];
  let calls = 0;
  let shared = false;
  await render(
    container,
    async () => {
      calls += 1;
      if (!shared) throw new NativeError({ code: "vm_chat_share_forbidden" });
      return { shared: true };
    },
    ran,
  );
  await press(container, "Share with Me");
  shared = true;
  await press(container, "Retry");
  expect(calls).toBe(2);
  expect(ran).toEqual(["shared"]);
  expect(buttons(container)).toEqual(["Share with Me", "New Cloud Machine", "Retry"]);
});

test("once the owner was asked, Retry with no share yet is a plain retry", async () => {
  const container = installDom();
  const ran: string[] = [];
  let calls = 0;
  await render(
    container,
    async () => {
      calls += 1;
      throw new NativeError({ code: "vm_chat_share_forbidden" });
    },
    ran,
  );
  await press(container, "Share with Me");
  await press(container, "Retry");
  expect(calls).toBe(2);
  expect(ran).toEqual(["retry"]);
});

test("other refusals offer no share, and a new refusal starts over", async () => {
  const container = installDom();
  const ran: string[] = [];
  await render(container, async () => ({}), ran, { ...teamRefusal, code: "app.folder_needed", error: "no folder" });
  expect(buttons(container)).not.toContain("Share with Me");
  await render(container, async () => ({}), ran);
  expect(buttons(container)).toContain("Share with Me");
});
