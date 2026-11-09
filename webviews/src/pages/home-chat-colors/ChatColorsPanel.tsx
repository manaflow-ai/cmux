// Chat Colors: one chat's bubble and text colours, with a live preview (design/home.md "Chat
// Colors"). It draws only the state the host last sent: a pick goes to the host, which stores it and
// streams the new state back, so a change from the CLI while the panel is open redraws it the same
// way. The layout has fixed heights, so the preview and every row keep their place while you pick
// and only colours change.
import type { CSSProperties } from "react";
import type { Strings } from "../shared/i18n";
import { DialogButton } from "../../ui/DialogButton";
import { cx } from "../../ui/cx";
import {
  hasOwnColors,
  normalizeHex,
  RECEIVED_SWATCHES,
  SENT_SWATCHES,
  TEXT_SWATCHES,
  type ChatColorRole,
  type ChatColorsPair,
  type ChatColorsState,
} from "./host";

/** The layouts the gallery compares (`home.chat-colors`); the app draws `rows`, the AppKit panel's. */
export type ChatColorsLook = "rows" | "caption-labels" | "grouped";

export interface ChatColorsPanelProps {
  readonly strings: Strings;
  /** The host's last state; null before the first one (the controls draw with no colours yet). */
  readonly state: ChatColorsState | null;
  readonly look?: ChatColorsLook;
  /** A swatch: the role's colour, or null for Default (bubble) or Automatic (text). */
  readonly onPick: (role: ChatColorRole, color: string | null) => void;
  readonly onCustom: (role: ChatColorRole) => void;
  readonly onReset: () => void;
  readonly onDone: () => void;
}

const EMPTY_PAIR: ChatColorsPair = { fill: "transparent", text: "currentColor" };

export function ChatColorsPanel({
  strings,
  state,
  look = "rows",
  onPick,
  onCustom,
  onReset,
  onDone,
}: ChatColorsPanelProps) {
  const preview = state?.preview;
  const t = (key: string) => strings.t(`home.chatColors.${key}`);
  const section = (side: "mine" | "theirs") => {
    const fill: ChatColorRole = side === "mine" ? "sent" : "received";
    const text: ChatColorRole = side === "mine" ? "sentText" : "receivedText";
    const pair = (side === "mine" ? preview?.sent : preview?.received) ?? EMPTY_PAIR;
    return (
      <section className="cc-section" aria-labelledby={`cc-${side}`}>
        <h2 id={`cc-${side}`} className="cc-heading">
          {t(side)}
        </h2>
        <SwatchRow
          label={t("bubble")}
          role={fill}
          choices={side === "mine" ? SENT_SWATCHES : RECEIVED_SWATCHES}
          none={{ name: t("default"), glyph: "default" }}
          current={pair.fill}
          {...{ state, strings, onPick, onCustom }}
        />
        <SwatchRow
          label={t("text")}
          role={text}
          choices={TEXT_SWATCHES}
          none={{ name: t("automatic"), glyph: "automatic" }}
          current={pair.text}
          {...{ state, strings, onPick, onCustom }}
        />
      </section>
    );
  };
  return (
    <div className="cc-panel" data-look={look}>
      <figure
        className="cc-preview"
        aria-label={t("preview")}
        style={{ background: preview?.background ?? "transparent" }}
      >
        <Bubble side="received" text={t("sample.received")} pair={preview?.received ?? EMPTY_PAIR} />
        <Bubble side="sent" text={t("sample.sent")} pair={preview?.sent ?? EMPTY_PAIR} />
      </figure>
      {section("mine")}
      {section("theirs")}
      <div className="cc-buttons">
        <DialogButton dialogKey={null} className="cc-button" disabled={!hasOwnColors(state)} onClick={onReset}>
          {t("reset")}
        </DialogButton>
        <DialogButton dialogKey="return" className="cc-button cc-done" onClick={onDone}>
          {t("done")}
        </DialogButton>
      </div>
    </div>
  );
}

function Bubble({ side, text, pair }: { side: "sent" | "received"; text: string; pair: ChatColorsPair }) {
  return (
    <div className={cx("cc-bubble", `cc-bubble-${side}`)} style={{ background: pair.fill, color: pair.text }}>
      {text}
    </div>
  );
}

interface SwatchRowProps {
  readonly label: string;
  readonly role: ChatColorRole;
  readonly choices: readonly string[];
  /** The first swatch, which clears the role: Default (a slashed circle) or Automatic (a text glyph). */
  readonly none: { name: string; glyph: "default" | "automatic" };
  /** The colour the role draws with now (the custom colour's well shows it). */
  readonly current: string;
  readonly state: ChatColorsState | null;
  readonly strings: Strings;
  readonly onPick: (role: ChatColorRole, color: string | null) => void;
  readonly onCustom: (role: ChatColorRole) => void;
}

function SwatchRow({ label, role, choices, none, current, state, strings, onPick, onCustom }: SwatchRowProps) {
  const stored = normalizeHex(state?.colors[role]);
  const custom = strings.t("home.chatColors.custom");
  return (
    <div className="cc-row">
      <span className="cc-row-label">{label}</span>
      <div className="cc-swatches">
        <Swatch
          name={none.name}
          color={null}
          glyph={none.glyph}
          selected={state !== null && stored === null}
          onPress={() => onPick(role, null)}
        />
        {choices.map((color) => (
          <Swatch
            key={color}
            name={color}
            color={color}
            selected={stored === color}
            onPress={() => onPick(role, color)}
          />
        ))}
        <button
          type="button"
          className="cc-well"
          aria-label={custom}
          title={custom}
          style={{ "--cc-well": stored ?? current } as CSSProperties}
          onClick={() => onCustom(role)}
        />
      </div>
    </div>
  );
}

interface SwatchProps {
  readonly name: string;
  readonly color: string | null;
  readonly glyph?: "default" | "automatic";
  readonly selected: boolean;
  readonly onPress: () => void;
}

/** A colour swatch; a null colour is Default or Automatic. Selected draws the accent ring outside it. */
function Swatch({ name, color, glyph, selected, onPress }: SwatchProps) {
  return (
    <button
      type="button"
      className={cx("cc-swatch", color === null && "cc-swatch-none")}
      aria-label={name}
      aria-pressed={selected}
      title={name}
      data-color={color ?? undefined}
      style={color ? { background: color } : undefined}
      onClick={onPress}
    >
      {color === null && glyph === "default" && (
        <svg viewBox="0 0 18 18" aria-hidden="true">
          <line x1="5" y1="13" x2="13" y2="5" />
        </svg>
      )}
      {color === null && glyph === "automatic" && (
        <svg viewBox="0 0 18 18" aria-hidden="true">
          <path d="M5.5 12.5 9 5l3.5 7.5M6.8 10h4.4" />
        </svg>
      )}
    </button>
  );
}
