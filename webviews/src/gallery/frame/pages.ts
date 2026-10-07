// Page hosts: the real page entry (src/pages/markdown/main.tsx, src/pages/diff/main.tsx) on an
// in-page cmuxPage host (test/latency/mock-host.ts, the latency harness's) that answers the page's
// ops from the state's data. The config carries the look the app sends: the Ghostty theme pair
// and the code font (`appearance`), and for markdown the `markdown` settings (font family, size).
import { HostError, installMockHost, type HostOp } from "../../../test/latency/mock-host";
import type { PageClient } from "../../pages/shared/pageClient";
import { AppsOps } from "../../pages/apps/types";
import { sampleApps, MockAppsProvider } from "../../pages/apps/mockProvider";
import { CloudOps, ACTION_RUN as CLOUD_ACTION_RUN, PAGE_COMMAND as CLOUD_PAGE_COMMAND } from "../../pages/cloud/ops";
import { MockCloudProvider } from "../../pages/cloud/mockProvider";
import { CodeRouterOps } from "../../pages/coderouter/types";
import { MockCodeRouterProvider } from "../../pages/coderouter/mockProvider";
import { ACTION_RUN as CHANGELOG_ACTION_RUN, ChangelogOps } from "../../pages/changelog/types";
import { MockChangelogProvider } from "../../pages/changelog/mockProvider";
import { IconPickerOps } from "../../pages/icon-picker/host";
import { MockIconPickerHost } from "../../pages/icon-picker/mockHost";
import { diffViewerLabelsFor, diffViewerLanguage, loadDiffViewerLabels } from "../../labels";
import type {
  AppsPageVariant,
  ChangelogPageVariant,
  CloudPageVariant,
  CodeRouterPageVariant,
  DiffFixtureFile,
  DiffPageVariant,
  EditorPageVariant,
  HistoryPageVariant,
  IconPickerPageVariant,
  KeybindingsPageVariant,
  MarkdownPageVariant,
} from "../format";
import { addPseudoLocales, isPseudo, pseudoText } from "../pseudo";
import type { StageContext } from "./context";
import {
  EDITOR_CHANGES,
  EDITOR_CONFIG_OP,
  EDITOR_EDITED_OP,
  EDITOR_LOOK,
  EDITOR_OPEN_LINK_OP,
  EDITOR_OPEN_OP,
  EDITOR_RECENTS_OP,
  EDITOR_SAVE_OP,
  EDITOR_SET_PREFERENCE_OP,
  type EditorConfig,
  type EditorFile,
} from "../../pages/editor/host";
import { HistoryOps, type HistoryEntry } from "../../pages/history/types";
import { HISTORY_FILTERS, type HistoryFilter } from "../../pages/history/model";
import { KeybindingOps } from "../../pages/keybindings/types";

const hash = (text: string) => {
  let value = 5381;
  for (let index = 0; index < text.length; index += 1) value = (value * 33) ^ text.charCodeAt(index);
  return `h${(value >>> 0).toString(16)}`;
};

