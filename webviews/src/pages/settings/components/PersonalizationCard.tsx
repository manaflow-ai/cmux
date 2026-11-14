// Settings > Personalization (Leo, 2026-11-07: the profile menu's "Personalization" is "a sort of
// like fast jump into the settings of the appearance section ... we can do a lot better"): every
// visual choice on one page, under a jump bar. Each part is the card or the rows its home category
// draws (the theme studio, the background picker, the Chief's look, chat text and density, sounds),
// so this page writes the same keys through the same store calls and holds no setting of its own.
import { useRouterState } from "@tanstack/react-router";
import { useEffect, useRef } from "react";
import { JumpBar } from "./JumpBar";
import { Button } from "../../../ui/Button";
import { categoryById, type CategoryGroup } from "../categories";
import { useSettingsRouter, useSettingsState } from "../context";
import {
  FOCUS_PREFIX,
  PERSONALIZATION_PARTS,
  personalizationPart,
  type Part,
  type PartID,
} from "../personalizationParts";
import { parseLocation, sectionHref } from "../router";
import { rowsByKey } from "../schema";
import { t, text } from "../strings";
import { ChiefPetCard } from "./ChiefPetCard";
import { DensityCard } from "./DensityCard";
import { GroupList } from "./GroupList";
import { BACKDROP_ROWS, Backdrops, useBackdropsShown } from "./HostCards";
import { useCurrentCard } from "../useCurrentCard";
import { ThemeStudio } from "./ThemeStudio";

export {
  PERSONALIZATION_KEYS,
  PERSONALIZATION_PARTS,
  personalizationPart,
  personalizationPartOf,
} from "../personalizationParts";

const PART_IDS: readonly PartID[] = PERSONALIZATION_PARTS.map((part) => part.id);

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
  // The jump bar's current part follows the scroll (useCurrentCard); a jump or a route's reveal
  // holds its part until the person scrolls.
  const root = useRef<HTMLDivElement>(null);
  const [current, pin] = useCurrentCard(root, PART_IDS, "part");
  // The part the route names, read from the route itself: its href changes a render before the
  // section's `focus`, and the two must name the same part when the reveal runs.
  const href = useRouterState({ router, select: (routerState) => routerState.location.href });
  const routeFocus = parseLocation(href).focus ?? focus;
  const opened = personalizationPart(routeFocus);
  // A search result's key: its row reveals itself and takes focus, as on any category page.
  const key = routeFocus && !routeFocus.startsWith(FOCUS_PREFIX) && opened ? routeFocus : null;
  // Each navigation reveals the part it names, once the owner's values and the host's lists arrive
  // (the parts above it have their height: the host adds the Theme part's override lines and the
  // Background part's picker, so a reveal before it landed ~180 px short as they grew above):
  // Change Background… (a new route each time, with `open`) and a jump alike.
  // A host that refused its lists still lets the reveal run: the page draws without them.
  const hostLoaded = state.hostSettled;
  const revealed = useRef<string | null>(null);
  useEffect(() => {
    if (!state.readable || !hostLoaded || opened === null || revealed.current === href) return;
    revealed.current = href;
    pin(opened);
    // The first part opens the page at its very top, with the page's title over it (Lucas
    // 2026-11-11: Theme must show "Personalization" too); the others scroll their title to the top.
    // A key's own row reveals itself (SettingRow), so the part does not scroll over it.
    const scroller = root.current?.closest<HTMLElement>(".content");
    const rows = parts.current.get(opened)?.querySelectorAll<HTMLElement>("[data-row-key]") ?? [];
    if (key && [...rows].some((row) => row.dataset.rowKey === key)) return;
    if (opened === PART_IDS[0] && scroller) scroller.scrollTo?.({ top: 0 });
    else parts.current.get(opened)?.scrollIntoView?.({ block: "start" });
  }, [href, opened, key, state.readable, hostLoaded, pin]);
  // A jump is the route's part (as a picked menu is Settings > Menus' focus), so the jump bar's
  // current part, Back and the host's next Change Background… all follow it.
  const jump = (id: PartID) => {
    pin(id);
    router.history.replace(sectionHref("personalization", `${FOCUS_PREFIX}${id}`, workspace));
  };
  const rowsOf = (part: Part): CategoryGroup[] => {
    const keys = part.id === "background" && picker ? part.rows.filter((key) => !BACKDROP_ROWS.has(key)) : part.rows;
    const rows = keys.map((key) => rowsByKey.get(key)).filter((row) => row !== undefined);
    return rows.length > 0 ? [{ key: `personalization.${part.id}`, title: { key: "", text: "" }, rows }] : [];
  };
  const body = (part: Part) => {
    switch (part.id) {
      case "theme":
        return <ThemeStudio focus={key} />;
      case "background":
        return (
          <>
            {picker && (
              <Backdrops
                focus={opened === "background" ? (key ?? "appearance.background") : null}
                workspace={workspace}
              />
            )}
            <GroupList groups={rowsOf(part)} focus={key} />
          </>
        );
      case "chief":
        return <ChiefPetCard focus={key} />;
      case "text":
        return (
          <>
            <DensityCard focus={key} />
            <GroupList groups={rowsOf(part)} focus={key} />
          </>
        );
      case "sounds":
        return <GroupList groups={rowsOf(part)} focus={key} />;
    }
  };
  return (
    <div className="personalization" data-card="personalization" ref={root}>
      <JumpBar
        items={PERSONALIZATION_PARTS.map((part) => ({ id: part.id, label: partTitle(part.id) }))}
        current={current}
        label={t("settingsPage.personalization.jump")}
        onJump={(id) => jump(id as PartID)}
      />
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
