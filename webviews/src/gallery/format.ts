// The gallery's fixture format: ONE format for both hosts (the web gallery here, the DEBUG native
// gallery in cmux-next, CmuxNextGallery). A `<name>.gallery.ts(x)` file next to a component or
// page exports one entry by default: an id, which host draws it, what it covers and its named
// variants. A variant is plain data of the real structures (an AcpmuxSnapshot, a markdown file, a
// patch, a Swift model's JSON), never a copy of the component: the host feeds it through the
// input the app uses (the pane bridge, the cmuxPage bridge, the Swift view's model), so the real
// code renders it.
//
// Ids are dotted lower kebab case (`agent-pane.transcript`, `home.list-row`), the same in Swift
// and TypeScript; variant names are lower kebab case (`pending-single`, `9`). The URL names both.
//
// Gallery files import types only (and pure data helpers), so a test can import every one of them
// without a DOM (test/gallery-coverage.test.ts). A component host loads its component lazily.
import type { ComponentType } from "react";
import type { AcpmuxSnapshot } from "../agent-session/acpmux/model";
import type { EditorFile, ReadOnlyReason } from "../pages/editor/host";
import type { HistoryFilter, HistoryGrouping } from "../pages/history/model";
import type { HistoryEntry } from "../pages/history/types";
import type { Binding } from "../pages/keybindings/types";
import type { WidthName } from "./env";

/** Common to every variant. */
type VariantBase = {
  /** One line for the stage header: what the variant shows. */
  note?: string;
  /** The stage's height in px; else the entry's. */
  height?: number;
};

/** The whole agent pane (AcpmuxApp) on the pane bridge, as the app hosts it. */
export type AgentPaneVariant = VariantBase & {
  /** Fields of the `ready` answer the app sends (newTab, draft, newSession, machineName, ...). */
  ready?: Record<string, unknown>;
  /** The snapshot the bridge delivers after `ready`. */
  snapshot: AcpmuxSnapshot;
};

/** The markdown editor page (src/pages/markdown) on an in-page cmuxPage host. */
export type MarkdownPageVariant = VariantBase & {
  path: string;
  /** Null: the page opens in its empty state (no file). */
  text: string | null;
  readOnly?: boolean;
  /** cmux.json's `markdown` section. */
  settings?: Record<string, unknown>;
  /** The user's markdown/theme.css. */
  themeCSS?: string;
  /** Other files links may name (and the empty state's recents). */
  files?: Record<string, string>;
};

/** One file of a diff fixture: the text before (absent for a new file) and after (absent when deleted). */
export type DiffFixtureFile = { path: string; before?: string; after?: string };

/** The diff viewer page (src/pages/diff) on an in-page cmuxPage host serving fixed patches. */
export type DiffPageVariant = VariantBase & {
  title?: string;
  layout?: "split" | "unified";
  /** A unified patch (`git diff` output) or files to diff. */
  patch?: string;
  files?: DiffFixtureFile[];
  repoRoot?: string;
  baseRef?: string;
};

/** The code editor page (src/pages/editor) on a cmuxPage host with a fixture file. */
export type EditorPageVariant = VariantBase & {
  path?: string;
  text?: string;
  hash?: string;
  size?: number;
  readOnly?: boolean;
  readOnlyReason?: ReadOnlyReason;
  recoveredText?: string;
  settings?: unknown;
  files?: Record<string, EditorFile>;
  recents?: Array<{ path: string; name?: string; openedAt: number }>;
  /** Leave the first host request pending so the page's loading state remains visible. */
  loading?: boolean;
  error?: "network" | "permission" | "not-found" | "not-file" | "too-large";
  conflict?: { hash: string; text?: string; deleted?: boolean };
};

/** The history page (src/pages/history) on a cmuxPage host with timeline entries. */
export type HistoryPageVariant = VariantBase & {
  entries?: HistoryEntry[];
  loading?: boolean;
  error?: "network" | "permission" | "not-found";
  query?: {
    text?: string;
    filter?: HistoryFilter;
    grouping?: HistoryGrouping;
    selectIndex?: number;
    menuIndex?: number;
  };
};

/** The keyboard shortcuts page (src/pages/keybindings) on a cmuxPage host with bindings. */
export type KeybindingsPageVariant = VariantBase & {
  bindings?: Binding[];
  loading?: boolean;
  error?: "network" | "unsupported" | "not-found";
  query?: { text?: string; conflictsOnly?: boolean; selectIndex?: number; editIndex?: number; record?: boolean };
};

/** A React component with props, for components no page host draws on its own. */
export type ComponentVariant<P> = VariantBase & { props: P };

/**
 * A native (Swift) view's variant: the view builder registered under the same id in
 * CmuxNextGallery decodes `fixture`. `fixture` is a repo-relative path of a JSON file of the
 * Swift model (a shared fixture both hosts and the model's tests read), or inline JSON.
 */