export async function mountMarkdownPage(state: MarkdownPageVariant, context: StageContext): Promise<void> {
  // The page reads its tables once, as it loads: the pseudo-locales go in first.
  for (const table of [
    (await import("../../pages/markdown/generated/strings.json")).default,
    (await import("../../viewer-empty/generated/strings.json")).default,
  ])
    addPseudoLocales(table as unknown as Record<string, Record<string, string>>);
  const files = new Map<string, { text: string; hash: string }>();
  if (state.text !== null) files.set(state.path, { text: state.text, hash: hash(state.text) });
  for (const [path, text] of Object.entries(state.files ?? {})) files.set(path, { text, hash: hash(text) });
  const settings = { ...state.settings } as Record<string, unknown>;
  if (context.env.fontFamily || context.env.fontSize)
    settings.font = {
      ...(settings.font as object | undefined),
      ...(context.env.fontFamily && { family: context.env.fontFamily }),
      ...(context.env.fontSize && { size: context.env.fontSize }),
    };
  const config = (path: string) => {
    const file = files.get(path);
    if (!file) throw new HostError("cmux.markdown.not_found", path);
    return {
      path,
      text: file.text,
      hash: file.hash,
      readOnly: state.readOnly === true,
      assetBase: "/__gallery/none/",
      libBase: "/__gallery/none/",
      settings,
      themeCSS: state.themeCSS ?? "",
      appearance: context.appearance,
    };
  };
  const dir = state.path.replace(/[^/]*$/, "");
  const host = installMockHost(
    {
      "cmux.markdown.config": () =>
        state.text === null ? { pick: true, appearance: context.appearance } : config(state.path),
      "cmux.markdown.open": (params: { path: string }) => config(params.path),
      "cmux.markdown.read": () => {
        const file = files.get(state.path);
        return file ? { text: file.text, hash: file.hash } : { deleted: true };
      },
      "cmux.markdown.save": (params: { path: string; text: string }) => {
        const next = { text: params.text, hash: hash(params.text) };
        files.set(params.path, next);
        return { hash: next.hash };
      },
      "cmux.markdown.resolveLinks": (params: { paths: string[] }) => ({
        links: Object.fromEntries(
          params.paths.map((path) => {
            const target = path.startsWith("/") ? path : `${dir}${path.replace(/^\.\//, "")}`;
            return [path, { exists: files.has(target), path: target, kind: "markdown" }];
          }),
        ),
      }),
      "cmux.markdown.listFiles": () => ({ entries: [...files.keys()].map((path) => path.slice(dir.length)) }),
      "cmux.markdown.openLink": () => null,
      "cmux.markdown.recents": () => ({
        items: Object.keys(state.files ?? {}).map((path, index) => ({
          path,
          openedAt: Date.now() - index * 3_600_000,
        })),
      }),
    },
    ["cmux.markdown.changes", "cmux.markdown.look", "cmux.page.command"],
  );
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "markdown";
  root.dataset.cmuxWebviewKind = "markdown";
  await import("../../pages/markdown/main");
}

function filePatch(file: DiffFixtureFile): string {
  const before = file.before === undefined ? [] : file.before.replace(/\n$/, "").split("\n");
  const after = file.after === undefined ? [] : file.after.replace(/\n$/, "").split("\n");
  const head =
    file.before === undefined
      ? `diff --git a/${file.path} b/${file.path}\nnew file mode 100644\n--- /dev/null\n+++ b/${file.path}\n`
      : file.after === undefined
        ? `diff --git a/${file.path} b/${file.path}\ndeleted file mode 100644\n--- a/${file.path}\n+++ /dev/null\n`
        : `diff --git a/${file.path} b/${file.path}\n--- a/${file.path}\n+++ b/${file.path}\n`;
  // One hunk over the whole file: every line kept, removed or added (a line-level LCS).
  const rows: string[] = [];
  const table = Array.from({ length: before.length + 1 }, () => Array.from({ length: after.length + 1 }, () => 0));
  for (let i = before.length - 1; i >= 0; i -= 1)
    for (let j = after.length - 1; j >= 0; j -= 1)
      table[i]![j] =
        before[i] === after[j] ? table[i + 1]![j + 1]! + 1 : Math.max(table[i + 1]![j]!, table[i]![j + 1]!);
  let i = 0;
  let j = 0;
  while (i < before.length || j < after.length) {
    if (i < before.length && j < after.length && before[i] === after[j]) {
      rows.push(` ${before[i]}`);
      i += 1;
      j += 1;
    } else if (j < after.length && (i >= before.length || table[i]![j + 1]! >= table[i + 1]![j]!)) {
      rows.push(`+${after[j]}`);
      j += 1;
    } else {
      rows.push(`-${before[i]}`);
      i += 1;
    }
  }
  const start = (lines: string[]) => (lines.length ? 1 : 0);
  return `${head}@@ -${start(before)},${before.length} +${start(after)},${after.length} @@\n${rows.join("\n")}\n`;
}

