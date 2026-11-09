// Gallery-only: a card drawn in one of the chat's Interface Fonts (chatUiFont.ts), with the row
// estimator's first height (cardHeight.ts) beside the height the card draws. cmux#38886 review:
// System UI and System UI, tight share a stack, as Inter and cmux Inter do, but not their tracking.
import { type CSSProperties, type RefObject, useLayoutEffect, useState } from "react";
import type { Play } from "../../../gallery/play";
import { setChatDisplay } from "../chatDisplay";
import { CHAT_UI_FONT_KEY, chatUiFontVariables, loadChatUiFont, type ChatUiFont } from "../chatUiFont";
import type { AcpmuxPermission } from "../model";
import { permissionCardHeight } from "./cardHeight";

/// The fonts that share a stack in pairs: each pair tracks differently.
export const PAIRED_UI_FONTS = ["system-ui", "system-ui-tight", "inter", "inter-tuned"] as const;

/// The page variables `font` sets, for the card's own root, and the caption's heights once the
/// face loaded and the card under `stack` drew.
export function useCardFont(
  font: ChatUiFont | undefined,
  permission: AcpmuxPermission | undefined,
  stack: RefObject<HTMLElement | null>,
): { style?: CSSProperties; caption?: string } {
  const [caption, setCaption] = useState<string>();
  useLayoutEffect(() => {
    if (!font) return;
    setChatDisplay({ [CHAT_UI_FONT_KEY]: font });
    const measure = () => {
      const card = stack.current?.firstElementChild as HTMLElement | null;
      if (!card) return;
      const estimate = Math.round(permissionCardHeight(permission, card.offsetWidth));
      setCaption(`${font}: estimate ${estimate} px, drawn ${card.offsetHeight} px`);
    };
    loadChatUiFont(font, () => void document.fonts.ready.then(measure));
    void document.fonts.ready.then(measure);
    return () => setChatDisplay({});
  }, [font, permission, stack]);
  if (!font) return {};
  const variables = Object.entries(chatUiFontVariables(font)).filter(([, value]) => value !== null);
  return { style: Object.fromEntries(variables) as CSSProperties, caption };
}

/// The caption under the card, once measured.
export const CardFontCaption = ({ caption }: { caption?: string }) =>
  caption ? (
    <p className="acpmux-muted" data-gallery-card-heights>
      {caption}
    </p>
  ) : null;

/// The stage waits for the caption: the face loaded and the card measured.
export const fontMeasured: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-gallery-card-heights]"));
};
