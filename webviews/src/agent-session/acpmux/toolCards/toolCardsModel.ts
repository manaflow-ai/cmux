import { type NoticeKind } from "../../../ui/Notice";
import type { ToolCard } from "./toolCardStore";

/// The notice kind of a card's state: an ask asks, a stopped run is an error, the rest are status.
export function toolCardKind(state: ToolCard["state"]): NoticeKind {
  return state === "ask" ? "ask" : state === "failed" ? "error" : "toast";
}
