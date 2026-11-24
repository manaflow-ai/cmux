// A ```cmux-tour fence in a reply (conversation/Markdown.tsx): the tour card, with Start wired
// through the chat's TourStartContext (App.tsx). A fence that is not a tour draws as code.
import { useContext } from "react";
import { useMessageScope } from "../chips/messageScope";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { TourStartContext } from "./tourBlockModel";
import { TourCard } from "./TourCard";
import { parseTour } from "./tourModel";

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
