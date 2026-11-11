// A fork's cut as one divider in the transcript (Leo 2026-11-11: "you select a different model ...
// That's implicitly you're forking it, right? So all it should be is like, you know, it looks like
// there's a line, and it's like, you know, forked from previous"). The rows above it are the chat it
// came from; the line names what that chat ran ("Forked from Claude Opus 5.5") from acpmux's record
// of the switch (`forkOrigin` on the session summary, hub/fork.rs), so every surface draws the same
// truth. An ordinary fork's line names the chat it came from. A model switch shown in this pane
// also offers Open in new tab (Leo: "Or perhaps it, like, opens up a new thing, possibly"), never
// a dialog.
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { BUNDLED_MODEL_CATALOG } from "../modelCatalogData";
import { modelIdName } from "../defaultChoice";
import { harnessName } from "../permissions/planBuild";
import { sessionTitle, type AcpmuxSessionEntry, type ForkOrigin } from "../sessionList";
import type { Translate } from "../i18n";

export type ForkDivider = {
  /// "Forked from Claude Opus 5.5" / "Forked from Fix the login page".
  label: string;
  /// A model switch shown in this pane: the fork and the chat it came from, for Open in new tab.
  openInTab?: { sessionId: string; parentId: string };
};

/// The row id direct.ts gives a fork's cut (`forked-from-<seq>`).
const CUT = "forked-from-";

type Catalog = AcpmuxSnapshot["catalog"];

/// What a switch's chat ran, as the picker names it: the model's catalog name ("Claude Opus 5.5"),
/// else a Claude id read out ("Opus 5.5"), else the harness's name ("Codex"). Never an id that
/// reads as code.
export function forkOriginName(origin: ForkOrigin, catalog: Catalog, t: Translate): string {
  const harness =
    catalog.find((entry) => entry.id === origin.harness) ??
    (origin.family ? catalog.find((entry) => entry.family === origin.family) : undefined);
  const bundled =
    BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === origin.harness) ??
    BUNDLED_MODEL_CATALOG.harnesses.find((entry) => !!origin.family && entry.families.includes(origin.family));
  if (origin.model) {
    const model =
      harness?.models.find((entry) => entry.id === origin.model) ??
      BUNDLED_MODEL_CATALOG.harnesses.flatMap((entry) => entry.models).find((entry) => entry.id === origin.model);
    if (model?.name) return model.name;
    const read = modelIdName(origin.model, t);
    if (read !== origin.model) return read;
  }
  return harness?.name || bundled?.name || harnessName(origin.family ?? origin.harness);
}

/// One divider per fork cut in the shown chat's transcript, newest first: the shown chat's own
/// cut, then each ancestor's (a fork's history holds its parent's cuts too). Undefined entries
/// keep their row as acpmux's client drew it.
export function forkDividers(
  sessionId: string | undefined,
  sessions: readonly AcpmuxSessionEntry[],
  catalog: Catalog,
  t: Translate,
  canOpenTab: boolean,
): (ForkDivider | undefined)[] {
  if (!sessionId) return [];
  const byId = (id: string | undefined) => (id ? sessions.find((entry) => entry.sessionId === id) : undefined);
  const out: (ForkDivider | undefined)[] = [];
  const seen = new Set<string>();
  let current = byId(sessionId);
  while (current && !seen.has(current.sessionId)) {
    seen.add(current.sessionId);
    const parentId = current.forkOrigin?.sessionId ?? current.parentId;
    if (!parentId) break;
    const parent = byId(parentId);
    if (current.forkOrigin) {
      const label = t("forkDivider.from", { name: forkOriginName(current.forkOrigin, catalog, t) });
      out.push({
        label,
        ...(canOpenTab && out.length === 0 && { openInTab: { sessionId: current.sessionId, parentId } }),
      });
    } else {
      out.push(parent ? { label: t("forkDivider.from", { name: sessionTitle(parent, t) }) } : undefined);
    }
    current = parent;
  }
  return out;
}

/// The rows with each fork cut drawn as its divider (`dividers`, newest first). The same array
/// when there is nothing to change.
export function withForkDividers(rows: AcpmuxRow[], dividers: readonly (ForkDivider | undefined)[]): AcpmuxRow[] {
  if (dividers.length === 0) return rows;
  let cuts = 0;
  for (const row of rows) if (row.id.startsWith(CUT)) cuts += 1;
  if (cuts === 0) return rows;
  let index = cuts;
  return rows.map((row) => {
    if (!row.id.startsWith(CUT)) return row;
    // The oldest cut on screen is the furthest ancestor's: count back from the newest.
    index -= 1;
    const divider = dividers[index];
    return divider ? { ...row, forkDivider: divider } : row;
  });
}
