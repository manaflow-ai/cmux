import { useEffect, useSyncExternalStore } from "react";
import { APPEARANCE_CATEGORIES } from "../appearanceUndo";
import {
  ACCENT_KEY,
  APP_THEME_KEY,
  BACKDROP_ROWS,
  CHIEF_PET_ROWS,
  MACHINE_COLORS_KEY,
  THEME_EDITS_KEY,
  THEME_KEY,
  useBackdropsShown,
} from "../cardRows";
import { categoryById, type CategoryCard } from "../categories";
import { useSectionLoader } from "../context";
import { DENSITY_ROWS } from "../density";
import { text } from "../strings";
import { AppearanceBar } from "./AppearanceBar";
import { GroupList } from "./GroupList";
import { SectionActions } from "./SectionActions";

/** One category: its title, the cards before its groups, the groups, the cards after, actions. */
export function SectionView({
  section,
  focus,
  workspace = null,
}: {
  section: string;
  focus: string | null;
  workspace?: string | null;
}) {
  const category = categoryById(section);
  // The theme studio draws appearance.theme, appearance.appTheme and appearance.accent itself; the
  // schema's group for them would draw each a second time (a second "App Theme" card).
  const studio = category.lead.includes("themeStudio");
  const drawn = new Set(studio ? [THEME_KEY, APP_THEME_KEY, ACCENT_KEY] : []);
  // The background picker draws appearance.background and its Opacity while it shows.
  const picker = useBackdropsShown() && [...category.lead, ...category.trail].includes("backdrops");
  // The Chief Pet card draws home.chiefPetEnabled and home.chiefPetMascot.
  const pet = category.lead.includes("chiefPet");
  // The density card draws appearance.density and the custom density keys.
  const densityCard = [...category.lead, ...category.trail].includes("density");
  // The Machines card draws appearance.machineColors: a color well on each machine's row.
  const machinesCard = [...category.lead, ...category.trail].includes("machines");
  // appearance.themeEdits is the pickers' "(custom)" themes, never a row of its own.
  const groups = category.groups
    .map((group) => ({
      ...group,
      rows: group.rows.filter(
        (row) =>
          row.key !== THEME_EDITS_KEY &&
          !drawn.has(row.key) &&
          !(picker && BACKDROP_ROWS.has(row.key)) &&
          !(pet && CHIEF_PET_ROWS.has(row.key)) &&
          !(machinesCard && row.key === MACHINE_COLORS_KEY) &&
          !(densityCard && DENSITY_ROWS.has(row.key)),
      ),
    }))
    .filter((group) => group.rows.length > 0);
  return (
    <div className="section" data-section={category.id}>
      <h1 className="section-title">{text(category.title)}</h1>
      {category.lead.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} />
      ))}
      {groups.length > 0 && <GroupList groups={groups} focus={focus} />}
      {category.trail.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} />
      ))}
      {category.actions.map((id) => (
        <SectionActions key={id} section={id} />
      ))}
      {APPEARANCE_CATEGORIES.includes(category.id) && <AppearanceBar />}
    </div>
  );
}

/** A card, drawn from its section's chunk (lazySections.ts). The section route's loader has loaded
 * the chunk; a section drawn before it (the route's pending component) adds the card when it loads. */
function CardSlot({ card, focus, workspace }: { card: CategoryCard; focus: string | null; workspace: string | null }) {
  const sections = useSectionLoader();
  const draw = useSyncExternalStore(sections.subscribe, () => sections.card(card));
  useEffect(() => {
    if (!draw) void sections.loadCard(card);
  }, [draw, sections, card]);
  return draw ? draw(focus, workspace) : null;
}
