// The transcript's header (PaneHeaderView.swift, HomeHeaderPanelBar.swift and +Presence.swift): the
// conversation's avatar, its name in a glass pill under it (a click opens the conversation's
// details), who else has it open as faces beside the pill, and the top-right panel toggles. It lies
// over the top of the transcript, whose rows scroll under its backdrop. A section the host pins
// under it (Needs you) sits over the rows too, so showing it moves no message.
import type { CSSProperties, ReactNode } from "react";
import { Avatar } from "../../home-channels/Avatar";
import { HomeIcon } from "../../home-channels/icons";
import type { HomeParticipant } from "../../home-channels/types";
import type { Strings } from "../../shared/i18n";
import { initials } from "../../../ui/initials";

/** One top-right toggle (`HomeHeaderPanelItem`): a panel beside Home that it opens and closes. */
export interface HeaderPanelItem {
  /** Stable id: the button's test id suffix (`cmux.home.headerPanel.<id>`). */
  id: string;
  /** Its glyph (an SVG the host or the cards part draws). */
  icon: ReactNode;
  /** The localized name: its label and tooltip. */
  label: string;
  /** Its shortcut for the tooltip ("⌥⌘B"). */
  shortcut?: string;
  /** The panel is open: the toggle shows on (in the accent). */
  on: boolean;
}

export interface TranscriptHeaderProps {
  title: string;
  /** The participant the avatar shows (the other person, or the Chief); absent: the title's initials. */
  participant?: HomeParticipant;
  /** Names of the others who have the conversation open now (presence), already without me. */
  alsoHere?: readonly string[];
  panels?: readonly HeaderPanelItem[];
  onPanel?(id: string): void;
  onContact?(): void;
  strings: Strings;
}

/** Who else is here, by name (from the conversation's participants, else their id), in name order. */
export function alsoHereNames(
  viewing: readonly string[],
  participants: readonly HomeParticipant[],
  me: string,
  language: string,
): string[] {
  const others = new Set(viewing.filter((id) => id !== me));
  if (others.size === 0) return [];
  const names = new Map<string, string>();
  for (const person of participants) {
    const name = person.name.trim();
    if (others.has(person.id) && name && !names.has(person.id)) names.set(person.id, name);
  }
  const collator = new Intl.Collator(language, { numeric: true, sensitivity: "base" });
  return [...others].map((id) => names.get(id) ?? id).sort(collator.compare);
}

/** A face's colour: the name's hash on the hue wheel (one person keeps one colour). */
function faceHue(name: string): number {
  let hash = 0;
  for (const char of name) hash = (hash * 31 + char.codePointAt(0)!) >>> 0;
  return hash % 360;
}

export function TranscriptHeader({
  title,
  participant,
  alsoHere = [],
  panels = [],
  onPanel,
  onContact,
  strings,
}: TranscriptHeaderProps) {
  const list = new Intl.ListFormat(strings.language, { type: "conjunction" });
  return (
    <header className="mt-header">
      <div className="mt-header-center">
        <span className="mt-header-avatar" aria-hidden>
          {participant ? (
            <Avatar participant={participant} size={36} />
          ) : (
            <span className="mt-header-initials">{initials(title)}</span>
          )}
        </span>
        <span className="mt-header-line">
          <button
            type="button"
            className="mt-name-pill"
            aria-label={strings.format("header.contact", title)}
            onClick={onContact}
          >
            <span className="mt-name-text">{title}</span>
            <HomeIcon name="chevronRight" />
          </button>
          {alsoHere.length > 0 && (
            <span className="mt-faces">
              <span className="mt-sr">{strings.format("home.header.alsoHere", list.format(alsoHere))}</span>
              {alsoHere.map((name) => (
                <span
                  key={name}
                  className="mt-face"
                  aria-hidden
                  style={{ "--mt-face-hue": faceHue(name) } as CSSProperties}
                >
                  {initials(name).slice(0, 1)}
                </span>
              ))}
            </span>
          )}
        </span>
      </div>
      {panels.length > 0 && (
        <div className="mt-header-panels">
          {panels.map((item) => (
            <button
              key={item.id}
              type="button"
              className={`mt-panel-toggle${item.on ? " on" : ""}`}
              data-testid={`cmux.home.headerPanel.${item.id}`}
              aria-label={item.label}
              aria-pressed={item.on}
              title={item.shortcut ? `${item.label} (${item.shortcut})` : item.label}
              onClick={() => onPanel?.(item.id)}
            >
              {item.icon}
            </button>
          ))}
        </div>
      )}
    </header>
  );
}
