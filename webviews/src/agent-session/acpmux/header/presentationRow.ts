import type { Translate } from "../i18n";
import { defaultPresentation, type Presentation } from "../chatDisplay";
import {
  hasOwnPresentation,
  makePresentationDefault,
  presentationOf,
  setPresentation,
} from "../conversation/presentation";
import type { ChatMenuChild } from "./ChatHeaderTools";
import { transcriptViewRow } from "./transcriptViewRow";

/** Add presentation to the existing submenu, leaving the top-level chat menu its same height. */
export function presentationRow(sessionId: string | undefined, t: Translate, more: readonly ChatMenuChild[] = []) {
  const row = transcriptViewRow(sessionId, t, more);
  if (!sessionId || !row) return row;
  const presentation = presentationOf(sessionId);
  const name = (value: Presentation) => t(`chatMenu.presentation.${value}`);
  return {
    ...row,
    children: [
      ...(["transcript", "messages"] as const).map((value) => ({
        key: `presentation.${value}`,
        label: name(value),
        checked: presentation === value,
        onSelect: () => setPresentation(sessionId, value),
      })),
      {
        key: "presentation.default",
        label: t("chatMenu.transcriptView.makeDefault", { view: name(presentation) }),
        disabled: presentation === defaultPresentation() && !hasOwnPresentation(sessionId),
        onSelect: () => makePresentationDefault(sessionId, presentation),
      },
      ...(row.children ?? []).map((child, index) => ({
        ...child,
        ...(index === 0 ? { separatorBefore: true } : {}),
        ...(child.key.startsWith("transcriptView.") && presentation === "messages" ? { disabled: true } : {}),
      })),
    ],
  };
}
