// l10n-allow-file: gallery labels and paths are fixture content, not shipped UI.
import { useState, type ReactNode } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { UiProvider, type UiDirection } from "../ui/UiProvider";
import { EmptyState, RecentList } from "./EmptyState";
import type { RecentItem } from "./ops";
import { viewerEmptyStrings } from "./strings";

const HOME = "/Users/demo";
const PROJECTS = `${HOME}/Projects`;
const NOW = Date.parse("2026-10-13T12:00:00Z");

type Props = {
  state?: "empty" | "recents" | "loading" | "error";
  direction?: UiDirection;
};

const recents: RecentItem[] = [
  { path: `${PROJECTS}/cmux`, name: "cmux", openedAt: NOW - 4 * 60_000, source: "branch", branch: "feat-cmux-next" },
  { path: `${PROJECTS}/docs/README.md`, name: "README.md", openedAt: NOW - 2 * 60 * 60_000 },
];

function GalleryEmptyState({ state = "recents", direction = "ltr" }: Props) {
  const [container, setContainer] = useState<HTMLElement | null>(null);
  const [receipt, setReceipt] = useState("Ready");
  const strings = viewerEmptyStrings([direction === "rtl" ? "ar" : "en"]);
  const items = state === "empty" || state === "error" ? [] : state === "loading" ? null : recents;
  const error = state === "error" ? "Could not open README.md" : undefined;
  const children: ReactNode = (
    <>
      <div className="ve-actions">
        <button
          className="ve-button ve-button-primary ve-button-large"
          type="button"
          onClick={() => setReceipt("Choose folder")}
        >
          Choose folder
        </button>
        <button className="ve-button ve-button-quiet" type="button" onClick={() => setReceipt("Cancelled")}>
          Cancel
        </button>
      </div>
      <RecentList
        items={items}
        home={HOME}
        icon="repo"
        strings={strings}
        label="Recent repositories"
        emptyText="No recent repositories"
        now={NOW}
        onOpen={(item) => setReceipt(`Opened ${item.name ?? item.path}`)}
      />
    </>
  );
  return (
    <div ref={setContainer} className="empty-state-gallery-host">
      {container ? (
        <UiProvider container={container} dir={direction}>
          <EmptyState
            kind="diff"
            title="Open a repository"
            subtitle="Choose a folder, open a recent repository, or drop one here."
            dropText="Drop a repository to open it"
            onDrop={(item) => setReceipt(`Dropped ${item.name}`)}
            error={error}
          >
            {children}
          </EmptyState>
        </UiProvider>
      ) : null}
      <output className="empty-state-gallery-receipt" data-testid="empty-state-gallery-receipt" aria-live="polite">
        {receipt}
      </output>
    </div>
  );
}

const openRecent: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.find({ role: "option", name: /cmux/ }));
  await ctx.click({ role: "option", name: /cmux/ });
  await ctx.waitFor(() => ctx.find({ testId: "empty-state-gallery-receipt" }).textContent === "Opened cmux");
};

const chooseFolder: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Choose folder" });
  await ctx.waitFor(() => ctx.find({ testId: "empty-state-gallery-receipt" }).textContent === "Choose folder");
};

export default componentEntry<Props>({
  id: "viewer-empty.empty-state",
  title: "Viewer empty state",
  area: "Viewer",
  height: 430,
  widths: { narrow: 360, normal: 560, wide: 820 },
  anchors: [{ selector: ".empty-state-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Choosing or opening a recent item must not move the stable receipt anchor." },
    settleMaxMs: { value: 250, reason: "Empty-state actions are local fixture interactions." },
  },
  covers: [
    "viewer-empty/EmptyState.tsx#EmptyState",
    "viewer-empty/EmptyState.tsx#RecentList",
    "viewer-empty/EmptyState.tsx#TailPath",
  ],
  load: async () => GalleryEmptyState,
  styles: () => Promise.all([import("./styles.css"), import("./EmptyState.gallery.css")]),
  variants: {
    recents: { props: {}, play: openRecent },
    empty: { props: { state: "empty" } },
    loading: { props: { state: "loading" } },
    error: { props: { state: "error" } },
    choose: { props: {}, play: chooseFolder },
    rtl: { props: { direction: "rtl" } },
  },
});
