// The pane's Needs you wiring (App.tsx): the list from the snapshot, the header badge's actions,
// and the transcript's Needs your input pill, which share one list and one way to answer.
import { useMemo, useRef } from "react";
import { revealTurnWhenShown } from "../links";
import type { AcpmuxSnapshot } from "../model";
import { reply, replyParams, selection } from "../question/model";
import { nextAsk, needsYouPillOn, type TranscriptNeedsYou } from "./JumpPill";
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
  if (item.kind === "held") return item.peer ? { method: "chat.agentPair.resume", params: { peer: item.peer } } : undefined;
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
  ask,
}: {
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "asks" | "sessionId" | "rows">;
  callNative: CallNative;
  ask: (question: string, sessionId: string) => Promise<string>;
}): { mode: NeedsYouMode; items: NeedsYouItem[]; actions: NeedsYouActions; pill?: TranscriptNeedsYou } {
  const mode = needsYouMode();
  const pillOn = needsYouPillOn();
  const { sessions, asks, sessionId, rows } = snapshot;
  const items = useMemo(
    () =>
      mode === "off" && !pillOn
        ? []
        : needsYouItems({ sessions, asks: asks ?? [], open: { ...(sessionId ? { sessionId } : {}), rows } }),
    [mode, pillOn, sessions, asks, sessionId, rows],
  );
  const goTo = (item: NeedsYouItem) => {
    const reveal = () => {
      if (item.turnId) void revealTurnWhenShown(item.turnId);
      else document.querySelector(item.kind === "held" ? ".cv-agent-pair" : ".acpmux-permission")?.scrollIntoView({ block: "nearest" });
    };
    if (item.sessionId === sessionId) return reveal();
    void callNative("chat.select", { sessionId: item.sessionId }).then(reveal, () => undefined);
  };
  const actions: NeedsYouActions = {
    answer: (item, choice) => {
      const call = answerParams(item, choice);
      return call ? callNative(call.method, call.params) : Promise.reject(new Error("unanswerable"));
    },
    goTo,
    ask: (item, question) => ask(question, item.sessionId),
  };
  // The last ask the pill went to, so the next press goes to the one after it.
  const last = useRef<string | undefined>(undefined);
  const elsewhere = items.filter((item) => item.sessionId !== sessionId).length;
  const pill: TranscriptNeedsYou | undefined =
    pillOn && items.length > 0
      ? {
          count: items.length,
          elsewhere,
          next: (behind) => {
            const item = nextAsk(items, sessionId, behind, last.current);
            if (!item) return;
            last.current = item.id;
            goTo(item);
          },
        }
      : undefined;
  return { mode, items, actions, ...(pill ? { pill } : {}) };
}
