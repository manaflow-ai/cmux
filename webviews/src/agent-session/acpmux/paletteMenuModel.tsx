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
};

export type PaletteSection = {
  title: string;
  choices: PaletteChoice[];
  onPick?: (id: string) => void | "keep" | Promise<void | "keep">;
};

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
