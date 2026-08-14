import type { DiffViewerAppearance } from "./appearance";
import type { DiffTransportConfig } from "./diff/generated/protocol";

export type DiffViewerPayload = {
  appearance?: DiffViewerAppearance;
  transport?: DiffTransportConfig;
  externalURL?: string;
  labels?: Record<string, string>;
  layout?: "split" | "unified";
  layoutSource?: "default" | "explicit";
  pendingReplacement?: boolean;
  statusMessage?: string;
  title?: string;
  [key: string]: any;
};

export type DiffViewerConfig = {
  assets?: Record<string, string | undefined>;
  payload?: DiffViewerPayload;
  [key: string]: any;
};
