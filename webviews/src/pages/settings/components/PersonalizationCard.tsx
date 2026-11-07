// Settings > Personalization (Leo, 2026-11-07: the profile menu's "Personalization" is "a sort of
// like fast jump into the settings of the appearance section ... we can do a lot better"): every
// visual choice on one page, under a jump bar. Each part is the card or the rows its home category
// draws (the theme studio, the background picker, the Chief's look, chat text and density, sounds),
// so this page writes the same keys through the same store calls and holds no setting of its own.
import { useRouterState } from "@tanstack/react-router";
import { useEffect, useRef } from "react";
import { Button } from "../../../ui/Button";
import { categoryById, type CategoryGroup } from "../categories";
import { useSettingsRouter, useSettingsState } from "../context";
import { DENSITY_ROWS } from "../density";
import { parseLocation, sectionHref } from "../router";
import { rowsByKey } from "../schema";
import { t, text } from "../strings";
import { CHIEF_PET_ENABLED, CHIEF_PET_MASCOT, ChiefPetCard } from "./ChiefPetCard";
import { DensityCard } from "./DensityCard";
import { GroupList } from "./GroupList";
import { BACKDROP_ROWS, Backdrops, useBackdropsShown } from "./HostCards";
import { ACCENT_KEY, APP_THEME_KEY, THEME_KEY, ThemeStudio } from "./ThemeStudio";

/** A part of the page: its jump-bar id, the categories that are the homes of what it draws (each
 * gets a More in … link), the keys its cards draw and the schema rows drawn under them. */
type Part = { id: PartID; homes: readonly string[]; cardKeys: readonly string[]; rows: readonly string[] };
type PartID = "theme" | "background" | "chief" | "text" | "sounds";

/** The background rows the picker draws while it shows; without art they are rows of their own. */
const BACKGROUND_ROWS = [
  "appearance.background",
  "appearance.backgroundBlur",
  "appearance.backgroundOpacity",
  "appearance.paneBackgrounds",
  "appearance.backgroundRotation",
];

export const PERSONALIZATION_PARTS: readonly Part[] = [
  { id: "theme", homes: ["theme"], cardKeys: [THEME_KEY, APP_THEME_KEY, ACCENT_KEY], rows: [] },
  { id: "background", homes: ["appearance"], cardKeys: [...BACKDROP_ROWS], rows: BACKGROUND_ROWS },
  { id: "chief", homes: ["chief"], cardKeys: [CHIEF_PET_ENABLED, CHIEF_PET_MASCOT], rows: [] },
  {
    id: "text",
    // The density tiles are Appearance's; the chat text rows (Agents' whole Chat Text card) are Agents'.
    homes: ["appearance", "agents"],
    cardKeys: [...DENSITY_ROWS],
    rows: [
      "agentPane.display.font.ui",
      "agentPane.display.font.preset",
      "agentPane.display.font.size",
      "agentPane.display.font.lineHeight",
      "agentPane.display.code.family",
      "agentPane.display.code.scale",
      "agentPane.display.transcriptView",
    ],
  },
  {
    id: "sounds",
    homes: ["notifications"],
    cardKeys: [],
    rows: ["notifications.sound", "notifications.sounds.volume", "notifications.sounds.when"],
  },
];

/** Every key this page reads and writes: each one a row of its home category (personalization.test.ts). */
export const PERSONALIZATION_KEYS: readonly string[] = [
  ...new Set(PERSONALIZATION_PARTS.flatMap((part) => [...part.cardKeys, ...part.rows])),
];

const FOCUS_PREFIX = "personalization.";

/** `#/settings/personalization?focus=personalization.background` opens on that part (Change Background…). */
export function personalizationPart(focus: string | null): PartID | null {
  const id = focus?.startsWith(FOCUS_PREFIX) ? focus.slice(FOCUS_PREFIX.length) : null;
  return PERSONALIZATION_PARTS.some((part) => part.id === id) ? (id as PartID) : null;
}

