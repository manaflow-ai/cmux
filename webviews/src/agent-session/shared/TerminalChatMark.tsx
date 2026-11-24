// Four ways a list row could tell a terminal agent chat (a Pty tab running an agent) from a GUI agent
// chat (a Conversation tab), drawn for comparison only: nothing ships them and no surface imports this
// file but its gallery (TerminalChatMark.gallery.tsx). Leo, 2026-11-24: "terminal agent chats. can they
// be demarcated a bit differently/should they? than gui agent chats. both of them rn are just claude
// icon. but one is terminal one is gui. should we do anything? how? a small subscript symbol? but
// wouldn't that look kinda dingleberry-esque?"
//
// Every form keeps the harness's own mark (AgentMark) and draws the terminal sign around it:
// - label: the mark unchanged; the row's second line starts with the word (`terminalChatDetail`).
// - tile: the mark in the terminal's foreground on a rounded square in the terminal's background
//   (WebTheme.swift `terminal.background` / `.foreground`, which the page has as `--cmux-surface-token`
//   and `--cmux-text`), filling the slot the bare mark takes. Corner: min(8, floor4(side / 3)).
//   `tileStyle` picks the tile's colours: `surface` (the terminal's background token; in the default themes
//   it equals the sidebar's ground, so the tile shows only on a selected row), `ink` (a solid tile of the
//   row's primary text ink, the mark knocked out in the row's ground; it inverts with the theme) or
//   `black` (the terminal's black, ANSI 0, in both themes, the mark in the terminal's foreground, a 1 px
//   inner hairline in the separator colour so it keeps its edge on a dark sidebar).
// - chevron: a monospace prompt chevron before the mark.
// - badge: the icon pack's `terminal` glyph on a cutout plate at the slot's bottom-right corner.
import type { CSSProperties } from "react";
import { Icon } from "../acpmux/icons/Icon";
import { AgentMark } from "./AgentMark";

export type TerminalChatMarkVariant = "label" | "tile" | "chevron" | "badge";
export type TerminalTileStyle = "surface" | "ink" | "black";

/// The `black` tile's colours. The page's theme has no ANSI palette variables today; the gallery sets these
/// two from the default terminal theme (Apple System Colors: ANSI 0 #1a1a1a, ANSI 15 #ffffff). Without them
/// the tile falls back to the terminal background token and the text ink.
export const TERMINAL_BLACK = "var(--cmux-terminal-ansi-0, var(--cmux-surface-token, var(--cmux-surface-background)))";
export const TERMINAL_BLACK_INK = "var(--cmux-terminal-ansi-15, var(--cmux-text))";

export type TerminalChatMarkProps = {
  agent?: string;
  /** The mark's side in px (16 in a Mac sidebar row, 14 in the web chat history, 20 on iOS). */
  size?: number;
  /** The square the mark sits in (iOS's 32 frame); the mark's own side when omitted. */
  slot?: number;
  variant: TerminalChatMarkVariant;
  /** A GUI chat: the bare mark in its slot, whatever the variant. */
  terminal?: boolean;
  /** Passed to AgentMark: the mark in the text colour (the sidebar rows), else brand colours (iOS). */
  tint?: boolean;
  onDark?: boolean;
  /** The colour under the row (its fill when selected), for the badge's cutout ring. */
  ground?: string;
  /** The tile's colours (the `tile` variant only); `surface` when omitted. */
  tileStyle?: TerminalTileStyle;
};

/// The tile's corner for a square of `side` px: the design scale's control corner rule, min(8, floor4(side / 3)):
/// 4 on a 14 or 16 square, 8 on a 32 one.
export function terminalTileRadius(side: number): number {
  return Math.min(8, Math.max(2, Math.floor(side / 3 / 4) * 4));
}

/// The mark's side on a tile of `side`: the largest icon-scale size (12, 16, 20) that leaves 2 px of tile on each
/// side, else the tile less 4 px (a 14 px web row's tile holds a 10 px mark).
export function terminalTileMarkSize(side: number): number {
  return [20, 16, 12].find((candidate) => candidate <= side - 4) ?? side - 4;
}

/// The badge plate's side for a slot of `slot`: 9 on a 14 or 16 slot, 14 on iOS's 32 frame. The glyph inside is the
/// plate less a 1 px cutout ring on each side.
export function terminalBadgeSide(slot: number): number {
  return Math.max(9, Math.round(slot * 0.44));
}

/// A terminal chat's second line under the label form: the word first, then what the line said already.
export function terminalChatDetail(word: string, detail?: string | null): string {
  return detail ? `${word} · ${detail}` : word;
}

export function TerminalChatMark({
  agent,
  size = 16,
  slot,
  variant,
  terminal = true,
  tint,
  onDark,
  ground,
  tileStyle = "surface",
}: TerminalChatMarkProps) {
  const side = slot ?? size;
  const box: CSSProperties = {
    position: "relative",
    display: "inline-flex",
    flex: "none",
    alignItems: "center",
    justifyContent: "center",
    width: side,
    height: side,
  };
  const bare = <AgentMark agent={agent} size={size} tint={tint} onDark={onDark} reserve />;
  if (!terminal || variant === "label") return <span style={box}>{bare}</span>;

  if (variant === "tile") {
    const colours: CSSProperties =
      tileStyle === "ink"
        ? { background: "var(--cmux-text)", color: ground ?? "var(--cmux-surface-background)" }
        : tileStyle === "black"
          ? {
              background: TERMINAL_BLACK,
              color: TERMINAL_BLACK_INK,
              boxShadow: "inset 0 0 0 1px var(--cmux-sidebar-line)",
            }
          : { background: "var(--cmux-surface-token, var(--cmux-surface-background))", color: "var(--cmux-text)" };
    return (
      <span
        data-terminal-chat="tile"
        data-tile-style={tileStyle}
        style={{ ...box, borderRadius: terminalTileRadius(side), ...colours }}
      >
        <AgentMark agent={agent} size={terminalTileMarkSize(side)} tint reserve />
      </span>
    );
  }

  if (variant === "chevron") {
    return (
      <span data-terminal-chat="chevron" style={{ display: "inline-flex", flex: "none", alignItems: "center", gap: 2 }}>
        <span
          aria-hidden="true"
          style={{
            fontFamily: 'var(--cv-mono-default, ui-monospace, "SF Mono", Menlo, monospace)',
            fontSize: size,
            lineHeight: `${side}px`,
            color: "var(--cmux-text-tertiary)",
          }}
        >
          ›
        </span>
        <span style={box}>{bare}</span>
      </span>
    );
  }

  // badge
  const plate = terminalBadgeSide(side);
  const overhang = slot && slot > size ? 0 : 2;
  return (
    <span data-terminal-chat="badge" style={box}>
      {bare}
      <span
        aria-hidden="true"
        style={{
          position: "absolute",
          right: -overhang,
          bottom: -overhang,
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          boxSizing: "border-box",
          width: plate,
          height: plate,
          borderRadius: terminalTileRadius(plate),
          background: ground ?? "var(--cmux-surface-background)",
          color: "var(--cmux-text)",
        }}
      >
        {/* The pack's Solid form: at 7 px the Line form's stroke is half a pixel. Sized by CSS, below Icon's
            12 px floor, which is what a subscript badge on a 16 px mark needs. */}
        <Icon name="terminal" selected row style={{ width: plate - 2, height: plate - 2 }} />
      </span>
    </span>
  );
}
