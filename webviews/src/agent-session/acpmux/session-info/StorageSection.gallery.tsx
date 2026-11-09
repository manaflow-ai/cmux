// l10n-allow-file: gallery fixtures (sample worktrees and commands), not shipped UI.
//
// Session Info's Storage (StorageSection.tsx), three layouts and every state.
//
// - plain: checklist rows with the size trailing, a Select all line over them.
// - grouped: the same rows under their repository's caption.
// - summary: one line with the disk's meter and what is free of it, then the rows.
//
// Shipped: summary. The panel is machine-wide and the person opens it to decide whether to free
// anything at all; the disk line answers that first ("212 GB free of 1 TB", the meter amber under
// pressure) with the meter Context already uses, so it reads as the same panel. Grouped spends a
// caption row per repository, which in a 300-row list is mostly captions for one-row groups; plain
// gives the sizes no scale to read them against.
import { useMemo, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SessionInfoPanel } from "./SessionInfo";
import { SessionInfoSection } from "./SessionInfoSection";
import {
  StorageSection,
  resetStorageForTests,
  useStorage,
  useStorageMeta,
  type StorageActions,
  type StorageLayout,
  type StorageSource,
  type StorageView,
} from "./StorageSection";
import type { KeptRow, StaleRow } from "./storageSectionModel";

const GB = 1024 ** 3;
const MB = 1024 ** 2;

const REPOS = ["atlas", "harbor", "lumen"];
const REASONS = ["merged into main", "squashed into main", "merged into release"];

function staleRows(count: number): StaleRow[] {
  return Array.from({ length: count }, (_, index) => ({
    path: `/Users/sam/worktrees/${REPOS[index % 3]}-task-${index + 1}`,
    name: `${REPOS[index % 3]}-task-${index + 1}`,
    repository: REPOS[index % 3]!,
    branch: `lane/task-${index + 1}`,
    reason: REASONS[index % 3]!,
    // Every seventh one was past the sizing budget: not measured.
    ...(index % 7 === 6 ? {} : { bytes: Math.round(((count - index) * 37 * MB) % (4 * GB)) + 120 * MB }),
  }));
}

const KEPT: KeptRow[] = Array.from({ length: 41 }, (_, index) => ({
  path: `/Users/sam/worktrees/kept-${index + 1}`,
  name: `kept-${index + 1}`,
  reason: ["a live session uses it", "uncommitted work", "not merged into a base"][index % 3]!,
}));

const DISK = { total: 1000 * GB, available: 212 * GB };

const base = (stale: StaleRow[]): StorageView => ({
  loading: false,
  empty: false,
  disk: DISK,
  pressure: "high",
  stale,
  kept: KEPT,
  errors: [],
  selected: new Set(),
  failed: new Map(),
  freeing: false,
});

type State = "ready" | "loading" | "empty" | "many" | "errors" | "freeing" | "freed" | "live";

function view(state: State): StorageView {
  const six = staleRows(6);
  switch (state) {
    case "ready":
      return { ...base(six), selected: new Set(six.slice(0, 3).map((row) => row.path)) };
    case "loading":
      return { ...base([]), loading: true, empty: true, kept: [] };
    case "empty":
      return { ...base([]), pressure: "normal" };
    case "many":
      return { ...base(staleRows(300)), selected: new Set(staleRows(300).map((row) => row.path)) };
    case "errors":
      return {
        ...base(six),
        failed: new Map([
          [six[1]!.path, "it changed since the scan; it stays"],
          [six[4]!.path, "a session opened in it; it stays"],
        ]),
        errors: ["git worktree list failed in /Users/sam/src/lumen"],
      };
    case "freeing":
      return { ...base(six), selected: new Set(six.slice(0, 3).map((row) => row.path)), freeing: true };
    case "freed":
      return { ...base(six.slice(3)), freed: Math.round(2.1 * GB) };
    default:
      return base(six);
  }
}

/// A source that answers like acpmux, a little late: the live variant's flow end to end.
function gallerySource(): StorageSource {
  let stale = staleRows(6);
  const report = () => ({
    report: {
      disk: DISK,
      pressure: "high",
      applied: false,
      items: [
        ...stale.map((row) => ({
          path: row.path,
          repository: `/Users/sam/src/${row.repository}`,
          branch: row.branch,
          verdict: { action: "reclaim", reason: row.reason },
          stale: true,
          ...(row.bytes !== undefined ? { bytes: row.bytes } : {}),
        })),
        ...KEPT.map((row) => ({
          path: row.path,
          repository: "/Users/sam/src/atlas",
          verdict: { action: "keep", reason: row.reason },
          stale: false,
        })),
      ],
      freed: 0,
      reclaimable: 0,
      errors: [],
      expired: [],
    },
    last: null,
  });
  const later = <T,>(value: () => T, ms: number) => new Promise<T>((done) => setTimeout(() => done(value()), ms));
  return {
    report: () => later(report, 900),
    clean: (paths) =>
      later(() => {
        const freed = stale.filter((row) => paths.includes(row.path));
        stale = stale.filter((row) => !paths.includes(row.path));
        return {
          ...report().report,
          applied: true,
          freed: freed.reduce((sum, row) => sum + (row.bytes ?? 0), 0),
          items: freed.map((row) => ({
            path: row.path,
            repository: "",
            verdict: { action: "reclaim", reason: row.reason },
            stale: true,
            outcome: { ok: true, freed: row.bytes ?? 0 },
          })),
        };
      }, 700),
  };
}

