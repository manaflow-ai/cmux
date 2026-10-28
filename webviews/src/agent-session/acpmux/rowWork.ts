/** Debug-only operation counts for transcript delta consumers; inert in normal renders. */
export const transcriptWork = {
  enabled: false,
  turnPrefixComparisons: 0,
  layoutPrefixComparisons: 0,
  reset(): void {
    this.turnPrefixComparisons = 0;
    this.layoutPrefixComparisons = 0;
  },
};
