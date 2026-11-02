// The pane's Needs you wiring (App.tsx): the list from the snapshot, the header badge's actions,
// and the transcript's Needs your input pill, which share one list and one way to answer.
import { useMemo, useRef } from "react";
import { revealTurnWhenShown } from "../links";
import type { AcpmuxSnapshot } from "../model";
import { reply, replyParams, selection } from "../question/model";
import { nextAsk, needsYouPillOn, pillAsks, type TranscriptNeedsYou } from "./JumpPill";
import { needsYouItems, type NeedsYouAnswer, type NeedsYouItem } from "./model";
import { needsYouMode, type NeedsYouActions, type NeedsYouMode } from "./NeedsYou";

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
}): { mode: NeedsYouMode; items: NeedsYouItem[]; actions: NeedsYouActions; pill?: TranscriptNeedsYou } {
  const mode = needsYouMode();
  const pillOn = needsYouPillOn();
  const { sessions, asks, sessionId, rows, queue, queueApproval } = snapshot;
  const items = useMemo(
    () =>
      mode === "off" && !pillOn
        ? []
        : needsYouItems({
            sessions,
            asks: asks ?? [],
            open: { ...(sessionId ? { sessionId } : {}), rows, queue, queueApproval },
          }),
    [mode, pillOn, sessions, asks, sessionId, rows, queue, queueApproval],
  );
  /// Another chat's ask: the app shows that chat's tab or opens it in this chat's side pane on the
  /// right (`chat.asks.open`, AgentPaneAskOpen). Never `chat.select`, which replaced the chat on
  /// screen in its own tab (Leo 2026-10-21). A host that opens none leaves this chat as it is.
  const openElsewhere = (item: NeedsYouItem) => {
    // Peer sessions stay in the header list; they are not local chats that this pane can open.
    const target = sessions.find((session) => session.sessionId === item.sessionId);
    if (target?.peer) return Promise.resolve();
    return callNative("chat.asks.open", { sessionId: item.sessionId }).catch(() => undefined);
  };
  const goTo = (item: NeedsYouItem) => {
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
      // The pane may answer only a chat it shows (the relay's session scope and answers rule), so
      // another chat's ask opens that chat on the side, answered there; the row stays here.
      if (item.sessionId !== sessionId && item.kind !== "held") {
        await openElsewhere(item);
        throw new Error();
      }
      return callNative(call.method, call.params);
    },
    goTo,
    ask: async (item, question) => {
      // `_acpmux/btw` is session scoped like an answer: another chat's ask opens that chat on the
      // side, asked about there.
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
        const target = sessions.find((session) => session.sessionId === item.sessionId);
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
  return { mode, items, actions, ...(pill ? { pill } : {}) };
}
