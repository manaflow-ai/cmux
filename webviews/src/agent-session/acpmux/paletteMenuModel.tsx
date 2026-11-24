import React from "react";
import { Icon as CmuxIcon } from "./icons/Icon";
import type { ComposerPlusExtension } from "./composerPlusRegistry";
import { type Translate } from "./i18n";

export type PaletteChoice = {
  id: string;
  name: string;
  description?: string;
  icon?: React.ReactNode;
  hint?: string;
  keywords?: readonly string[];
  /** What Return does to this row, as a verb ("Open", "Run", "Switch to", "Ask Chief"); the row shows it when
   * highlighted under the `verb` and `footer` Return looks. Falls back to the section's verb. */
  verb?: string;
  /** The outcome with its target, read after the Return keycap ("opens “Fix the login bug” in this pane"), for the
   * `footer` look. */
  outcome?: string;
};

export type PaletteSection = {
  title: string;
  choices: PaletteChoice[];
  onPick?: (id: string) => void | "keep" | Promise<void | "keep">;
  /** Return's verb for every row in the section that names none of its own. */
  verb?: string;
};

/** How the highlighted row says what Return will do before Return (Beyer's P3, pushed past New Tab's ↩):
 * nothing (today), the Return keycap alone, the keycap with a verb, or the keycap and verb with the
 * whole outcome and its target in a quiet line under the list. */
export type PaletteReturnLook = "none" | "keycap" | "verb" | "footer";

// Words a description may add without saying more than the title: articles and the verbs every row means.
const RESTATING_WORDS = new Set(["a", "an", "the", "open", "new", "find", "search", "show", "start", "create"]);
const stem = (word: string) => (word.length > 3 && word.endsWith("s") ? word.slice(0, -1) : word);
const words = (text: string) =>
  text
    .toLocaleLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean)
    .map(stem);

/** A description that only restates its row's title ("New Browser Tab" / "Open a browser tab"): every word it
 * has is the title's or a word every row means. Such a line is narration (design/menus.md) and can go. */
export function descriptionRestatesName(name: string, description: string | undefined): boolean {
  if (!description) return false;
  const title = new Set(words(name));
  const said = words(description);
  return said.length > 0 && said.every((word) => title.has(word) || RESTATING_WORDS.has(word));
}

/** The tools and navigation exposed from the same native action catalog as Cmd-P. */
export function paletteSections(
  onAction: (id: string) => void | Promise<void>,
  t: Translate,
  extensions: readonly ComposerPlusExtension[] = [],
): PaletteSection[] {
  return (["tools", "apps", "sessions", "tabs"] as const).flatMap((section) => {
    const entries = extensions.filter((entry) => entry.section === section);
    return entries.length
      ? [
          {
            title: t(
              { tools: "plus.tools", apps: "plus.apps", sessions: "sidebar.sessions", tabs: "newTab.openTabs" }[
                section
              ] as Parameters<Translate>[0],
            ),
            choices: entries.map((entry) => ({
              id: entry.id,
              name: entry.name,
              description: entry.description,
              keywords: entry.keywords,
              icon: <CmuxIcon name={entry.icon} size={16} />,
            })),
            onPick: (id: string) => {
              const entry = entries.find((row) => row.id === id);
              if (entry?.action.kind !== "command") return "keep" as const;
              return onAction(entry.action.id);
            },
          },
        ]
      : [];
  });
}

export function filterPaletteSections(sections: readonly PaletteSection[], query: string): PaletteSection[] {
  const text = query.trim().toLocaleLowerCase();
  return sections
    .map((section) => ({
      ...section,
      choices: text
        ? section.choices.filter((choice) =>
            [choice.name, choice.description ?? "", ...(choice.keywords ?? [])]
              .join(" ")
              .toLocaleLowerCase()
              .includes(text),
          )
        : section.choices,
    }))
    .filter((section) => section.choices.length > 0);
}
