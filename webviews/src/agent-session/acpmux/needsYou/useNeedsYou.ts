// The pane's Needs you wiring (App.tsx): the list from the snapshot, the header badge's actions,
// and the transcript's Needs your input pill, which share one list and one way to answer.
import { useMemo, useRef } from "react";
import { answerFromHome, replyElsewhere } from "../homeInboxModel";
import { revealTurnWhenShown } from "../links";
import type { AcpmuxSnapshot } from "../model";
import { reply, replyParams, selection, type QuestionReply } from "../question/model";
import { ATTENTION_OPEN_OP, useAttentionTabs } from "./attentionTabs";
import type { AttentionTab } from "./attentionTabs";
import { askContext } from "./context";
import { type TranscriptNeedsYou } from "./JumpPill";
import { nextAsk, needsYouPillOn, pillAsks } from "./jumpPillModel";
import { needsYouItems, type NeedsYouAnswer, type NeedsYouItem } from "./model";
import { findSession } from "../sessionIndex";
import { needsYouMode, type NeedsYouActions, type NeedsYouMode, type NeedsYouPlace } from "./needsYouModel";

type CallNative = <T>(method: string, params?: Record<string, unknown>) => Promise<T>;

/// What an answer sends: a held pair's Resume, a question's choice in its harness's shape, or a
/// permission's option. Every answer goes through the page's own `chat.permission` action, the
/// path the ask's card uses (its gesture ticket included), with the ask's chat named.
export function answerParams(
  item: NeedsYouItem,
  choice: NeedsYouAnswer,
): { method: string; params: Record<string, unknown> } | undefined {
  // A guest's held prompt is answered on its card only (Review goes there): nothing to send.
  if (item.kind === "held" && item.promptId) return undefined;
  if (item.kind === "held")
    return item.peer ? { method: "chat.agentPair.resume", params: { peer: item.peer } } : undefined;
  if (!item.permissionId) return undefined;
  if (item.question) {
    const first = item.question.items[0];
    if (!first) return undefined;
    const sent = reply(item.question, { selections: { [first.id]: selection([choice.id]) } });
    return { method: "chat.permission", params: replyParams(sent) };
  }
  return {
    method: "chat.permission",
    params: { sessionId: item.sessionId, permissionId: item.permissionId, optionId: choice.id },
  };
}

/// An answer to an ask of a chat this pane does not show: a tool permission's allow or deny once,
/// or a question's choice as its card sends it, the host answers on this click (`chat.asks.answer`,
/// AgentPaneAskAnswer: a chat on this Mac's acpmux only), else that chat opens, where its card
/// takes the answer ("opened"). Another computer's chat always opens. Needs you's rows, Waiting on
/// you (queue/QueueScreen.tsx) and the composer hat answer through this one path.
export async function answerAnotherChat(
  callNative: CallNative,
  item: NeedsYouItem,
  choice: NeedsYouAnswer,
  { peer, open }: { peer: boolean; open: () => unknown },
): Promise<"answered" | "opened"> {
  if (!answerParams(item, choice)) throw new Error("unanswerable");
  if (!peer) return answerFromHome(callNative, item, choice, () => void open());
  await open();
  return "opened";
}

