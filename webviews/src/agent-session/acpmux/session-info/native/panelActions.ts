// Native chrome sends intents; the page keeps the same width, folds and section order as the web panel.
import { DEFAULT_ORDER, setSectionOrder } from "../sectionOrder";
import {
  SESSION_INFO_WIDTH,
  setSessionInfoOpen,
  setSessionInfoSection,
  setSessionInfoWidth,
  type SessionInfoSectionId,
} from "../sessionInfoState";
import type { NativeInfoSection } from "./model";

const known = (id: string): id is SessionInfoSectionId => DEFAULT_ORDER.includes(id as SessionInfoSectionId);

export function panelAction(id: string, sections: readonly NativeInfoSection[] = []): boolean {
  if (id === "close") {
    setSessionInfoOpen(false);
    return true;
  }
  if (id === "width:reset") {
    setSessionInfoWidth(SESSION_INFO_WIDTH.fallback);
    return true;
  }
  const width = /^width:(\d{1,4})$/.exec(id);
  if (width) {
    setSessionInfoWidth(Math.min(SESSION_INFO_WIDTH.max, Math.max(SESSION_INFO_WIDTH.min, Number(width[1]))));
    return true;
  }
  const fold = /^fold:([a-z]+):([01])$/.exec(id);
  if (fold && known(fold[1]!)) {
    setSessionInfoSection(fold[1], fold[2] === "1");
    return true;
  }
  const move = /^move:([a-z]+):([a-z]+)$/.exec(id);
  if (!move || !known(move[1]!)) return false;
  const shown = sections.filter((section) => section.reorderable).map((section) => section.id);
  const from = move[1] as SessionInfoSectionId;
  const before = move[2]!;
  if (!shown.includes(from) || (before !== "end" && !shown.includes(before as SessionInfoSectionId))) return false;
  if (from === before) return true;
  const next = shown.filter((section) => section !== from);
  next.splice(before === "end" ? next.length : next.indexOf(before as SessionInfoSectionId), 0, from);
  setSectionOrder(next);
  return true;
}