export function diffPatch(state: DiffPageVariant): string {
  return state.patch ?? (state.files ?? []).map(filePatch).join("");
}

export async function mountDiffPage(state: DiffPageVariant, context: StageContext): Promise<void> {
  await import("../../styles.css");
  const repo = state.repoRoot ?? "/Users/you/src/app";
  const token = "gallery";
  const patch = diffPatch(state);
  const patchPath = `/__patch/${token}/1.patch`;
  const realFetch = window.fetch.bind(window);
  window.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(
      typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
      location.href,
    );
    if (url.pathname === patchPath)
      return Promise.resolve(new Response(patch, { headers: { "Content-Type": "text/x-diff" } }));
    return realFetch(input, init);
  }) as typeof fetch;
  // Ordinary gallery locales exercise the same host-free catalog as the app.
  // Pseudo-locales retain a protocol override so synthetic text remains a gallery concern.
  if (isPseudo(context.env.locale)) await loadDiffViewerLabels(diffViewerLanguage([context.env.locale]));
  const labels = isPseudo(context.env.locale)
    ? Object.fromEntries(
        Object.entries(diffViewerLabelsFor(diffViewerLanguage([context.env.locale]))).map(([key, text]) => [
          key,
          pseudoText(text, context.env.locale as "en-XA"),
        ]),
      )
    : undefined;
  const source = { kind: "branch", repoRoot: repo, baseRef: state.baseRef ?? "main" };
  const prefs: Record<string, unknown> = {};
  const host = installMockHost(
    {
      "cmux.diff.config": () => ({
        payload: {
          title: state.title ?? "Changes",
          transport: { kind: "page", endpoint: "", protocolVersion: 1 },
          capabilityToken: token,
          sessionSource: source,
          repoRoot: repo,
          branchBaseRef: source.baseRef,
          layout: state.layout ?? "split",
          layoutSource: "default",
          appearance: context.appearance,
          labels,
        },
        ops: ["cmux.diff.comments"],
      }),
      "cmux.diff.protocolHandshake": () => ({
        type: "handshake",
        value: { protocolVersion: 1, capabilities: ["sessions", "branches"] },
      }),
      "cmux.diff.sessionOpen": () => ({
        type: "sessionOpened",
        value: {
          sessionId: "gallery",
          patch: { id: patchPath, mediaType: "text/x-diff", byteLength: patch.length, revision: 1 },
          source,
          generatedPaths: [],
        },
      }),
      "cmux.diff.sessionClose": () => ({ type: "sessionClosed" }),
      "cmux.diff.branchList": () => ({
        type: "branches",
        value: {
          groups: [{ id: "suggested", label: "Suggested", rows: [{ ref: "main", label: "main", current: true }] }],
        },
      }),
      "cmux.diff.comments": (params: { method: string; params: Record<string, unknown> }) => {
        if (params.method === "viewedFiles.list") return { files: [] };
        if (params.method === "viewerPrefs.get") return { preferences: prefs };
        if (params.method === "comments.list") return { comments: [] };
        return {};
      },
    },
    ["cmux.diff.events", "cmux.diff.languages"],
  );
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "diff";
  root.dataset.cmuxWebviewKind = "diff";
  await import("../../pages/diff/main");
}

function pageOps(
  provider: PageClient,
  operations: readonly string[],
  state: {
    mode?: "loading" | "error";
    firstOperation: string;
    error?: { code: string; message: string };
  },
): Record<string, HostOp> {
  return Object.fromEntries(
    operations.map((operation) => [
      operation,
      async (params: unknown) => {
        if (state.mode === "loading" && operation === state.firstOperation) return await new Promise<never>(() => {});
        if (state.mode === "error" && operation === state.firstOperation) {
          throw new HostError(
            state.error?.code ?? "cmux.page.failed",
            state.error?.message ?? "The sample host failed.",
          );
        }
        return provider.call(operation, params);
      },
    ]),
  );
}