export function useNeedsYou({
  snapshot,
  callNative,
  sideSession,
}: {
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "asks" | "sessionId" | "rows"> &
    Partial<Pick<AcpmuxSnapshot, "queue" | "queueApproval">>;
  callNative: CallNative;
  /// Opens a side session about chat `sessionId` with `question` (direct.ts `btw`, then the host's
  /// `chat.sideChat`); rejects when acpmux or the relay refused it.
  sideSession: (sessionId: string, question: string) => Promise<unknown>;
}): {
  mode: NeedsYouMode;
  items: NeedsYouItem[];
  actions: NeedsYouActions;
  attentionTabs: readonly AttentionTab[];
  pill?: TranscriptNeedsYou;
} {
  const mode = needsYouMode();
  const pillOn = needsYouPillOn();
  const { sessions, asks, sessionId, rows, queue, queueApproval } = snapshot;
  const tabs = useAttentionTabs();
  const items = useMemo(
    () =>
      mode === "off" && !pillOn
        ? []
        : needsYouItems({
            sessions,
            asks: asks ?? [],
            open: { ...(sessionId ? { sessionId } : {}), rows, queue, queueApproval },
            tabs,
          }),
    [mode, pillOn, sessions, asks, sessionId, rows, queue, queueApproval, tabs],
  );
  /// Another chat's ask: the app shows that chat's tab or opens it in this chat's side pane on the
  /// right (`chat.asks.open`, AgentPaneAskOpen). Never `chat.select`, which replaced the chat on
  /// screen in its own tab (Leo 2026-10-21). A host that opens none leaves this chat as it is.
  /// `place` other than the right (the default, sent as no `where` so an older host reads it the
  /// same) is the expanded row's pick: the workspace whose tab shows the chat, or a new workspace.
  const isPeer = (item: NeedsYouItem) =>
    sessions.some((session) => session.sessionId === item.sessionId && session.peer);
  const openElsewhere = (item: NeedsYouItem, place: NeedsYouPlace = "right") => {
    // Peer sessions stay in the header list; they are not local chats that this pane can open.
    if (isPeer(item)) return Promise.resolve();
    const where = place === "right" ? {} : { where: place };
    return callNative("chat.asks.open", { sessionId: item.sessionId, ...where }).catch(() => undefined);
  };
  const goTo = (item: NeedsYouItem) => {
    // A tab an agent marked: the app shows it as Search Tabs does.
    if (item.kind === "tab") {
      if (item.tabId) void callNative(ATTENTION_OPEN_OP, { tabId: item.tabId }).catch(() => undefined);
      return;
    }
    const reveal = () => {
      if (item.turnId) void revealTurnWhenShown(item.turnId);
      else if (item.promptId) {
        // The held card itself, focused, so Return approves it once the owner has read it.
        const card = [...document.querySelectorAll<HTMLElement>(".cv-held[data-held]")].find(
          (each) => each.getAttribute("data-queued-message") === item.promptId,
        );
        card?.scrollIntoView({ block: "center" });
        card?.focus({ preventScroll: true });
      } else
        document
          .querySelector(item.kind === "held" ? ".cv-agent-pair" : ".acpmux-permission")
          ?.scrollIntoView({ block: "nearest" });
    };
    if (item.sessionId === sessionId) return reveal();
    void openElsewhere(item);
  };
  const actions: NeedsYouActions = {
    answer: async (item, choice) => {
      // `reply` throws on an answer its question cannot take: a refusal, never a stuck row.
      const call = answerParams(item, choice);
      if (!call) throw new Error("unanswerable");
      // The pane may answer only a chat it shows (the relay's session scope and answers rule).
      // Another chat's tool permission is answered by the host on this click, as the home's inbox
      // answers it (`chat.asks.answer`, AgentPaneAskAnswer: allow once or deny once, a chat on this
      // Mac's acpmux only); a host that can't opens that chat, whose card answers it, and the row
      // stays. A question, or another computer's chat, opens the chat on the side.
      if (item.sessionId !== sessionId && item.kind !== "held") {
        const outcome = await answerAnotherChat(callNative, item, choice, {
          peer: isPeer(item),
          open: () => openElsewhere(item),
        });
        if (outcome === "answered") return;
        throw new Error();
      }
      return callNative(call.method, call.params);
    },
    reply: async (item: NeedsYouItem, sent: QuestionReply) => {
      // An expanded question's whole answer goes the way its card sends it: this chat's through the
      // relay; another chat's on this Mac through the host on this click (`replyElsewhere`), else
      // (another computer's, or a host that can't) that chat opens on the side, where its card
      // takes the answer, and the row stays.
      if (item.sessionId !== sessionId) {
        const outcome = isPeer(item)
          ? (await openElsewhere(item), "opened")
          : await replyElsewhere(callNative, sent, () => void openElsewhere(item));
        if (outcome === "answered") return;
        throw new Error();
      }
      return callNative("chat.permission", replyParams(sent));
    },
    context: (item: NeedsYouItem) => askContext(item, { ...(sessionId ? { sessionId } : {}), rows }, sessions),
    open: (item: NeedsYouItem, place: NeedsYouPlace) => void openElsewhere(item, place),
    opensElsewhere: (item: NeedsYouItem) => item.kind !== "tab" && item.sessionId !== sessionId && !isPeer(item),
    goTo,
    ask: async (item, question) => {
      // `_acpmux/btw` is session scoped like an answer: another chat's ask opens in that chat's
      // tab, asked about there. A marked tab names no chat.
      if (item.kind === "tab") throw new Error();
      if (item.sessionId !== sessionId) {
        await openElsewhere(item);
        throw new Error();
      }
      return sideSession(item.sessionId, question);
    },
  };
  // The last ask the pill went to, so the next press goes to the one after it.
  const last = useRef<string | undefined>(undefined);
  // The pill speaks for this chat and the chats it started only (JumpPill.tsx `pillAsks`); the
  // header's list keeps every ask. Peer and missing sessions remain header-only.
  const ours = useMemo(
    () =>
      (pillOn ? pillAsks(items, sessions, sessionId) : []).filter((item) => {
        const target = findSession(sessions, item.sessionId);
        if (target?.peer) return false;
        return item.sessionId === sessionId || target !== undefined;
      }),
    [pillOn, items, sessions, sessionId],
  );
  const elsewhere = ours.filter((item) => item.sessionId !== sessionId).length;
  const pill: TranscriptNeedsYou | undefined =
    pillOn && ours.length > 0
      ? {
          count: ours.length,
          elsewhere,
          next: (behind) => {
            const item = nextAsk(ours, sessionId, behind, last.current);
            if (!item) return;
            last.current = item.id;
            goTo(item);
          },
        }
      : undefined;
  return { mode, items, actions, attentionTabs: tabs, ...(pill ? { pill } : {}) };
}
