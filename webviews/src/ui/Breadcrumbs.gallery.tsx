// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Breadcrumbs, type Crumb } from "./Breadcrumbs";

const DEFAULT_CRUMBS: Crumb[] = [
  { label: "Home", path: "/" },
  { label: "Projects", path: "/projects" },
  { label: "cmux", path: "/projects/cmux" },
  { label: "webviews", path: "/projects/cmux/webviews" },
];

const LONG_CRUMBS: Crumb[] = [
  { label: "Home", path: "/" },
  { label: "Projects", path: "/projects" },
  { label: "Manaflow", path: "/projects/manaflow" },
  { label: "cmux", path: "/projects/manaflow/cmux" },
  { label: "feat-cmux-next", path: "/projects/manaflow/cmux/feat-cmux-next" },
  { label: "webviews", path: "/projects/manaflow/cmux/feat-cmux-next/webviews" },
];

type Props = {
  long?: boolean;
  separator?: "chevron" | "slash";
};

function BreadcrumbsGallery({ long = false, separator = "chevron" }: Props) {
  const crumbs = long ? LONG_CRUMBS : DEFAULT_CRUMBS;
  return (
    <div className="breadcrumbs-gallery-stage">
      <div className="breadcrumbs-gallery-copy">
        <strong>Current location</strong>
        <span>Choose an ancestor without adding another tab stop to the path field.</span>
      </div>
      <Breadcrumbs
        label="Project path"
        crumbs={crumbs}
        className="breadcrumbs-gallery"
        crumbClassName="breadcrumbs-gallery-crumb"
        separator={(index) => (
          <span className="breadcrumbs-gallery-separator" aria-hidden="true">
            {separator === "chevron" ? "›" : "/"}
            <span className="ui-sr-only">Level {index}</span>
          </span>
        )}
        onNavigate={(crumb) => {
          const receipt = document.querySelector<HTMLOutputElement>("[data-testid='breadcrumbs-gallery-receipt']");
          if (receipt) receipt.textContent = `Navigated to ${crumb.path}`;
        }}
      />
      <output className="breadcrumbs-gallery-receipt" data-testid="breadcrumbs-gallery-receipt" aria-live="polite">
        Ready
      </output>
    </div>
  );
}

const navigateAncestor: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Projects" });
  await ctx.waitFor(() => ctx.find({ testId: "breadcrumbs-gallery-receipt" }).textContent === "Navigated to /projects");
};

const navigateRoot: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Home" });
  await ctx.waitFor(() => ctx.find({ testId: "breadcrumbs-gallery-receipt" }).textContent === "Navigated to /");
};

const currentSemantics: Play = async (ctx) => {
  await ctx.waitFor(() => {
    const current = ctx.document.querySelector('[aria-current="location"]');
    return current?.textContent?.trim() === "webviews";
  });
};

export default componentEntry<Props>({
  id: "ui.breadcrumbs",
  title: "Breadcrumbs",
  area: "UI primitives",
  height: 280,
  widths: { narrow: 360, normal: 560, wide: 820 },
  anchors: [{ selector: ".breadcrumbs-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Navigating to an ancestor must not move the receipt anchor." },
    longFrameFailMs: {
      value: 33,
      reason: "Breadcrumb navigation and current-state updates should stay within two display frames.",
    },
    settleMaxMs: { value: 250, reason: "Breadcrumb navigation is a local interaction." },
  },
  covers: ["ui/Breadcrumbs.tsx#Breadcrumbs"],
  load: async () => BreadcrumbsGallery,
  styles: () => Promise.all([import("./ui.css"), import("./Breadcrumbs.gallery.css")]),
  variants: {
    initial: { props: {} },
    "ancestor-click": { props: {}, play: navigateAncestor },
    "root-click": { props: {}, play: navigateRoot },
    "current-semantics": { props: {}, play: currentSemantics },
    "long-path": { props: { long: true }, play: navigateAncestor },
    slash: { props: { separator: "slash" }, play: navigateRoot },
  },
});
