// A ```cmux-tour fence in a reply (conversation/Markdown.tsx): the tour card, with Start wired
// through the chat's TourStartContext (App.tsx). A fence that is not a tour draws as code.
import { createContext, useContext } from "react";
import { useMessageScope } from "../chips/messageScope";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { TourCard, type StartTourTask } from "./TourCard";
import { parseTour, TOUR_FENCE } from "./tourModel";

/// The chat's task Start (App.tsx `chat.tour.start`); none in a read-only or remote transcript.
export const TourStartContext = createContext<StartTourTask | undefined>(undefined);

/// Whether a fence is a tour: a streaming one always is (it draws as the card's pending line), a
/// closed one only when its JSON reads as a tour.
export function isTourFence(lang: string, code: string, open: boolean): boolean {
  if (lang.trim().toLowerCase() !== TOUR_FENCE) return false;
  return open || parseTour(lang, code) !== undefined;
}

/// Start only on this chat's own reply: a tour inside another agent's message (on this Mac or a
/// peer, conversation/IncomingMessageCard.tsx) or in a read-only transcript reads without it, so
/// no other agent's words become a task here.
export function TourBlock({ lang, code, open }: { lang: string; code: string; open: boolean }) {
  const start = useContext(TourStartContext);
  const scope = useMessageScope();
  const readOnly = useTranscriptReadOnly();
  const onStart = scope === null && !readOnly ? start : undefined;
  return <TourCard tour={open ? undefined : parseTour(lang, code)} onStart={onStart} />;
}
