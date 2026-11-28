/** Whether a deferred parse result still belongs to the item that requested it. */
export function canApplyDeferredHydration(
  item: { fileDiff?: unknown } | undefined,
  expectedFileDiff: unknown,
): boolean {
  return item?.fileDiff === expectedFileDiff;
}
