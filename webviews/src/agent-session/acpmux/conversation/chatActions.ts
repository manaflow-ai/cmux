// Message actions (`cmux.chat.action/1`): the rows installed extensions add to a message's menu.
// The daemon decides which there are for a prompt and for a reply (cmux-tui-core
// apps/chat_actions.rs, `apps.chat_actions.list`, through the page host's
// `cmux.apps.panels.chatActions`); this file only keeps its answer, lists it again when the
// installed apps change, and adds the rows to the message's menu report (messageMenu.ts). The
// pane's native menu draws them and sends the pick to the daemon (`apps-chat-action`). With no
// extension listing any, the report carries nothing and the menu is as it was.
import { useSyncExternalStore } from "react";
import type { PageClient } from "../../../pages/shared/pageClient";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { pageHostClient } from "../pageHost";
import { ComposerContributions } from "../composer/extensionCommands";
import type { MessageMenuTarget } from "./messageMenu";

export type ChatActionRole = "user" | "assistant";

/// One row of the menu: the extension's app id and its action's id, title and SF Symbol.
export type ChatActionRow = { app: string; id: string; title: string; symbol?: string };

/// What the menu report carries: the message the menu opened on, and its rows.
export type ChatActionsReport = {
  message: { id: string; role: ChatActionRole; text: string; session?: string };
  rows: ChatActionRow[];
};

/// The rows in an `apps.chat_actions.list` reply; an entry without an app, an id or a title is dropped.
export function chatActionRowsFrom(reply: unknown): ChatActionRow[] {
  const actions = (reply as { actions?: unknown } | null)?.actions;
  if (!Array.isArray(actions)) return [];
  const rows: ChatActionRow[] = [];
  for (const entry of actions) {
    if (!entry || typeof entry !== "object") continue;
    const { app, id, title, symbol } = entry as Record<string, unknown>;
    if (typeof app !== "string" || !app || typeof id !== "string" || !id || typeof title !== "string" || !title)
      continue;
    rows.push({ app, id, title, ...(typeof symbol === "string" && symbol && { symbol }) });
  }
  return rows;
}

/// The menu report's `chatActions` for a message of `role`, or undefined when no extension lists one.
export function chatActionsReport(
  rows: readonly ChatActionRow[],
  message: ChatActionsReport["message"],
): ChatActionsReport | undefined {
  return rows.length ? { message, rows: [...rows] } : undefined;
}

/// `target` with the message's extension rows, unchanged when there are none.
export function withChatActions(
  target: MessageMenuTarget | undefined,
  message: ChatActionsReport["message"] | undefined,
  rows: (role: ChatActionRole) => readonly ChatActionRow[],
): MessageMenuTarget | undefined {
  if (!target || !message) return target;
  const report = chatActionsReport(rows(message.role), message);
  return report ? { ...target, chatActions: report } : target;
}

const owners = new WeakMap<PageClient, Record<ChatActionRole, ComposerContributions>>();

function listsFor(client: PageClient): Record<ChatActionRole, ComposerContributions> {
  const existing = owners.get(client);
  if (existing) return existing;
  const lists = {
    user: new ComposerContributions(client, "cmux.apps.panels.chatActions", { role: "user" }),
    assistant: new ComposerContributions(client, "cmux.apps.panels.chatActions", { role: "assistant" }),
  };
  owners.set(client, lists);
  return lists;
}

const noSubscribe = () => () => undefined;
const nothing = () => null;

/// The message actions for prompts and for replies, kept current while the page shows a chat.
/// The menu reads them when it opens, so a save of an extension's manifest changes the next menu.
export function useChatActionRows(
  injectedClient?: PageClient | null,
): (role: ChatActionRole) => readonly ChatActionRow[] {
  const client = injectedClient === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injectedClient;
  const lists = client ? listsFor(client) : undefined;
  const user = useSyncExternalStore(
    lists?.user.subscribe ?? noSubscribe,
    lists?.user.getSnapshot ?? nothing,
    lists?.user.getSnapshot ?? nothing,
  );
  const assistant = useSyncExternalStore(
    lists?.assistant.subscribe ?? noSubscribe,
    lists?.assistant.getSnapshot ?? nothing,
    lists?.assistant.getSnapshot ?? nothing,
  );
  const userRows = chatActionRowsFrom(user);
  const assistantRows = chatActionRowsFrom(assistant);
  return (role) => (role === "user" ? userRows : assistantRows);
}