function clickLater(selector: string): void {
  setTimeout(() => document.querySelector<HTMLElement>(selector)?.click(), 80);
}

export async function mountAppsPage(state: AppsPageVariant, _context: StageContext): Promise<void> {
  const provider = new MockAppsProvider(JSON.parse(JSON.stringify(state.data)) as ReturnType<typeof sampleApps>);
  const host = installMockHost(
    pageOps(provider, [...Object.values(AppsOps), "cmux.page.connection", "cmux.page.command"], {
      mode: state.mode === "normal" ? undefined : state.mode,
      firstOperation: AppsOps.catalogList,
      error: state.error,
    }),
    [AppsOps.watch, AppsOps.logs, "cmux.page.connection", "cmux.page.command"],
  );
  host.delayMs = 0;
  if (state.hash) location.hash = state.hash;
  document.documentElement.dataset.cmuxPage = "apps";
  document.documentElement.dataset.cmuxWebviewKind = "apps";
  await import("../../pages/apps/main");
  if (state.action === "install") clickLater(".apps-button.primary");
}

export async function mountCloudPage(state: CloudPageVariant, _context: StageContext): Promise<void> {
  const provider = new MockCloudProvider({ signedIn: state.signedIn ?? true, unsupported: [] });
  provider.machines = JSON.parse(JSON.stringify(state.machines));
  provider.snapshots = JSON.parse(JSON.stringify(state.snapshots));
  const host = installMockHost(
    pageOps(provider, [...Object.values(CloudOps), CLOUD_ACTION_RUN, CLOUD_PAGE_COMMAND], {
      mode: state.mode === "normal" ? undefined : state.mode,
      firstOperation: CloudOps.authStatus,
      error: state.error,
    }),
    [CloudOps.machineWatch, CloudOps.fileTransferChanged, "cmux.page.connection", CLOUD_PAGE_COMMAND],
  );
  host.delayMs = 0;
  document.documentElement.dataset.cmuxPage = "cloud";
  document.documentElement.dataset.cmuxWebviewKind = "cloud";
  document.documentElement.dataset.cloudMachinesLayout = state.layout ?? "rows";
  await import("../../pages/cloud/main");
  if (state.action === "select-machine") clickLater(".cloud-machine");
  if (state.action === "create") clickLater(".cloud-create-button");
}

export async function mountCodeRouterPage(state: CodeRouterPageVariant, _context: StageContext): Promise<void> {
  const provider = new MockCodeRouterProvider({ signedIn: state.signedIn ?? true });
  provider.providers = JSON.parse(JSON.stringify(state.providers));
  const host = installMockHost(
    pageOps(provider, [...Object.values(CodeRouterOps), "cmux.page.connection", "cmux.page.command"], {
      mode: state.mode === "normal" ? undefined : state.mode,
      firstOperation: CodeRouterOps.status,
      error: state.error,
    }),
    ["cmux.page.connection", "cmux.page.command"],
  );
  host.delayMs = 0;
  document.documentElement.dataset.cmuxPage = "coderouter";
  document.documentElement.dataset.cmuxWebviewKind = "coderouter";
  await import("../../pages/coderouter/main");
}

export async function mountChangelogPage(state: ChangelogPageVariant, _context: StageContext): Promise<void> {
  const provider = new MockChangelogProvider(JSON.parse(JSON.stringify(state.notes)), state.current);
  const host = installMockHost(
    pageOps(provider, [ChangelogOps.list, ChangelogOps.get, CHANGELOG_ACTION_RUN], {
      mode: state.mode === "normal" ? undefined : state.mode,
      firstOperation: ChangelogOps.list,
      error: state.error,
    }),
    [],
  );
  host.delayMs = 0;
  document.documentElement.dataset.cmuxPage = "changelog";
  document.documentElement.dataset.cmuxWebviewKind = "changelog";
  await import("../../pages/changelog/main");
}

