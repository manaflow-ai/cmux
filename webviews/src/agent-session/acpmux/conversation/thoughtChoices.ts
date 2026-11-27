// The reader's open or closed, by thought (ThoughtRow.tsx), so a row the transcript unmounts and
// mounts again keeps it. Its own module, so a fold that closes can forget the thoughts inside it
// (transcriptDisclosureModel.ts) without importing the rows. Keys are the thought's id, or
// `<view>:<id>` for a choice made in the Thinking or Verbose view.
// Its values are the open-state store's "thought" space (disclosureStore.ts).
import { pageSpace } from "./disclosureStore";

const VIEWS = ["thinking", "verbose"] as const;

/// The row a thought's choice shows in: its id is `<row id>:thought:<n>`, after a view's prefix. A
/// thought's choice is not kept per chat, so the row is credited in no chat ("").
export const thoughtChoices = pageSpace("thought", (key) => {
  const view = VIEWS.find((name) => key.startsWith(`${name}:`));
  const id = view ? key.slice(view.length + 1) : key;
  const at = id.indexOf(":thought:");
  return at < 0 ? undefined : id.slice(0, at);
});

/// Forgets every open choice on thoughts whose id `match` names (in every view), so they draw closed
/// again; a closed choice already is.
export function forgetThoughtChoices(match: (id: string) => boolean): void {
  thoughtChoices.deleteWhere((key, open) => {
    if (!open) return false;
    const view = VIEWS.find((name) => key.startsWith(`${name}:`));
    return match(view ? key.slice(view.length + 1) : key);
  });
}

/// The reader's choices on the thoughts of row `rowId` (ids `<row id>:thought:<n>`, in every view),
/// as one string: "" when there are none. Part of the row's state signature (rowOpenState.ts).
/// O(choices), and nothing when the reader opened or closed no thought.
export function thoughtChoicesNaming(rowId: string): string {
  if (thoughtChoices.size === 0) return "";
  const prefix = `${rowId}:thought:`;
  let out = "";
  for (const [key, open] of thoughtChoices) {
    const view = VIEWS.find((name) => key.startsWith(`${name}:`));
    if (!(view ? key.slice(view.length + 1) : key).startsWith(prefix)) continue;
    out += `${out === "" ? "" : ","}${key}=${open ? 1 : 0}`;
  }
  return out;
}
