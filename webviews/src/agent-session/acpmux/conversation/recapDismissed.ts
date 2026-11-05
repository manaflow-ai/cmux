// The session recaps the person dismissed on this device (RecapNote's ×). The client reads it
// before it makes a recap row and drops the row when the person dismisses it, so a dismissed
// recap leaves no row, and no empty slot, in the transcript.
const DISMISSED = "cmux.agentPane.recapDismissed";
const MAX_DISMISSED = 200;

function read(): string[] {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(DISMISSED) ?? "[]");
    return Array.isArray(value) ? value.filter((key): key is string => typeof key === "string") : [];
  } catch {
    return [];
  }
}

export function recapDismissed(key: string): boolean {
  return read().includes(key);
}

export function rememberRecapDismissed(key: string): void {
  try {
    const kept = read().filter((other) => other !== key);
    globalThis.localStorage?.setItem(DISMISSED, JSON.stringify([...kept, key].slice(-MAX_DISMISSED)));
  } catch {
    // Storage refused: the recap is gone from this view only.
  }
}
