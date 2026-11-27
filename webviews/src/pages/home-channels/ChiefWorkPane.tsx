import { useEffect, useSyncExternalStore } from "react";
import { useAutoRetry } from "../../agent-session/acpmux/autoRetry";
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
  // A failed read is asked again on its own while the owner is online; only one that lasts gets the
  // quiet "Still loading" line (Leo, 2026-11-22: no vacuous "try refreshing").
  const { stillTrying } = useAutoRetry(current && state.failed, () => void book.refresh(), {
    busy: current && state.loading,
    shown: online,
  });
  return (
    <ChiefWorkPanel
      snapshot={current ? state.snapshot : undefined}
      loading={!current || state.loading}
      stillTrying={current && stillTrying}
      strings={strings}
      onRefresh={() => void book.refresh()}
      onClose={onClose}
    />
  );
}
