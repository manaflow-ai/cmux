/// The catalog row of the model a chat runs: by its id, or the release an alias row stands for
/// ("opus"), then without a context variant suffix ("claude-opus-5-5[1m]" runs Opus 5.5's
/// levels). Its levels and default effort describe the Reasoning menu.
export function catalogRow<T extends { id: string; release?: string }>(
  models: readonly T[] | undefined,
  id: string | undefined,
): T | undefined {
  if (!models || !id) return undefined;
  const find = (want: string) => models.find((model) => model.id === want || model.release === want);
  return find(id) ?? find(id.replace(/\[[^\]]*\]$/, ""));
}
