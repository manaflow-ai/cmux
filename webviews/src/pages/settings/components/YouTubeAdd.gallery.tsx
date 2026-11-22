// l10n-allow-file: gallery fixtures (a sample link and picture), not shipped UI.
// Add YouTube Video… in Moving wallpapers, three ways to lay out the form:
// - card: the link's thumbnail beside the link, Start, End and Quality.
// - stacked: the thumbnail above the fields.
// - inline: a small thumbnail and every field on one row.
// Shipped: card, because the thumbnail confirms the video at the size of the picker's tiles while the
// fields stay one short column, and its height is the same empty, filled or refused; stacked spends a
// thumbnail's height before the link field, and inline wraps unevenly in a narrow window.
import { componentEntry } from "../../../gallery/format";
import { YouTubeAdd, type YouTubeAddDesign } from "./YouTubeAdd";

/** A public-safe stand-in for a video's thumbnail: rain over a city at night. */
const SAMPLE_THUMB =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="480" height="270"><rect width="480" height="270" fill="#1d2433"/><rect y="150" width="480" height="120" fill="#2b3550"/><g fill="#f2c46d"><rect x="40" y="110" width="50" height="160"/><rect x="120" y="80" width="70" height="190"/><rect x="230" y="125" width="60" height="145"/><rect x="330" y="95" width="80" height="175"/></g><g stroke="#9fb3d9" stroke-width="2" opacity="0.5"><path d="M30 10l-12 40M110 30l-12 40M200 0l-12 40M290 20l-12 40M380 5l-12 40M450 35l-12 40"/></g></svg>',
  );

type Props = { design: YouTubeAddDesign; initial?: { link?: string; start?: string; end?: string; quality?: number } };

function YouTubeAddFixture({ design, initial }: Props) {
  return (
    <section className="settings-page" style={{ padding: 16 }}>
      <section className="group" data-card="backdrop">
        <div className="backdrop-group" data-collection="video">
          <h4 className="row-help backdrop-group-title">Moving wallpapers</h4>
          <YouTubeAdd
            design={design}
            initial={initial}
            thumbSrc={() => SAMPLE_THUMB}
            onChoose={() => undefined}
            onClose={() => undefined}
          />
        </div>
      </section>
    </section>
  );
}

const filled = { link: "https://www.youtube.com/watch?v=aaaaaaaaaaa&t=1m30s", end: "4:00", quality: 1440 };

export default componentEntry<Props>({
  id: "settings.youtube-add",
  title: "Background: Add YouTube Video",
  area: "Settings",
  height: 260,
  widths: { narrow: 420, normal: 680 },
  covers: ["pages/settings/components/YouTubeAdd.tsx#YouTubeAdd"],
  load: async () => {
    // The form's labels come from the Settings catalog, which this component host does not load.
    const { installCatalog } = await import("../strings");
    installCatalog((await import("../generated/strings.json")).default);
    return YouTubeAddFixture;
  },
  styles: () => import("../page.css"),
  variants: {
    "card-empty": {
      note: "Shipped: before a link, an empty 16:9 box holds the thumbnail's place.",
      props: { design: "card" },
    },
    "card-filled": {
      note: "Shipped: a pasted link with t=1m30s (Start shows it), an End and 1440p.",
      props: { design: "card", initial: filled },
    },
    "card-refused": {
      note: "Shipped: End before Start says why; the form keeps its height.",
      props: { design: "card", initial: { ...filled, start: "5:00" } },
    },
    "stacked-filled": { note: "The thumbnail above the fields.", props: { design: "stacked", initial: filled } },
    "inline-filled": { note: "Everything on one row.", props: { design: "inline", initial: filled } },
  },
});
