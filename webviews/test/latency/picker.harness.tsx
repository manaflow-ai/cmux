// Latency harness page for the viewer empty states (src/viewer-empty): `?view=picker` is the
// in-page folder picker (PathPicker) over a generated tree whose listings answer after the host
// delay; `?view=empty` (default) is the diff empty state with 30 recent repositories.
import { createRoot } from "react-dom/client";
import { createDiffViewerLabelResolver } from "../../src/labels";
import { pageError, type PageClient } from "../../src/pages/shared/pageClient";
import "../../src/viewer-empty/styles.css";
import { DiffEmptyState } from "../../src/viewer-empty/DiffEmptyState";
import { PathPickerDialog } from "../../src/viewer-empty/PathPicker";
import { viewerEmptyStrings } from "../../src/viewer-empty/strings";
import { hostDelay } from "./mock-host";

const delay = hostDelay();
const wait = () => new Promise((resolve) => setTimeout(resolve, delay));
const HOME = "/Users/dev";

/** A generated tree: every folder has 40 subfolders (`dir00`..`dir39`) and 60 files. */
function listing(path: string | null) {
  const at = path == null || path === "~" ? HOME : path;
  const depth = at.split("/").filter(Boolean).length;
  const dirs = Array.from({ length: 40 }, (_, index) => ({
    name: `dir${String(index).padStart(2, "0")}`,
    path: `${at === "/" ? "" : at}/dir${String(index).padStart(2, "0")}`,
    kind: "dir" as const,
    git: index % 5 === 0,
  }));
  const files = Array.from({ length: 60 }, (_, index) => ({
    name: `notes${index}.md`,
    path: `${at}/notes${index}.md`,
    kind: "file" as const,
  }));
  return {
    path: at,
    parent: depth > 0 ? at.slice(0, at.lastIndexOf("/")) || "/" : null,
    home: HOME,
    entries: [...dirs, ...files],
  };
}

const strings = viewerEmptyStrings(["en"]);
const root = createRoot(document.getElementById("root")!);
const view = new URLSearchParams(location.search).get("view") ?? "empty";
document.documentElement.dataset.view = view;

if (view === "picker") {
  const show = () =>
    root.render(
      <PathPickerDialog
        key={Date.now()}
        mode="folder"
        strings={strings}
        start={`${HOME}/dir01`}
        recents={[`${HOME}/dir01/dir05`]}
        list={async (path) => {
          await wait();
          return listing(path);
        }}
        onChoose={(path) => {
          document.documentElement.dataset.chosen = path;
          root.render(<p className="chosen">{path}</p>);
        }}
        onCancel={() => root.render(<p className="cancelled">cancelled</p>)}
      />,
    );
  (window as unknown as { __showPicker: () => void }).__showPicker = show;
  show();
} else {
  const recents = Array.from({ length: 30 }, (_, index) => ({
    path: `${HOME}/code/repo${index}`,
    openedAt: Date.now() - index * 3_600_000,
    branch: index % 3 === 0 ? "main" : undefined,
  }));
  const client: PageClient = {
    async call<R>(op: string, params: unknown): Promise<R> {
      await wait();
      if (op === "cmux.diff.recents") return { items: recents, home: HOME } as R;
      if (op === "cmux.diff.open") return { payload: { repoRoot: (params as { path: string }).path } } as R;
      if (op === "cmux.diff.chooseFolder") return null as R;
      throw pageError("cmux.protocol.unknown_op", op);
    },
    subscribe: async () => () => undefined,
    handle: () => () => undefined,
  };
  const show = () =>
    root.render(
      <DiffEmptyState
        key={Date.now()}
        client={client}
        strings={strings}
        label={createDiffViewerLabelResolver(undefined)}
        onOpened={(config) => {
          document.documentElement.dataset.opened = JSON.stringify(config);
        }}
      />,
    );
  (window as unknown as { __showEmpty: () => void }).__showEmpty = show;
  show();
}