const partTitle = (id: PartID) => t(`settingsPage.personalization.${id}`);

export function PersonalizationCard({
  focus = null,
  workspace = null,
}: {
  focus?: string | null;
  workspace?: string | null;
}) {
  const router = useSettingsRouter();
  const state = useSettingsState();
  const picker = useBackdropsShown();
  const parts = useRef(new Map<PartID, HTMLElement>());
  // The part the route names, read from the route itself: its href changes a render before the
  // section's `focus`, and the two must name the same part when the reveal runs.
  const href = useRouterState({ router, select: (routerState) => routerState.location.href });
  const opened = personalizationPart(parseLocation(href).focus ?? focus);
  // Each navigation reveals the part it names, once the owner's values arrive (the parts above it
  // have their height): Change Background… (a new route each time, with `open`) and a jump alike.
  const revealed = useRef<string | null>(null);
  useEffect(() => {
    if (!state.readable || opened === null || revealed.current === href) return;
    revealed.current = href;
    parts.current.get(opened)?.scrollIntoView?.({ block: "start" });
  }, [href, opened, state.readable]);
  // A jump is the route's part (as a picked menu is Settings > Menus' focus), so the jump bar's
  // current part, Back and the host's next Change Background… all follow it.
  const jump = (id: PartID) =>
    router.history.replace(sectionHref("personalization", `${FOCUS_PREFIX}${id}`, workspace));
  const rowsOf = (part: Part): CategoryGroup[] => {
    const keys = part.id === "background" && picker ? part.rows.filter((key) => !BACKDROP_ROWS.has(key)) : part.rows;
    const rows = keys.map((key) => rowsByKey.get(key)).filter((row) => row !== undefined);
    return rows.length > 0 ? [{ key: `personalization.${part.id}`, title: { key: "", text: "" }, rows }] : [];
  };
  const body = (part: Part) => {
    switch (part.id) {
      case "theme":
        return <ThemeStudio focus={null} />;
      case "background":
        return (
          <>
            {picker && (
              <Backdrops focus={opened === "background" ? "appearance.background" : null} workspace={workspace} />
            )}
            <GroupList groups={rowsOf(part)} />
          </>
        );
      case "chief":
        return <ChiefPetCard focus={null} />;
      case "text":
        return (
          <>
            <DensityCard />
            <GroupList groups={rowsOf(part)} />
          </>
        );
      case "sounds":
        return <GroupList groups={rowsOf(part)} />;
    }
  };
  return (
    <div className="personalization" data-card="personalization">
      <nav className="personalization-jump" aria-label={t("settingsPage.personalization.jump")}>
        {PERSONALIZATION_PARTS.map((part) => (
          <Button
            key={part.id}
            type="button"
            variant="ghost"
            className="button personalization-jump-link"
            data-jump={part.id}
            aria-current={opened === part.id ? "true" : undefined}
            onClick={() => jump(part.id)}
          >
            {partTitle(part.id)}
          </Button>
        ))}
      </nav>
      {PERSONALIZATION_PARTS.map((part) => (
        <section
          key={part.id}
          className="personalization-part"
          data-part={part.id}
          aria-labelledby={`personalization-${part.id}`}
          ref={(node) => void (node ? parts.current.set(part.id, node) : parts.current.delete(part.id))}
        >
          <header className="personalization-part-header">
            <h2 className="personalization-part-title" id={`personalization-${part.id}`}>
              {partTitle(part.id)}
            </h2>
            <span className="personalization-more-links">
              {part.homes.map((home) => (
                <Button
                  key={home}
                  type="button"
                  variant="ghost"
                  className="button personalization-more"
                  data-more={home}
                  onClick={() => router.history.push(sectionHref(home))}
                >
                  {t("settingsPage.personalization.more", text(categoryById(home).title))}
                </Button>
              ))}
            </span>
          </header>
          {body(part)}
        </section>
      ))}
    </div>
  );
}
