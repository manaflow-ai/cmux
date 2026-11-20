import { useRouterState } from "@tanstack/react-router";
import { Button } from "../../../ui/Button";
import { categoryById, type CategoryGroup } from "../categories";
import { useSettingsRouter } from "../context";
import { FOCUS_PREFIX, PERSONALIZATION_PARTS, type Part, type PartID } from "../personalizationParts";
import { sectionHref } from "../router";
import { rowsByKey } from "../schema";
import { t, text } from "../strings";
import { ChiefPetCard } from "./ChiefPetCard";
import { DensityCard } from "./DensityCard";
import { GroupList } from "./GroupList";
import { BACKDROP_ROWS, Backdrops, useBackdropsShown } from "./HostCards";
import { ThemeStudio } from "./ThemeStudio";

export function PersonalizationCard({
  part: id,
  focus,
  workspace,
}: {
  part: PartID;
  focus: string | null;
  workspace: string | null;
}) {
  const router = useSettingsRouter();
  const picker = useBackdropsShown();
  const part = PERSONALIZATION_PARTS.find((part) => part.id === id)!;
  const key = focus?.startsWith(FOCUS_PREFIX) ? null : focus;
  // The host adds a fresh `open` token for each Change Background… request. Reveal the saved tile
  // again even when the Background panel is already open.
  const search = useRouterState({ router, select: (state) => state.location.searchStr });
  const open = new URLSearchParams(search).get("open");
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
                key={JSON.stringify([workspace, open])}
                focus={focus === `${FOCUS_PREFIX}background` ? "appearance.background" : key}
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
    <div className="personalization" data-card="personalization">
      <section className="personalization-part" data-part={id} aria-labelledby={`personalization-${id}`}>
        <header className="personalization-part-header">
          <h1 className="section-title" id={`personalization-${id}`}>
            {t(`settingsPage.personalization.${id}`)}
          </h1>
          {part.homes.length > 0 && (
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
          )}
        </header>
        {body(part)}
      </section>
    </div>
  );
}