export async function mountIconPickerPage(state: IconPickerPageVariant, _context: StageContext): Promise<void> {
  const provider = new MockIconPickerHost();
  const host = installMockHost(
    pageOps(provider, Object.values(IconPickerOps), { firstOperation: IconPickerOps.prefsLoad }),
    [IconPickerOps.session],
  );
  host.delayMs = 0;
  document.documentElement.dataset.cmuxPage = "icon-picker";
  document.documentElement.dataset.cmuxWebviewKind = "icon-picker";
  await import("../../pages/icon-picker/main");
  const picker = (
    globalThis as {
      cmuxIconPicker?: {
        open(session: unknown): void;
        store: { setQuery(query: string): void; setActive(index: number): void };
      };
    }
  ).cmuxIconPicker;
  if (!picker) return;
  picker.open(state.session);
  if (state.mode === "empty") picker.store.setQuery(state.query ?? "no matching icon");
  else if (state.query) picker.store.setQuery(state.query);
  if (state.active !== undefined) picker.store.setActive(state.active);
}

const never = (): Promise<never> => new Promise(() => undefined);

function fixtureHash(text: string): string {
  let value = 2166136261;
  for (let index = 0; index < text.length; index += 1) value = Math.imul(value ^ text.charCodeAt(index), 16777619);
  return `gallery-${(value >>> 0).toString(16)}`;
}

function editorError(state: EditorPageVariant): HostError | undefined {
  switch (state.error) {
    case "network":
      return new HostError("cmux.protocol.closed", "the editor owner is unavailable");
    case "permission":
      return new HostError("cmux.editor.read_only", "the file is not writable");
    case "not-found":
      return new HostError("cmux.editor.not_found", "the file does not exist");
    case "not-file":
      return new HostError("cmux.editor.not_file", "the path is a folder");
    case "too-large":
      return new HostError("cmux.editor.too_large", "the file is too large to open");
    default:
      return undefined;
  }
}

function editorConfig(
  file: EditorFile,
  state: EditorPageVariant,
  context: StageContext,
  recoveredText?: string,
): EditorConfig {
  return {
    ...file,
    ...(recoveredText !== undefined ? { recoveredText } : {}),
    size: file.size ?? file.text.length,
    settings: state.settings,
    appearance: context.appearance,
    themeCSS: "",
  };
}

