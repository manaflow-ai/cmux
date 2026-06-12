import type { DiffViewerAppearance } from "./appearance";

export type DiffViewerPayload = {
  appearance?: DiffViewerAppearance;
  externalURL?: string;
  labels?: Record<string, string>;
  layout?: "split" | "unified";
  layoutSource?: "default" | "explicit";
  pendingReplacement?: boolean;
  statusMessage?: string;
  title?: string;
  /** User-configured Monaco options from `editor.*` in cmux.json, already
   * curated and validated by the CLI. The webview re-filters defensively. */
  editorOptions?: Record<string, unknown>;
  [key: string]: any;
};

export type DiffViewerConfig = {
  assets?: Record<string, string | undefined>;
  payload?: DiffViewerPayload;
  [key: string]: any;
};
