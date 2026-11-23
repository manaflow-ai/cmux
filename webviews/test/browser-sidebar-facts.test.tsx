// l10n-allow-file: test fixture chat titles, hosts and folders, not shipped UI.
// The browser sidebar cuts a chat's title with an ellipsis and does not show its machine or folder.
// They show on the row's hover card, not in a `title` tooltip: a tooltip is one line and names only a
// control that shows no text (Chief, 2026-11-21, after the tooltip cuts: "Information sighted users
// lost must still show somewhere visible").
import { afterEach, expect, test } from "bun:test";
import { BrowserSidebar } from "../src/agent-session/acpmux/browser/BrowserSidebar";
import type { BrowserWorkspaces } from "../src/agent-session/acpmux/browser/workspaces";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { factsCardText, renderInDom } from "./support/factsCard";

const session: AcpmuxSessionEntry = {
  sessionId: "s-1",
  title: "Fix the retry banner in the payments service",
  harness: "claude",
  peer: "cmux-lawrence-2",
  cwd: "/Users/you/fun/cmux-worktrees/payments-service/apps/checkout",
};
const workspaces: BrowserWorkspaces = {
  available: true,
  registryId: "r-1",
  workspaces: [
    {
      id: "w-1",
      name: "payments",
      title: "Payments service checkout rewrite",
      chats: [
        { tabId: "t-1", local: false, title: "Review the checkout flow", host: "cmux-lawrence-3", harness: "codex" },
      ],
    },
  ],
};
let close: (() => Promise<void>) | undefined;

afterEach(async () => {
  await close?.();
  close = undefined;
});

async function sidebar(): Promise<HTMLElement> {
  const page = await renderInDom(<BrowserSidebar sessions={[session]} workspaces={workspaces} onSelect={() => {}} />);
  close = page.close;
  return page.container;
}

test("a session row shows its whole title, machine and folder on its hover card, with no title tooltip", async () => {
  const container = await sidebar();
  const row = container.querySelector<HTMLElement>('button[data-chat="s-1"]')!;
  expect(row.hasAttribute("title")).toBe(false);
  expect(await factsCardText(row)).toBe(`${session.title}${session.peer}${session.cwd}`);
});

test("another machine's chat shows its whole title and its machine on its hover card", async () => {
  const container = await sidebar();
  const chat = container.querySelector<HTMLButtonElement>('button[data-tab="t-1"]')!;
  expect(chat.hasAttribute("title")).toBe(false);
  // It cannot open here, but it still takes hover and focus: a disabled button gets neither.
  expect(chat.disabled).toBe(false);
  expect(chat.getAttribute("aria-disabled")).toBe("true");
  expect(await factsCardText(chat)).toBe("Review the checkout flowcmux-lawrence-3");
});

test("a workspace heading shows its whole title and its name on its hover card, with no title tooltip", async () => {
  const container = await sidebar();
  const summary = container.querySelector<HTMLElement>("details[data-workspace='w-1'] > summary")!;
  expect(summary.textContent).toBe("Payments service checkout rewrite");
  expect(summary.hasAttribute("title")).toBe(false);
  expect(await factsCardText(summary)).toBe("Payments service checkout rewritepayments");
});
