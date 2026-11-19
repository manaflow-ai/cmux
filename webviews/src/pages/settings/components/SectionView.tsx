import { categoryById, type CategoryCard } from "../categories";
import { text } from "../strings";
import { GroupList } from "./GroupList";
import { APPEARANCE_CATEGORIES } from "../appearanceUndo";
import { AppearanceBar } from "./AppearanceBar";
import { DENSITY_CARD_ROWS } from "../density";
import { PERSONALIZATION_KEYS } from "../personalizationParts";
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
  THEME_EDITS_KEY,
  THEME_FILE_KEY,
  THEME_KEY,
  useBackdropsShown,
} from "../cardRows";
import { arrangeGroups } from "../rowLevels";
import { Card } from "./cardModules";

/** Every key Personalization draws: its one home on the page. */
// The density card there also draws Text Size and the custom densities (DENSITY_CARD_ROWS).
const HUB_KEYS: ReadonlySet<string> = new Set([...PERSONALIZATION_KEYS, ...DENSITY_CARD_ROWS]);

/** One category: its title, the cards before its groups, the groups, the cards after, actions. */
export function SectionView({
  section,
  focus,
  workspace = null,
  reveal = null,
}: {
  section: string;
  focus: string | null;
  workspace?: string | null;
  /** The card the route opens the page on (`#/settings/machines`), else null. */
  reveal?: CategoryCard | null;
}) {
  const category = categoryById(section);
  // The theme studio draws appearance.theme, appearance.appTheme, appearance.accent,
  // appearance.highlightColor, appearance.rotateFavoriteThemes and appearance.themeFile itself; the
  // schema's group for them would draw each a second time (a second "App Theme" card).
  // Personalization is the one home of what it draws (the theme studio among it): no other page
  // draws those rows, and it does not draw them a second time as rows under its parts.
  const hub = category.lead.includes("personalization");
  const studio = hub || category.lead.includes("themeStudio");
  const drawn = new Set(
    studio ? [THEME_KEY, APP_THEME_KEY, ACCENT_KEY, HIGHLIGHT_COLOR_KEY, ROTATE_FAVORITES_KEY, THEME_FILE_KEY] : [],
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
  // appearance.themeEdits is the pickers' "(custom)" themes and appearance.favoriteThemes their
  // stars, never rows of their own.
  const groups = category.groups
    .map((group) => ({
      ...group,
      rows: group.rows.filter(
        (row) =>
          row.key !== THEME_EDITS_KEY &&
          row.key !== FAVORITE_THEMES_KEY &&
          !HUB_KEYS.has(row.key) &&
          !drawn.has(row.key) &&
          !(picker && BACKDROP_ROWS.has(row.key)) &&
          !(pet && CHIEF_PET_ROWS.has(row.key)) &&
          !(chiefsCard && CHIEFS_ROWS.has(row.key)) &&
          !(machinesCard && row.key === MACHINE_COLORS_KEY) &&
          !(computerUseCard && COMPUTER_USE_ROWS.has(row.key)) &&
          !(densityCard && DENSITY_CARD_ROWS.has(row.key)),
      ),
    }))
    .filter((group) => group.rows.length > 0);
  // Each row's level and the merged cards (rowLevels.ts). Only Personalization has a jump bar (its own
  // card); a category page is short enough without one (Lucas 2026-11-11).
  const cards = arrangeGroups(category.id, groups, focus);
  return (
    <div className="section" data-section={category.id}>
      <h1 className="section-title">{text(category.title)}</h1>
      {category.lead.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} reveal={reveal === card} />
      ))}
      {cards.length > 0 && <GroupList groups={cards} focus={focus} pageTitle={text(category.title)} />}
      {category.trail.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} reveal={reveal === card} />
      ))}
      {category.actions.map((id) => (
        <SectionActions key={id} section={id} />
      ))}
      {APPEARANCE_CATEGORIES.includes(category.id) && <AppearanceBar />}
    </div>
  );
}

/** One card, loaded with its section (cardModules.tsx). */
function CardSlot(props: { card: CategoryCard; focus: string | null; workspace: string | null; reveal: boolean }) {
  return <Card {...props} />;
}
