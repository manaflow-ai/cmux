import { expect, test } from "bun:test";
import { createDiffViewerStatus, initialDiffViewerStatus } from "../src/status";
import type { DiffViewerLabelResolver } from "../src/labels";
import type { DiffViewerConfig } from "../src/types";

const label: DiffViewerLabelResolver = (key) => {
  if (key === "loadingDiff") {
    return "Loading diff";
  }
  return key;
};

test("createDiffViewerStatus treats pending as loading", () => {
  expect(createDiffViewerStatus("Waiting", { pending: true })).toEqual({
    error: false,
    loading: true,
    message: "Waiting",
    pending: true,
    statusOnly: false,
  });
});

test("initialDiffViewerStatus uses pending replacement status", () => {
  const config: DiffViewerConfig = {
    payload: {
      pendingReplacement: true,
      statusMessage: "Rendering diff",
    },
  };

  expect(initialDiffViewerStatus(config, label)).toEqual({
    error: false,
    loading: true,
    message: "Rendering diff",
    pending: true,
    statusOnly: false,
  });
});

test("initialDiffViewerStatus falls back for pending replacement without a status message", () => {
  const config: DiffViewerConfig = {
    payload: {
      pendingReplacement: true,
    },
  };

  expect(initialDiffViewerStatus(config, label)).toEqual({
    error: false,
    loading: true,
    message: "Loading diff",
    pending: true,
    statusOnly: false,
  });
});

test("initialDiffViewerStatus treats status-only errors as terminal messages", () => {
  const config: DiffViewerConfig = {
    payload: {
      statusIsError: true,
      statusMessage: "No diff found",
    },
  };

  expect(initialDiffViewerStatus(config, label)).toEqual({
    error: true,
    loading: false,
    message: "No diff found",
    pending: false,
    statusOnly: true,
  });
});