const NOOP: StorageActions = {
  onToggle: () => undefined,
  onToggleAll: () => undefined,
  onFree: () => undefined,
  onRefresh: () => undefined,
};

type Props = { layout: StorageLayout; state: State };

function Frame({
  view: shown,
  actions,
  layout,
}: {
  view: StorageView;
  actions: StorageActions;
  layout: StorageLayout;
}) {
  const meta = useStorageMeta(shown);
  return (
    <div className="acpmux-shell" style={{ display: "flex", justifyContent: "flex-end", height: "100%" }}>
      <SessionInfoPanel width={320} placement="overlay">
        <div className="acpmux-session-info__body">
          <SessionInfoSection
            id="storage"
            title="Storage"
            open
            onOpenChange={() => undefined}
            meta={<span className="acpmux-session-info-section__value">{meta}</span>}
          >
            <StorageSection view={shown} actions={actions} layout={layout} measuringDelay={0} />
          </SessionInfoSection>
        </div>
      </SessionInfoPanel>
    </div>
  );
}

/// A fixture state with its checkboxes live, so a variant can be clicked through.
function Fixture({ layout, state }: Props) {
  const initial = useMemo(() => view(state), [state]);
  const [selected, setSelected] = useState(initial.selected);
  const shown = { ...initial, selected };
  const actions: StorageActions = {
    ...NOOP,
    onToggle: (path) =>
      setSelected((now) => {
        const next = new Set(now);
        if (!next.delete(path)) next.add(path);
        return next;
      }),
    onToggleAll: () =>
      setSelected((now) =>
        now.size === initial.stale.length ? new Set() : new Set(initial.stale.map((row) => row.path)),
      ),
  };
  return <Frame view={shown} actions={actions} layout={layout} />;
}

/// The shipped hook against a source that answers late: open, Measuring…, check, Free, Freed.
function Live({ layout }: { layout: StorageLayout }) {
  const source = useMemo(() => {
    resetStorageForTests();
    return gallerySource();
  }, []);
  const storage = useStorage(source, true);
  return <Frame view={storage.view} actions={storage.actions} layout={layout} />;
}

function StorageGallery(props: Props) {
  return props.state === "live" ? <Live layout={props.layout} /> : <Fixture {...props} />;
}

export default componentEntry<Props>({
  id: "agent-pane.session-info-storage",
  title: "Session Info Storage",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 284, normal: 320 },
  covers: [
    "agent-session/acpmux/session-info/StorageSection.tsx",
    "agent-session/acpmux/session-info/storageSectionModel.ts",
    "agent-session/acpmux/session-info/storageSection.css",
  ],
  load: async () => StorageGallery,
  variants: {
    "a-plain": {
      note: "Layout A: checklist rows, size trailing, Select all over them. Three checked.",
      props: { layout: "plain", state: "ready" },
    },
    "b-grouped": {
      note: "Layout B: the same rows under repository captions.",
      props: { layout: "grouped", state: "ready" },
    },
    "c-summary": {
      note: "Layout C (shipped): the disk's meter and free space, then the rows. Three checked.",
      props: { layout: "summary", state: "ready" },
    },
    loading: {
      note: "First open: one quiet Measuring… line where the rows will be, no spinner.",
      props: { layout: "summary", state: "loading" },
    },
    empty: {
      note: "Nothing stale: Nothing to free, the kept count still there.",
      props: { layout: "summary", state: "empty" },
    },
    "many-rows": {
      note: "300 stale worktrees, all checked: the list draws only the rows that can show (WindowedRows).",
      props: { layout: "summary", state: "many" },
    },
    "many-rows-grouped": {
      note: "300 rows grouped: captions windowed with the rows.",
      props: { layout: "grouped", state: "many" },
    },
    errors: {
      note: "A clean refused two worktrees: they keep their place with acpmux's reason in red; a pass error under the list.",
      props: { layout: "summary", state: "errors" },
    },
    freeing: {
      note: "Freeing: the button says so and the checkboxes hold.",
      props: { layout: "summary", state: "freeing" },
    },
    freed: {
      note: "Freed: the freed rows are gone, the rows under them closed up, Freed 2.1 GB in the button's place.",
      props: { layout: "summary", state: "freed" },
    },
    live: {
      note: "The shipped hook against a source that answers in about a second: check rows, press Free or Return.",
      props: { layout: "summary", state: "live" },
    },
  },
});