export type NativeVariant = VariantBase & { fixture?: string | Record<string, unknown> };

type EntryBase<V> = {
  /** Unique, dotted lower kebab case (`area.name`); the same id in both hosts. */
  id: string;
  title: string;
  /** Sidebar group. */
  area: string;
  /**
   * What the entry shows, for the coverage test: `<path under webviews/src>#<ExportName>` (or the
   * path alone for every export of a file) for web components, `page:<PageDescriptor id>` for
   * pages, `swift:<TypeName>` for native views.
   */
  covers: string[];
  /** Default stage height in px (else 520). */
  height?: number;
  /** The width presets in px, when the entry's own differ from the host's. */
  widths?: Partial<Record<WidthName, number>>;
  variants: Record<string, V>;
};

export type AgentPaneEntry = EntryBase<AgentPaneVariant> & { host: "agent-pane" };
export type MarkdownPageEntry = EntryBase<MarkdownPageVariant> & { host: "markdown-page" };
export type DiffPageEntry = EntryBase<DiffPageVariant> & { host: "diff-page" };
export type EditorPageEntry = EntryBase<EditorPageVariant> & { host: "editor-page" };
export type HistoryPageEntry = EntryBase<HistoryPageVariant> & { host: "history-page" };
export type KeybindingsPageEntry = EntryBase<KeybindingsPageVariant> & { host: "keybindings-page" };
export type ComponentEntry<P = Record<string, unknown>> = EntryBase<ComponentVariant<P>> & {
  host: "component";
  /** The component; loaded only in a stage frame. */
  load: () => Promise<ComponentType<P>>;
  /** Stylesheets the component needs, loaded before it. */
  styles?: () => Promise<unknown>;
};
/** Drawn only by the native gallery; the web gallery lists it and shows its native snapshots. */
export type NativeEntry = EntryBase<NativeVariant> & { host: "native" };

export type GalleryEntry =
  | AgentPaneEntry
  | MarkdownPageEntry
  | DiffPageEntry
  | EditorPageEntry
  | HistoryPageEntry
  | KeybindingsPageEntry
  | ComponentEntry<any>
  | NativeEntry;
export type HostKind = GalleryEntry["host"];

/** Identity helpers that check an entry against its host's variant type. */
export const agentPaneEntry = (entry: Omit<AgentPaneEntry, "host">): AgentPaneEntry => ({
  ...entry,
  host: "agent-pane",
});
export const markdownPageEntry = (entry: Omit<MarkdownPageEntry, "host">): MarkdownPageEntry => ({
  ...entry,
  host: "markdown-page",
});
export const diffPageEntry = (entry: Omit<DiffPageEntry, "host">): DiffPageEntry => ({ ...entry, host: "diff-page" });
export const editorPageEntry = (entry: Omit<EditorPageEntry, "host">): EditorPageEntry => ({
  ...entry,
  host: "editor-page",
});
export const historyPageEntry = (entry: Omit<HistoryPageEntry, "host">): HistoryPageEntry => ({
  ...entry,
  host: "history-page",
});
export const keybindingsPageEntry = (entry: Omit<KeybindingsPageEntry, "host">): KeybindingsPageEntry => ({
  ...entry,
  host: "keybindings-page",
});
export function componentEntry<P>(entry: Omit<ComponentEntry<P>, "host">): ComponentEntry<P> {
  return { ...entry, host: "component" };
}
export const nativeEntry = (entry: Omit<NativeEntry, "host">): NativeEntry => ({ ...entry, host: "native" });

export const DEFAULT_STAGE_HEIGHT = 520;

export function stageHeight(entry: GalleryEntry, variant: string): number {
  return entry.variants[variant]?.height ?? entry.height ?? DEFAULT_STAGE_HEIGHT;
}

export const ENTRY_ID = /^[a-z0-9-]+(\.[a-z0-9-]+)+$/;
export const VARIANT_NAME = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/** Checks a set of entries: unique ids, at least one variant each, names the URL can carry. */
export function validateEntries(entries: readonly GalleryEntry[]): string[] {
  const problems: string[] = [];
  const seen = new Set<string>();
  for (const entry of entries) {
    if (!ENTRY_ID.test(entry.id)) problems.push(`${entry.id}: the id must be dotted lower kebab case`);
    if (seen.has(entry.id)) problems.push(`${entry.id}: duplicate id`);
    seen.add(entry.id);
    const variants = Object.keys(entry.variants);
    if (variants.length === 0) problems.push(`${entry.id}: no variants`);
    for (const name of variants)
      if (!VARIANT_NAME.test(name)) problems.push(`${entry.id}#${name}: variant names are lower kebab case`);
    if (entry.covers.length === 0) problems.push(`${entry.id}: covers nothing`);
  }
  return problems;
}
