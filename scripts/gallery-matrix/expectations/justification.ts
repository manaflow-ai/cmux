// The PR body's justification block: one line per changed surface, saying whether the change is
// better, worse, intentional or neutral, and why. The gate puts each line next to that surface's
// before | after | diff, so a reviewer only decides "do we want this".
//
//   ## Visual changes
//   - web/ui.menu: better — the menu adopts the shared transient veil
//   - ios/team-appearance#sheet: intentional — sheets are translucent per design/transient-material.md
//
// A ref is `<platform>/<surface id>`, optionally `#<state>` for one state only. Any heading level
// works; the block ends at the next heading. A dash, en dash, em dash or colon separates the verdict
// from the reason.

export const VERDICTS = ["better", "worse", "intentional", "neutral", "removed"] as const;
export type Verdict = (typeof VERDICTS)[number];
export type Justification = { ref: string; state?: string; verdict: Verdict; reason: string; line: number };
export type Parsed = { justifications: Justification[]; problems: string[] };

const HEADING = /^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$/;
const ITEM = /^\s*[-*+]\s+`?([a-z]+\/[a-z0-9][a-z0-9.-]*)(?:#([a-z0-9][a-z0-9.-]*))?`?\s*[:(]\s*([A-Za-z]+)\s*\)?\s*(?:[—–:-]\s*)?(.*)$/;

export function parseJustifications(body: string): Parsed {
  const justifications: Justification[] = [];
  const problems: string[] = [];
  let inBlock = false;
  let inFence = false;
  body.split(/\r?\n/).forEach((text, index) => {
    if (/^\s*(```|~~~)/.test(text)) inFence = !inFence;
    if (inFence) return;
    const heading = HEADING.exec(text);
    if (heading) {
      inBlock = /^visual changes?\b/i.test(heading[1]!.trim());
      return;
    }
    if (!inBlock || !/^\s*[-*+]\s+/.test(text)) return;
    const item = ITEM.exec(text);
    if (!item) {
      problems.push(`line ${index + 1}: not "- platform/surface: verdict — reason": ${text.trim().slice(0, 120)}`);
      return;
    }
    const verdict = item[3]!.toLowerCase() as Verdict;
    if (!VERDICTS.includes(verdict)) {
      problems.push(`line ${index + 1}: verdict "${item[3]}" is not one of ${VERDICTS.join(", ")}`);
      return;
    }
    const reason = item[4]!.trim();
    if (reason.length < 8) {
      problems.push(`line ${index + 1}: ${item[1]} needs a reason, not just "${verdict}"`);
      return;
    }
    justifications.push({ ref: item[1]!, state: item[2], verdict, reason, line: index + 1 });
  });
  return { justifications, problems };
}

/** The justification for one state: a state-specific line wins over the surface's line. */
export function justificationFor(list: readonly Justification[], ref: string, state: string): Justification | undefined {
  return list.find((j) => j.ref === ref && j.state === state) ?? list.find((j) => j.ref === ref && !j.state);
}
