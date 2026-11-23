// The reader's open or closed, by thought (ThoughtRow.tsx), so a row the transcript unmounts and
// mounts again keeps it. Its own module, so a fold that closes can forget the thoughts inside it
// (transcriptDisclosureModel.ts) without importing the rows. Keys are the thought's id, or
// `<view>:<id>` for a choice made in the Thinking or Verbose view.
export const thoughtChoices = new Map<string, boolean>();

const VIEWS = ["thinking", "verbose"] as const;

/// Forgets every open choice on thoughts whose id `match` names (in every view), so they draw closed
/// again; a closed choice already is.
export function forgetThoughtChoices(match: (id: string) => boolean): void {
  for (const [key, open] of thoughtChoices) {
    if (!open) continue;
    const view = VIEWS.find((name) => key.startsWith(`${name}:`));
    if (match(view ? key.slice(view.length + 1) : key)) thoughtChoices.delete(key);
  }
}
