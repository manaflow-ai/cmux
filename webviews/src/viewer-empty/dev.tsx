// Dev server only (dev-server/plugins.ts): the host side of the empty states in a plain browser.
// `chooseFolder` and `chooseFile` show the in-page fallback picker (PathPicker.tsx) listing
// folders through POST /__cmux-viewer/op `cmux.picker.list`; recents come from the same endpoint.
// The diff dev page uses `devDiffClient`; the markdown dev bridge calls `showDevPicker`. Nothing
// here ships.
import { createRoot } from "react-dom/client";
import type { PageClient } from "../pages/shared/pageClient";
import { pageError } from "../pages/shared/pageClient";
import type { Strings } from "../pages/shared/i18n";
import {
  DIFF_CHOOSE_FOLDER_OP,
  DIFF_OPEN_OP,
  DIFF_RECENTS_OP,
  EDITOR_RECENTS_OP,
  MARKDOWN_RECENTS_OP,
  PICKER_LIST_OP,
  parseRecents,
  type PickerMode,
} from "./ops";
import { UiProvider, languageDirection } from "../ui/UiProvider";
import { PathPickerDialog } from "./PathPicker";
import { viewerEmptyStrings } from "./strings";

/** POSTs one dev op to `url`; a non-2xx answer rejects with the server's page error. */
export async function devOp(url: string, op: string, params: unknown): Promise<unknown> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ op, params }),
  });
  const body = (await response.json().catch(() => ({}))) as { code?: string; message?: string };
  if (!response.ok)
    throw pageError(body.code ?? "cmux.page.failed", body.message ?? body.code ?? String(response.status));
  return body;
}

/** The dev answer to `chooseFolder` / `chooseFile`: the fallback picker over the page. */
export async function showDevPicker(
  mode: PickerMode,
  options: { start?: string | null; strings?: Strings; labels?: { title?: string; empty?: string } } = {},
): Promise<{ path: string } | null> {
  const recentsOp = mode === "folder" ? DIFF_RECENTS_OP : mode === "anyFile" ? EDITOR_RECENTS_OP : MARKDOWN_RECENTS_OP;
  const recents = parseRecents(await devOp("/__cmux-viewer/op", recentsOp, {}).catch(() => null)).map(
    (item) => item.path,
  );
  const host = document.createElement("div");
  host.className = "ve-sheet-host";
  // ui-allow: this host is the container the picker dialog portals into (UiProvider below).
  document.body.append(host);
  const root = createRoot(host);
  const previous = document.activeElement as HTMLElement | null;
  return new Promise((resolve) => {
    const done = (path: string | null) => {
      queueMicrotask(() => {
        root.unmount();
        host.remove();
        previous?.focus?.({ preventScroll: true });
        resolve(path ? { path } : null);
      });
    };
    const strings = options.strings ?? viewerEmptyStrings();
    root.render(
      <UiProvider container={host} dir={languageDirection(strings.language)}>
        <PathPickerDialog
          mode={mode}
          strings={strings}
          recents={recents}
          start={options.start ?? null}
          labels={options.labels}
          list={(path, list) => devOp("/__cmux-viewer/op", PICKER_LIST_OP, { path, ...list })}
          onChoose={(path) => done(path)}
          onCancel={() => done(null)}
        />
      </UiProvider>,
    );
  });
}

/** The page client of the diff dev page's empty state (`/diff/?pick`). */
export function devDiffClient(strings?: Strings): PageClient {
  return {
    async call<R>(op: string, params: unknown): Promise<R> {
      if (op === DIFF_CHOOSE_FOLDER_OP) {
        const start = (params as { start?: unknown } | null)?.start;
        return (await showDevPicker("folder", { start: typeof start === "string" ? start : null, strings })) as R;
      }
      if (op === DIFF_OPEN_OP) return (await devOp("/__cmux-diff/open", op, params)) as R;
      return (await devOp("/__cmux-viewer/op", op, params)) as R;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}
