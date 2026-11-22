import { useEffect, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import type { ChiefWorkStore } from "./ChiefWorkStore";
import { ChiefWorkPanel } from "./ChiefWorkPanel";

/** Mounting reads once; leaving the conversation closes its read scope and invalidates late replies. */
export function ChiefWorkPane({
  book,
  chief,
  online,
  strings,
  onClose,
}: {
  book: ChiefWorkStore;
  chief: string;
  online: boolean;
  strings: Strings;
  onClose(): void;
}) {
  const state = useSyncExternalStore(book.subscribe, book.getSnapshot);
  useEffect(() => {
    book.select(chief);
    return () => book.select(undefined);
  }, [book, chief]);
  useEffect(() => {
    if (online) void book.refresh();
  }, [book, online]);
  // The previous Chief's snapshot is never shown during React's effect hand-off.
  const current = state.chief === chief;
  return (
    <ChiefWorkPanel
      snapshot={current ? state.snapshot : undefined}
      loading={!current || state.loading}
      error={current && state.failed ? strings.t("work.unavailable") : undefined}
      strings={strings}
      onRefresh={() => void book.refresh()}
      onClose={onClose}
    />
  );
}
