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
  /** Persisted display toggles baked in by the CLI; sanitized at boot. */
  viewerOptions?: Record<string, unknown>;
  /**
   * The sidecar session options the host's sidecar honors, by their handshake capability names
   * (Native/DiffSidecar/src/protocol.rs): `session.ignoreWhitespace` turns on Hide white space.
   */
  sessionCapabilities?: string[];
  [key: string]: any;
};

export type DiffViewerConfig = {
  payload?: DiffViewerPayload;
  [key: string]: any;
};
