import { categoryById, type CategoryCard } from "../categories";
import { text, t } from "../strings";
import { GroupList } from "./GroupList";
import { APPEARANCE_CATEGORIES } from "../appearanceUndo";
import { AppearanceBar } from "./AppearanceBar";
import { DENSITY_CARD_ROWS } from "../density";
import { SectionActions } from "./SectionActions";
import {
  ACCENT_KEY,
  APP_THEME_KEY,
  BACKDROP_ROWS,
  CHIEF_PET_ROWS,
  CHIEFS_ROWS,
  COMPUTER_USE_ROWS,
  FAVORITE_THEMES_KEY,
  HIGHLIGHT_COLOR_KEY,
  MACHINE_COLORS_KEY,
  ROTATE_FAVORITES_KEY,
  SPACE_ROWS,
  THEME_EDITS_KEY,
  THEME_FILE_KEY,
  THEME_KEY,
  useBackdropsShown,
  useSeveralSpaces,
  SELECTION_KEY,
  DOCTOR_NOTICE_KEY,
} from "../cardRows";
import { arrangeGroups } from "../rowLevels";
import { Card } from "./cardModules";
import { LinkMissing, useLinkLanding } from "./LinkLanding";

/** One category: its title, the cards before its groups, the groups, the cards after, actions. */
export function SectionView({
  section,
  focus,
  workspace = null,
  reveal = null,
  target = null,
  targetRequired = false,
  missing = null,
}: {
  section: string;
  focus: string | null;
  workspace?: string | null;
  /** The card the route opens the page on (`#/settings/machines`), else null. */
  reveal?: CategoryCard | null;
  /** The element the link lands on and highlights (settingsLinks.ts), else null. */
  target?: string | null;
  /** The target's absence is a miss (a connection the host does not draw). */
  targetRequired?: boolean;
  /** The part of the link nothing matched, named at the top of the page. */
  missing?: string | null;
}) {
  const absent = useLinkLanding(target, targetRequired);
  const unmatched = missing ?? (absent && target ? linkName(target) : null);
  const category = categoryById(section);
  // The theme studio draws appearance.theme, appearance.appTheme, appearance.accent,
  // appearance.selection, appearance.highlightColor, appearance.rotateFavoriteThemes,
  // appearance.themeFile and customize.doctorNotice itself; the schema's group for them would draw each a second time (a second
  // "App Theme" card).
  const studio = category.lead.includes("themeStudio");
  const drawn = new Set(
    studio
      ? [
          THEME_KEY,
          APP_THEME_KEY,
          ACCENT_KEY,
          SELECTION_KEY,
          HIGHLIGHT_COLOR_KEY,
          ROTATE_FAVORITES_KEY,
          THEME_FILE_KEY,
          DOCTOR_NOTICE_KEY,
        ]
      : [],
  );
  // The background picker draws appearance.background and its Opacity while it shows.
  const picker = useBackdropsShown() && [...category.lead, ...category.trail].includes("backdrops");
  // The Chief Pet card draws home.chiefPetEnabled and home.chiefPetMascot.
  const pet = category.lead.includes("chiefPet");
  // The Chiefs card draws its Engine row (home.chiefEngine).
  const chiefsCard = [...category.lead, ...category.trail].includes("chiefs");
  // The density card draws appearance.density, the custom density keys and Text Size.
  const densityCard = [...category.lead, ...category.trail].includes("density");
  // The Computer Use card draws every computerUse.* row (mode, denied apps, switches) itself.
  const computerUseCard = [...category.lead, ...category.trail].includes("computerUse");
  // The Machines card draws appearance.machineColors: a color well on each machine's row.
  const machinesCard = [...category.lead, ...category.trail].includes("machines");
  // With one space no row names spaces (Hide Spaces); a second space brings them back.
  const severalSpaces = useSeveralSpaces();
  // appearance.themeEdits is the pickers' "(custom)" themes and appearance.favoriteThemes their
  // stars, never rows of their own.
  const groups = category.groups
    .map((group) => ({
      ...group,
      rows: group.rows.filter(
        (row) =>
          row.key !== THEME_EDITS_KEY &&
          row.key !== FAVORITE_THEMES_KEY &&
          !drawn.has(row.key) &&
          !(picker && BACKDROP_ROWS.has(row.key)) &&
          !(pet && CHIEF_PET_ROWS.has(row.key)) &&
          !(chiefsCard && CHIEFS_ROWS.has(row.key)) &&
          !(machinesCard && row.key === MACHINE_COLORS_KEY) &&
          !(!severalSpaces && SPACE_ROWS.has(row.key)) &&
          !(computerUseCard && COMPUTER_USE_ROWS.has(row.key)) &&
          !(densityCard && DENSITY_CARD_ROWS.has(row.key)),
      ),
    }))
    .filter((group) => group.rows.length > 0);
  // Each row's level and the merged cards (rowLevels.ts).
  const cards = arrangeGroups(category.id, groups, focus);
  return (
    <div className="section" data-section={category.id}>
      <h1 className="section-title">{text(category.title)}</h1>
      {unmatched && <LinkMissing name={unmatched} />}
      {category.lead.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} reveal={reveal === card} />
      ))}
      {cards.length > 0 && (
        <GroupList
          groups={cards}
          focus={focus}
          pageTitle={text(category.title)}
          groupHelp={
            category.id === "cloud"
              ? { "settings.group.cloudWorkspaces": t("settingsWindow.cloud.workspaces.help") }
              : undefined
          }
        />
      )}
      {category.trail.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} reveal={reveal === card} />
      ))}
      {category.actions.map((id) => (
        <SectionActions key={id} section={id} />
      ))}
      {APPEARANCE_CATEGORIES.includes(category.id) && <AppearanceBar section={category.id} />}
    </div>
  );
}

/** One card, loaded with its section (cardModules.tsx). */
function CardSlot(props: { card: CategoryCard; focus: string | null; workspace: string | null; reveal: boolean }) {
  // `display: contents`: no box of its own, so the page's layout is unchanged; a deep link finds the
  // card by it (settingsLinks.ts), whether or not the card marks itself.
  return (
    <div className="card-slot" data-card-slot={props.card}>
      <Card {...props} />
    </div>
  );
}

/** The name a target selector asked for (`[data-hub-connection="linear"]` is "linear"). */
function linkName(target: string): string {
  return /="([^"]+)"/.exec(target)?.[1] ?? target;
}