export async function mountEditorPage(state: EditorPageVariant, context: StageContext): Promise<void> {
  const path = state.path ?? "/Users/you/src/atlas-web/src/main.ts";
  const text = state.text ?? 'export const greeting = "hello from the gallery";\n';
  const files = new Map<string, EditorFile>();
  const base: EditorFile = {
    path,
    text,
    hash: state.hash ?? fixtureHash(text),
    size: state.size ?? text.length,
    readOnly: state.readOnly,
    readOnlyReason: state.readOnlyReason,
  };
  files.set(path, base);
  for (const [filePath, file] of Object.entries(state.files ?? {})) files.set(filePath, file);
  for (const recent of state.recents ?? [])
    if (!files.has(recent.path))
      files.set(recent.path, {
        path: recent.path,
        text: "// Recent gallery file\n",
        hash: fixtureHash(recent.path),
        size: 22,
      });
  const failure = editorError(state);
  const host = installMockHost(
    {
      [EDITOR_CONFIG_OP]: () => {
        if (state.loading) return never();
        if (failure) throw failure;
        if (state.path === undefined && state.text === undefined && !state.files) return { pick: true };
        return editorConfig(base, state, context, state.recoveredText);
      },
      [EDITOR_OPEN_OP]: (params: { path: string }) => {
        const file = files.get(params.path);
        if (!file) throw new HostError("cmux.editor.not_found", "the file does not exist");
        return editorConfig(file, state, context);
      },
      [EDITOR_SAVE_OP]: (params: { path: string; text: string; baseHash: string | null }) => {
        const current = files.get(params.path);
        if (current && current.hash !== params.baseHash)
          throw new HostError("cmux.editor.conflict", "the file changed on disk", {
            hash: current.hash,
            text: current.text,
          });
        if (state.readOnly) throw new HostError("cmux.editor.read_only", "the file is not writable");
        const next = { path: params.path, text: params.text, hash: fixtureHash(params.text), size: params.text.length };
        files.set(params.path, next);
        host.emit(EDITOR_CHANGES, { path: params.path, hash: next.hash, text: next.text });
        return { hash: next.hash };
      },
      [EDITOR_SET_PREFERENCE_OP]: () => ({}),
      [EDITOR_RECENTS_OP]: () => ({
        items: state.recents ?? [
          { path, name: path.split("/").pop(), openedAt: Date.now() },
          ...Array.from({ length: 8 }, (_, index) => ({
            path: `/Users/you/src/atlas-web/src/feature-${index + 1}/module.ts`,
            openedAt: Date.now() - (index + 1) * 86_400_000,
          })),
        ],
        home: "/Users/you",
      }),
      ["cmux.editor.chooseFile"]: () => ({ path }),
      [EDITOR_OPEN_LINK_OP]: () => null,
      [EDITOR_EDITED_OP]: () => null,
    },
    [EDITOR_CHANGES, EDITOR_LOOK, "cmux.page.command"] as const,
  );
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "editor";
  root.dataset.cmuxWebviewKind = "editor";
  await import("../../pages/editor/main");
  if (state.conflict) {
    const emitConflict = () => {
      host.emit(EDITOR_CHANGES, {
        path,
        hash: state.conflict!.hash,
        text: state.conflict!.text,
        deleted: state.conflict!.deleted,
      });
    };
    const started = Date.now();
    const waitForView = () => {
      const editor = (window as unknown as { __cmuxEditor?: { view?: () => unknown } }).__cmuxEditor;
      if (editor?.view?.() || Date.now() - started > 4_000) emitConflict();
      else window.setTimeout(waitForView, 100);
    };
    waitForView();
  }
}

function historyError(state: HistoryPageVariant): HostError | undefined {
  switch (state.error) {
    case "network":
      return new HostError("cmux.protocol.closed", "history is unavailable");
    case "permission":
      return new HostError("cmux.history.permission_denied", "history cannot be changed");
    case "not-found":
      return new HostError("cmux.history.not_found", "the history owner was not found");
    default:
      return undefined;
  }
}

function historyMatches(entry: HistoryEntry, params: { kinds?: string[]; text?: string }): boolean {
  if (params.kinds?.length && !params.kinds.includes(entry.kind)) return false;
  const query = (params.text ?? "").trim().toLocaleLowerCase();
  return (
    !query ||
    [entry.title, entry.detail, entry.cwd, entry.command, entry.workspace]
      .filter(Boolean)
      .join(" ")
      .toLocaleLowerCase()
      .includes(query)
  );
}

export async function mountHistoryPage(state: HistoryPageVariant, _context: StageContext): Promise<void> {
  let entries = [...(state.entries ?? [])];
  const failure = historyError(state);
  const host = installMockHost(
    {
      [HistoryOps.list]: (params: { kinds?: string[]; text?: string; limit?: number }) => {
        if (state.loading) return never();
        if (failure) throw failure;
        return {
          entries: entries.filter((entry) => historyMatches(entry, params)).slice(0, params.limit ?? 200),
          revision: 1,
        };
      },
      [HistoryOps.remove]: (params: { ids: string[] }) => {
        if (state.error === "permission")
          throw new HostError("cmux.history.permission_denied", "history cannot be changed");
        const ids = new Set(params.ids);
        const before = entries.length;
        entries = entries.filter((entry) => !ids.has(entry.id));
        if (before !== entries.length) host.emit(HistoryOps.changed, { revision: 2, kinds: [] });
        return { removed: before - entries.length };
      },
      [HistoryOps.removeSite]: () => ({ removed: 0 }),
      [HistoryOps.clear]: () => ({ removed: 0 }),
      ["cmux.app.action.run"]: () => ({}),
      ["cmux.app.clipboard.write"]: () => ({}),
    },
    [HistoryOps.changed, "cmux.page.connection", "cmux.page.command"] as const,
  );
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "history";
  root.dataset.cmuxWebviewKind = "history";
  await import("../../pages/history/main");
  const query = state.query;
  if (query) {
    window.setTimeout(() => {
      const input = document.querySelector<HTMLInputElement>(".history-search");
      if (query.text !== undefined && input) {
        input.value = query.text;
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }
      if (query.filter) {
        const index = (HISTORY_FILTERS as readonly HistoryFilter[]).indexOf(query.filter);
        document.querySelectorAll<HTMLButtonElement>(".history-chip")[index]?.click();
      }
      if (query.selectIndex !== undefined || query.menuIndex !== undefined) {
        window.setTimeout(() => {
          const rows = document.querySelectorAll<HTMLElement>(".history-row");
          const index = query.menuIndex ?? query.selectIndex!;
          const row = rows[index];
          if (!row) return;
          if (query.menuIndex !== undefined)
            row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, clientX: 220, clientY: 180 }));
          else row.click();
        }, 100);
      }
    }, 100);
  }
}

