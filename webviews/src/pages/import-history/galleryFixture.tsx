// l10n-allow-file: public-safe gallery fixtures.
import { useState } from "react";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ImportHistory, type HistoryLayout } from "./ImportHistory";
import { initialRows, ImportHistoryStore, type Phase, type HistorySnapshot } from "./model";
import { MockImportHistoryProvider } from "./mockProvider";

export function ImportHistoryGallery({
  layout,
  phase = "ready",
  empty = false,
  paste = false,
  autodetected = false,
}: {
  layout?: HistoryLayout;
  phase?: Phase;
  empty?: boolean;
  paste?: boolean;
  autodetected?: boolean;
}) {
  const [store] = useState(() => {
    const rows = initialRows().map((row) => {
      if (row.kind === "local" && !empty && phase !== "detecting") return { ...row, source: row.id, selected: true };
      if (autodetected && row.id === "chatgpt")
        return {
          ...row,
          source: "zip:/Users/example/Downloads/chatgpt-export.zip",
          name: "chatgpt-export.zip",
          selected: true,
          detected: true,
        };
      if (autodetected && row.id === "claude")
        return {
          ...row,
          source: "zip:/Users/example/Desktop/claude-export.zip",
          name: "claude-export.zip",
          selected: true,
          detected: true,
        };
      if (row.id === "grok-bot" && paste)
        return {
          ...row,
          selected: true,
          expanded: true,
          text: "I prefer concise replies. My current project is a community garden. I plan the week on Sundays.",
        };
      return row;
    });
    if (phase === "done") {
      for (const row of rows.filter((row) => row.selected)) {
        row.phase = "done";
        row.report = {
          plan: { total: 12, new: 12, duplicate: 0, secrets: 0 },
          est_cost_usd: 0.02,
          written: 12,
        };
      }
    } else if (["importing", "error"].includes(phase)) {
      const first = rows[0];
      if (first) {
        first.phase = phase === "importing" ? "writing" : "error";
        first.report = {
          plan: { total: 12, new: 12, duplicate: 0, secrets: 0 },
          est_cost_usd: 0.02,
        };
        if (phase === "error") first.error = "The selected file is no longer available.";
      }
    }
    const fixture: HistorySnapshot = {
      phase,
      rows,
      canUndo: phase === "done",
      undoing: false,
      batch: "gallery-batch",
    };
    return new ImportHistoryStore(new MockImportHistoryProvider(empty), fixture);
  });
  const [strings] = useState(() => createStrings(table));
  return <ImportHistory store={store} strings={strings} layout={layout} />;
}
