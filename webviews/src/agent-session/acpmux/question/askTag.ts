// The words an ask's tag chip shows: the hat's (HatQuestions.tsx) and the next-step card's
// (conversation/NextStepCard.tsx), one map so both chips read the same.
import type { StringKey } from "../i18n";
import { hatTag, type HatTag } from "./hatModel";

export const TAG_KEY: Record<HatTag, StringKey> = {
  taste: "hat.tag.taste",
  irreversible: "hat.tag.irreversible",
  outward: "hat.tag.outward",
  physical: "hat.tag.physical",
  "check-in": "hat.tag.checkIn",
  "for you": "hat.tag.forYou",
};

/// A tag chip's text: a known tag in the pane's words, any other word as the agent wrote it, capitalized ("Trust").
export function askTagText(tag: string, t: (key: StringKey) => string): string {
  const known = hatTag(tag);
  return known ? t(TAG_KEY[known]) : tag.charAt(0).toUpperCase() + tag.slice(1);
}
