import type { DiffViewerLabelResolver } from "./labels";
import type { DiffViewerConfig } from "./types";

export type DiffViewerStatus = {
  error: boolean;
  loading: boolean;
  message: string;
  pending: boolean;
  statusOnly: boolean;
};

export type DiffViewerStatusOptions = {
  error?: boolean;
  loading?: boolean;
  pending?: boolean;
  statusOnly?: boolean;
};

export function createDiffViewerStatus(
  message: string,
  options: DiffViewerStatusOptions = {},
): DiffViewerStatus {
  const pending = options.pending === true;
  return {
    error: options.error === true,
    loading: options.loading === true || pending,
    message,
    pending,
    statusOnly: options.statusOnly === true,
  };
}

export function initialDiffViewerStatus(
  config: DiffViewerConfig,
  label: DiffViewerLabelResolver,
): DiffViewerStatus {
  const payload = config.payload;
  if (payload?.pendingReplacement === true) {
    return createDiffViewerStatus(payload.statusMessage ?? label("loadingDiff"), {
      loading: true,
      pending: true,
    });
  }

  if (typeof payload?.statusMessage === "string" && payload.statusMessage.length > 0) {
    return createDiffViewerStatus(payload.statusMessage, {
      error: payload.statusIsError === true,
      loading: false,
      statusOnly: true,
    });
  }

  return createDiffViewerStatus(label("loadingDiff"), { loading: true });
}

export function applyDiffViewerStatusToDocument(status: DiffViewerStatus): void {
  document.body.dataset.loading = status.loading ? "true" : "false";
  document.body.dataset.statusOnly = status.statusOnly ? "true" : "false";
}
