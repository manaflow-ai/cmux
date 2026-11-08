// A ```cmux-tour fence in a reply (conversation/Markdown.tsx): the tour card, with Start wired
// through the chat's TourStartContext (App.tsx). A fence that is not a tour draws as code.
import { createContext, useContext } from "react";
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

export function TourBlock({ lang, code, open }: { lang: string; code: string; open: boolean }) {
  const onStart = useContext(TourStartContext);
  return <TourCard tour={open ? undefined : parseTour(lang, code)} onStart={onStart} />;
}
