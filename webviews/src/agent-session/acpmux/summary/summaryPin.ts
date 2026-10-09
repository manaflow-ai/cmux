// Stub (red commit): the pinned summary's pin state and the wide-pane test.
export const PIN_KEY = "cmux.agent-pane.summary.pinned";
export function useSummaryPinned(): { pinned: boolean; wide: boolean; shown: boolean; setPinned(next: boolean): void } {
  return { pinned: false, wide: false, shown: false, setPinned: () => undefined };
}
