// l10n-allow-file: public-safe gallery fixtures.
import { useEffect, useState } from "react";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockStashProvider, sampleStashes } from "./mockProvider";
import { StashPage } from "./StashPage";
import { StashStore } from "./store";
import type { StashRecord } from "./types";

export type StashGalleryProps = {
  stashes?: "sample" | "empty" | "many";
  query?: string;
  importText?: string;
  offline?: boolean;
  /** The app's Undo toast stays up: a delete's rows stay hidden and nothing is deleted yet. */
  undoPending?: boolean;
};

function many(now: number): StashRecord[] {
  return Array.from({ length: 12 }, (_, group) => ({
    id: `g${group}`,
    name: group % 3 === 0 ? undefined : `research-${group}`,
    created_at_ms: now - group * 7_200_000,
    members: Array.from({ length: 8 }, (_, index) => ({
      id: `m${index}`,
      kind: "tab" as const,
      url: `https://docs${index}.example.test/${"chapter/".repeat(3)}${group}-${index}`,
      title: `Chapter ${index + 1} of a long reference manual that runs past the row's width (${group})`,
    })),
  }));
}

export function StashGallery({
  stashes = "sample",
  query,
  importText,
  offline = false,
  undoPending = false,
}: StashGalleryProps) {
  const [store] = useState(() => {
    const now = Date.now();
    const provider = new MockStashProvider(
      stashes === "empty" ? [] : stashes === "many" ? many(now) : sampleStashes(now),
    );
    provider.offline = offline;
    if (undoPending) provider.toast = new Promise<void>(() => undefined);
    const created = new StashStore(provider, { importOpen: importText !== undefined });
    if (query) created.setQuery(query);
    if (importText) created.setImportText(importText);
    return created;
  });
  const [strings] = useState(() => createStrings(table, ["en"]));
  useEffect(() => () => store.stop(), [store]);
  return <StashPage store={store} strings={strings} />;
}
