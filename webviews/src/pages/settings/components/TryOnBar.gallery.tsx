// l10n-allow-file: gallery fixtures (sample try-ons), not shipped UI.
// The try-on bar's looks, side by side for the pick (rulebook: more than two versions). From the
// cmux-design-references: an inline Undo / Keep beside the change with no card, and a small banner
// of one quiet line with one action.
// Shipped: `row`. It sits on the page's own hairline like the read-only banner, so Settings keeps
// one surface (no gray card in the content, the folder-tab join), and its meter is the hairline
// itself running down to the revert, which says "this goes away by itself" without a word.
// `card` reads as a warning and pushes every setting down by a card's padding; `pill` floats
// centered and is the easiest to miss on a wide page, where the eye starts at the left edge.
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import type { CustomizeTryOn } from "../ops";
import type { TryOnLook } from "./TryOnBar";

type Props = { look: TryOnLook; leftMs: number; label: string };

const MINUTE = 60_000;

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { TryOnBar } = await import("./TryOnBar");
  return function TryOnLooks({ look, leftMs, label }: Props) {
    const tryOn: CustomizeTryOn = {
      generation: 7,
      revert_to: 6,
      started_ms: GALLERY_NOW - (10 * MINUTE - leftMs),
      expires_ms: GALLERY_NOW + leftMs,
      label,
      origin: "cli",
    };
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <TryOnBar tryOn={tryOn} now={GALLERY_NOW} look={look} onKeep={() => {}} onRevert={() => {}} />
        <h2 className="result-section-title">Appearance</h2>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.try-on-bar",
  title: "Try on: Keep / Revert Now",
  area: "Settings",
  height: 160,
  widths: { narrow: 420, normal: 720, wide: 980 },
  covers: ["pages/settings/components/TryOnBar.tsx#TryOnBar"],
  load,
  styles: () => import("../page.css"),
  variants: {
    row: {
      note: "Shipped: one line on the page's hairline; the hairline runs down to the revert.",
      props: { look: "row", leftMs: 7 * MINUTE + 42_000, label: "profile night" },
    },
    card: {
      note: "A bordered card with a fill: louder, and every setting moves down.",
      props: { look: "card", leftMs: 7 * MINUTE + 42_000, label: "profile night" },
    },
    pill: {
      note: "A centered pill: compact, easy to miss on a wide page.",
      props: { look: "pill", leftMs: 7 * MINUTE + 42_000, label: "profile night" },
    },
    "row-last-seconds": {
      note: "Shipped look, 9 seconds left: the meter is nearly gone.",
      props: { look: "row", leftMs: 9_000, label: "profile night" },
    },
    "row-long-ask": {
      note: "Shipped look with a long ask: the label truncates, the time and buttons stay.",
      props: {
        look: "row",
        leftMs: 3 * MINUTE,
        label: "make the sidebar compact, add a PR widget under History and use a darker theme at night",
      },
    },
  },
});
