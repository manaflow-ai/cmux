/// The start the person asked for before a repair (a sign-in, setup) got in its way (Leo: "select
/// the thing and then start the thing"). The composer keeps it while the repair runs and, once it
/// is done, offers an explicit Start with the same agent, model, machine and folder: never a send
/// on its own, and never twice.
export type StartIntent = {
  harness: string;
  model?: string;
  /** The chosen machine (a peer host); none for this one. */
  host?: string;
  /** The chosen folder. */
  folder?: string;
  /** The draft when the start was refused: used only when the field is empty at Start. */
  draft: string;
  /** What the start waits on. */
  reason: "signIn" | "setup";
};

export type StartTarget = { harness?: string; host?: string; folder?: string };

/// The intent for a start refused on `target`, or none without a harness to start.
export function captureStartIntent(
  target: StartTarget,
  model: string | undefined,
  draft: string,
  reason: StartIntent["reason"],
): StartIntent | undefined {
  if (!target.harness) return undefined;
  return {
    harness: target.harness,
    ...(model ? { model } : {}),
    ...(target.host ? { host: target.host } : {}),
    ...(target.folder ? { folder: target.folder } : {}),
    draft,
    reason,
  };
}

/// Whether `intent` still names the composer's target: a machine, agent or folder picked since
/// is a new choice, and the old intent's Start would start the wrong thing.
export function intentStillApplies(intent: StartIntent, target: StartTarget): boolean {
  return (
    intent.harness === target.harness &&
    (intent.host ?? undefined) === (target.host ?? undefined) &&
    (intent.folder ?? undefined) === (target.folder ?? undefined)
  );
}

/// The prompt Start sends: the draft as it is now when there is one (a newer draft typed during
/// the repair wins), else the draft the refused start had.
export function intentPrompt(intent: StartIntent, current: string): string {
  return current.trim() ? current.trim() : intent.draft.trim();
}

/// Takes the intent once: a second Start (a double click, a key repeat) finds none.
export function takeStartIntent(slot: { current: StartIntent | undefined }): StartIntent | undefined {
  const intent = slot.current;
  slot.current = undefined;
  return intent;
}
