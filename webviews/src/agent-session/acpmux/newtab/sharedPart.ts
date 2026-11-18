// The host sends a New Tab context in two parts (Swift AgentPaneNewTabShared). The page's own part is small
// and comes at each send: the key's input token, the folder, the bar's open tabs. The shared part is large
// (every workspace, every palette action, the recent pages) and the same for each New Tab page, so a
// document gets it one time: as JSON text in the own part's `shared` field of a reply, or as the second
// value of the script that carries an adopt event or the context of the document's commit. The own part
// names the generation of the shared part that it goes with (`sharedGeneration`). The document keeps the
// shared part and joins each own part with it.

type Kept = { generation: number; value: Record<string, unknown> };

/// Where the document keeps its shared part: the host's scripts write the same slot (Swift newTabJoin).
function slot(): { __cmuxNewTabShared?: Kept } {
  return window as { __cmuxNewTabShared?: Kept };
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function parsed(text: string): Record<string, unknown> | undefined {
  try {
    return record(JSON.parse(text));
  } catch {
    return undefined;
  }
}

/// The whole context of a `newTab` value from the host: its own part joined with the shared part, which the
/// value carries (`shared`, kept from here) or the document keeps. The own part's keys win, and the bar is
/// joined list by list (the open tabs are the page's own). A value that names no generation is whole
/// already (`true`, an older host) and comes back as it is; an own part whose shared part the document does
/// not have comes back alone (`lacksSharedPart`).
export function wholeNewTab(raw: unknown): unknown {
  const own = record(raw);
  const generation = own?.sharedGeneration;
  if (!own || typeof generation !== "number") return raw;
  const { shared: text, ...rest } = own;
  let kept = slot().__cmuxNewTabShared;
  // One generation is one text: a part kept at this generation is not parsed again.
  if (typeof text === "string" && kept?.generation !== generation) {
    const value = parsed(text);
    if (value) {
      kept = { generation, value };
      slot().__cmuxNewTabShared = kept;
    }
  }
  if (!kept || kept.generation !== generation) return rest;
  return { ...kept.value, ...rest, omnibar: { ...record(kept.value.omnibar), ...record(rest.omnibar) } };
}

/// True for a page's own part whose shared part the document does not have: the value carries none, a
/// script joined none, and the part kept is of another generation or there is none. The host's mark and the
/// document differ then (a lost state), and the page asks for its context again (`useLostSharedPart`).
export function lacksSharedPart(raw: unknown): boolean {
  const own = record(raw);
  const generation = own?.sharedGeneration;
  if (!own || typeof generation !== "number") return false;
  if (typeof own.shared === "string" || own.hotkeys !== undefined) return false;
  return slot().__cmuxNewTabShared?.generation !== generation;
}