function keybindingsError(state: KeybindingsPageVariant): HostError | undefined {
  switch (state.error) {
    case "network":
      return new HostError("cmux.protocol.closed", "keybindings are unavailable");
    case "unsupported":
      return new HostError("cmux.keybindings.unsupported", "keybindings.json writing is not supported yet");
    case "not-found":
      return new HostError("cmux.keybindings.keymap_failed", "the keymap file was not found");
    default:
      return undefined;
  }
}

export async function mountKeybindingsPage(state: KeybindingsPageVariant, _context: StageContext): Promise<void> {
  let bindings = [...(state.bindings ?? [])];
  const failure = keybindingsError(state);
  const host = installMockHost(
    {
      [KeybindingOps.list]: () => {
        if (state.loading) return never();
        if (failure) throw failure;
        return { bindings };
      },
      [KeybindingOps.set]: () => {
        if (failure) throw failure;
        return {};
      },
      [KeybindingOps.remove]: () => {
        if (failure) throw failure;
        return {};
      },
      [KeybindingOps.reset]: () => {
        if (failure) throw failure;
        return {};
      },
      [KeybindingOps.recordStart]: () => ({}),
      [KeybindingOps.recordStop]: () => ({}),
      [KeybindingOps.keymapExport]: () => {
        if (failure && state.error === "not-found") throw failure;
        return { path: "/Users/you/Downloads/cmux-keymap.json" };
      },
      [KeybindingOps.keymapImport]: () => {
        if (failure && state.error === "not-found") throw failure;
        return { path: "/Users/you/Downloads/cmux-keymap.json" };
      },
    },
    [KeybindingOps.changed, KeybindingOps.recorded, "cmux.page.connection", "cmux.page.command"] as const,
  );
  host.delayMs = 0;
  const root = document.documentElement;
  root.dataset.cmuxPage = "keybindings";
  root.dataset.cmuxWebviewKind = "keybindings";
  await import("../../pages/keybindings/main");
  const query = state.query;
  if (query) {
    window.setTimeout(() => {
      const input = document.querySelector<HTMLInputElement>(".keys-search");
      if (query.text !== undefined && input) {
        input.value = query.text;
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }
      if (query.conflictsOnly) document.querySelector<HTMLButtonElement>(".keys-conflicts-only")?.click();
      window.setTimeout(() => {
        const rows = document.querySelectorAll<HTMLTableRowElement>(".keys-row");
        if (query.selectIndex !== undefined) rows[query.selectIndex]?.click();
        if (query.editIndex !== undefined)
          rows[query.editIndex]?.querySelector<HTMLButtonElement>(".keys-when")?.click();
        if (query.record) document.querySelector<HTMLButtonElement>(".keys-record")?.click();
      }, 100);
    }, 100);
  }
}

// These pages already have protocol-faithful mock providers. Keep their mutations and streams.
export { mountSettingsPage, mountPasswordsPage } from "./settingsPasswords";
