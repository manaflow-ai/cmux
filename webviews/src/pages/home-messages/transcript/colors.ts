// The bubbles' colours (HomeThemePalette.swift and HomeBubbleColors): a look over the theme, then the
// chat's own colours (Chat Colors, `home.bubbleColors.*`: sent, sentText, received, receivedText)
// over it. A colour the chat leaves unset keeps the look's. Text set to automatic reads on its
// bubble (white or black, as `HomeColor.readableText` picks).
import type { CSSProperties } from "react";

/** The bubbles' look: iMessage's (the default; Leo 2026-10-19: "the founders like the imessage apple
 * blue"), the theme's accent and surface, or a quiet outlined one for incoming. */
export type BubbleLook = "imessage" | "theme" | "outline";

export const BUBBLE_LOOKS: readonly BubbleLook[] = ["imessage", "theme", "outline"];

/** One chat's chosen colours, `#RRGGBB`; absent keeps the look's. */
export interface ChatColors {
  sent?: string;
  sentText?: string;
  received?: string;
  receivedText?: string;
}

const HEX = /^#([0-9a-f]{6})$/i;

/** sRGB relative luminance of `#RRGGBB` (undefined for anything else). */
export function luminance(hex: string): number | undefined {
  const match = HEX.exec(hex.trim());
  if (!match) return undefined;
  const value = Number.parseInt(match[1]!, 16);
  const channel = (shift: number) => {
    const c = ((value >> shift) & 255) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
}

/** The text that reads on a bubble of `hex`: white on a dark one, black on a light one. */
export function readableText(hex: string): string | undefined {
  const l = luminance(hex);
  if (l === undefined) return undefined;
  // HomePalette.readableText: white once it reads at 3:1 (Messages' blue keeps white text), else
  // whichever contrasts more.
  const onWhite = 1.05 / (l + 0.05);
  const onBlack = (l + 0.05) / 0.05;
  return onWhite >= 3 || onWhite >= onBlack ? "#ffffff" : "#000000";
}

/** The CSS variables the bubbles draw with: the chat's colours over the look's defaults (transcript.css). */
export function bubbleStyle(colors: ChatColors | undefined): CSSProperties {
  const style: Record<string, string> = {};
  const valid = (hex: string | undefined) => (hex && HEX.test(hex.trim()) ? hex.trim() : undefined);
  const sent = valid(colors?.sent);
  const received = valid(colors?.received);
  if (sent) style["--mt-sent"] = sent;
  if (received) style["--mt-received"] = received;
  const sentText = valid(colors?.sentText) ?? (sent ? readableText(sent) : undefined);
  const receivedText = valid(colors?.receivedText) ?? (received ? readableText(received) : undefined);
  if (sentText) style["--mt-sent-text"] = sentText;
  if (receivedText) style["--mt-received-text"] = receivedText;
  return style as CSSProperties;
}
