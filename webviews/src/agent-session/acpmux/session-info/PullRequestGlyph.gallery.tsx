// l10n-allow-file: gallery fixtures (sample pull requests), not shipped UI.
// Session Info's Changes glyphs beside the panel's other row icons (the machine, folder and branch
// above, Sources' `git.pullrequest` below), one pull request in each state: open, draft, with
// conflicts, merged and closed. Leo, 2026-11-03: "these icons in the changes are kinda ugly".
// The shipped variant draws the cmux pack's pull-request family (PullRequestGlyph.tsx); the others
// are the alternatives it was picked over, drawn into the same rows so only the glyph differs.
import { useLayoutEffect, useRef } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { sessionSummary } from "../summary/sessionSummary";
import type { SummaryPullRequest } from "../summary/sessionSummary";
import { PULL_REQUEST_ICONS, type PullRequestGlyphState } from "./PullRequestGlyph";
import { SessionInfo, SessionInfoPanel } from "./SessionInfo";
import { DEFAULT_SECTIONS } from "./sessionInfoState";

type Glyphs = "pack" | "hand-drawn" | "pack-solid";

const pr = (repo: string, number: number, title: string, state: SummaryPullRequest["state"] = "open") => ({
  url: `https://github.com/${repo}/pull/${number}`,
  repo,
  number,
  title,
  opened: true,
  state,
});
const pullRequests: SummaryPullRequest[] = [
  pr("manaflow-ai/cmux", 32813, "perf(agent-chat): keep the transcript's rows while it streams"),
  pr("manaflow-ai/cmux", 32828, "Session Info: the grip sits left of the title"),
  pr("manaflow-ai/cmux", 32831, "Session Info: fold the long sections under Show more"),
  pr("manaflow-ai/cmux", 32850, "Session Info: the machine first, then Context", "merged"),
  pr("acme/billing", 7, "billing: retry webhooks on a 502", "closed"),
];
const summary = sessionSummary([]);
const statuses = {
  [pullRequests[0]!.url]: { additions: 214, deletions: 31, checks: "passing" },
  [pullRequests[1]!.url]: { state: "draft", additions: 48, deletions: 12, checks: "pending" },
  [pullRequests[2]!.url]: { mergeable: "conflicting", additions: 96, deletions: 40 },
  [pullRequests[3]!.url]: { additions: 1_204, deletions: 380 },
  [pullRequests[4]!.url]: { additions: 18, deletions: 2 },
};

/// The glyphs Changes drew before this entry (Claude Code desktop's shapes, hand-drawn in
/// PullRequestGlyph.tsx): kept here only to compare.
const node = (cx: number, cy: number) => `<circle cx="${cx}" cy="${cy}" r="2.25"/>`;
const HEAD = "M17.5 16L17.5 9.5C17.5 7.843 16.157 6.5 14.5 6.5L11.5 6.5";
const cross = (cx: number, cy: number) =>
  `M${cx - 2} ${cy - 2}L${cx + 2} ${cy + 2}M${cx + 2} ${cy - 2}L${cx - 2} ${cy + 2}`;
const HAND_DRAWN: Record<PullRequestGlyphState, string> = {
  open: `<path d="M6.5 7.75L6.5 16.25${HEAD}M13.5 4L11 6.5L13.5 9"/>${node(6.5, 5.5)}${node(6.5, 18.5)}${node(17.5, 18.5)}`,
  merged: `${node(6.5, 5.5)}<path d="M6.5 7.75L6.5 20.75M6.5 9.5C6.5 13 9.5 15.5 15.25 15.5"/>${node(17.5, 15.5)}`,
  draft: `<path d="${cross(6.5, 5.5)}M6.5 11L6.5 17"/><path d="${HEAD}"/>${node(17.5, 18.5)}`,
  closed: `${node(6.5, 5.5)}<path d="M6.5 7.75L6.5 16.25"/>${node(6.5, 18.5)}<path d="${cross(17.5, 5.5)}M17.5 10.5L17.5 16.25"/>${node(17.5, 18.5)}`,
  conflicting: "",
};
HAND_DRAWN.conflicting = HAND_DRAWN.closed;

/// The pack's Solid form of the shipped glyphs (2-wide stems, filled nodes): what `selected` draws.
const SOLID: Record<PullRequestGlyphState, string> = {
  open: `<path d="M6.5 8v8M17.5 16V9.5a3 3 0 0 0-3-3h-3M13.5 4l-2.5 2.5 2.5 2.5"/>`,
  merged: `<path d="M6.5 8v8M6.5 8c0 2.75 2.5 4 8.75 4"/>`,
  draft: `<path d="M6.5 8v8M17.5 13.5v.75M17.5 8.75v.75M17.5 4v.75"/>`,
  closed: `<path d="M6.5 8v8M15.5 4l4 4M19.5 4l-4 4M17.5 11v5"/>`,
  conflicting: "",
};
SOLID.conflicting = SOLID.closed;
const SOLID_NODES: Record<PullRequestGlyphState, [number, number][]> = {
  open: [
    [6.5, 5.5],
    [6.5, 18.5],
    [17.5, 18.5],
  ],
  merged: [
    [6.5, 5.5],
    [6.5, 18.5],
    [17.5, 12],
  ],
  draft: [
    [6.5, 5.5],
    [6.5, 18.5],
    [17.5, 18.5],
  ],
  closed: [
    [6.5, 5.5],
    [6.5, 18.5],
    [17.5, 18.5],
  ],
  conflicting: [
    [6.5, 5.5],
    [6.5, 18.5],
    [17.5, 18.5],
  ],
};

/// Draws an alternative into each Changes row's glyph after mount, so the rows stay the shipped ones.
function drawAlternative(root: HTMLElement, glyphs: Glyphs) {
  if (glyphs === "pack") return;
  for (const row of root.querySelectorAll<HTMLElement>(".acpmux-session-info-pr")) {
    const svg = row.querySelector<SVGSVGElement>("svg.acpmux-session-info-pr__glyph");
    const state = row.dataset.state as PullRequestGlyphState | undefined;
    if (!svg || !state) continue;
    svg.dataset.alternative = glyphs;
    if (glyphs === "hand-drawn") {
      svg.setAttribute("fill", "none");
      svg.setAttribute("stroke", "currentColor");
      svg.setAttribute("stroke-width", "1.5");
      svg.setAttribute("stroke-linecap", "round");
      svg.setAttribute("stroke-linejoin", "round");
      svg.innerHTML = HAND_DRAWN[state];
    } else {
      const nodes = SOLID_NODES[state].map(([x, y]) => `<circle cx="${x}" cy="${y}" r="2.5" fill="currentColor"/>`);
      svg.innerHTML = `<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${SOLID[state]}</g>${nodes.join("")}`;
    }
  }
}

function ChangesGlyphs({ glyphs = "pack" }: { glyphs?: Glyphs }) {
  const root = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (root.current) drawAlternative(root.current, glyphs);
  });
  return (
    <div
      ref={root}
      className="acpmux-shell"
      style={{ display: "flex", justifyContent: "flex-end", height: "100%" }}
      data-glyphs={glyphs}
    >
      <SessionInfoPanel width={320} placement="overlay">
        <SessionInfo
          summary={{ sessionId: "gallery-changes-glyphs" }}
          made={{
            ...summary,
            pullRequests,
            sources: [
              {
                url: "https://github.com/acme/billing/pull/9",
                label: "billing: the 502 retry issue",
                kind: "pullRequest",
              },
              { label: "src/net/fetch.ts", kind: "file" },
            ],
          }}
          statuses={statuses}
          machineName="Studio"
          repository="manaflow-ai/cmux"
          // Changes is one of the sections the default view holds behind Show more (#32939): open it, so
          // the rows this entry compares are drawn.
          more
          sections={{
            ...DEFAULT_SECTIONS,
            context: false,
            subagents: false,
            tasks: false,
            changes: true,
            sources: true,
          }}
        />
      </SessionInfoPanel>
    </div>
  );
}

/// Every state's row draws its glyph, in the pack's names when shipped.
const glyphsDrawn =
  (glyphs: Glyphs): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-session-info-pr").length === pullRequests.length);
    for (const row of ctx.document.querySelectorAll<HTMLElement>(".acpmux-session-info-pr")) {
      const svg = row.querySelector<SVGSVGElement>("svg.acpmux-session-info-pr__glyph");
      if (!svg) throw new Error(`Changes row ${row.dataset.state} has no glyph`);
      const state = row.dataset.state as PullRequestGlyphState;
      if (glyphs === "pack" && svg.dataset.icon !== PULL_REQUEST_ICONS[state])
        throw new Error(`Changes row ${state} draws ${svg.dataset.icon}, not ${PULL_REQUEST_ICONS[state]}`);
      if (glyphs !== "pack" && svg.dataset.alternative !== glyphs)
        throw new Error(`Changes row ${state} kept the pack glyph`);
      const box = svg.getBoundingClientRect();
      if (Math.round(box.width) !== 14 || Math.round(box.height) !== 14)
        throw new Error(`Changes row ${state}'s glyph is ${box.width}x${box.height}, not the rows' 14`);
    }
    const states = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-session-info-pr")].map(
      (row) => row.dataset.state,
    );
    if (states.join() !== "conflicting,draft,open,closed,merged") throw new Error(`Changes rows are ${states.join()}`);
  };

export default componentEntry({
  id: "agent-pane.session-info-changes-glyphs",
  title: "Session Info Changes glyphs",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 340, normal: 360 },
  covers: [
    "agent-session/acpmux/session-info/PullRequestGlyph.tsx",
    "agent-session/acpmux/session-info/ChangesSection.tsx",
  ],
  load: async () => ChangesGlyphs,
  variants: {
    pack: {
      note: "Chosen: the cmux pack's pull-request family (git.pullrequest and its merged, draft and closed forms) at the panel's 14 pt row size and 1.5 stroke, the same family and weight as Sources' pull request and the Environment's branch. Merged curves its head into the base stem (three nodes), a draft dots its head stem, closed or conflicting crosses out its head. Colored by state.",
      props: { glyphs: "pack" },
      play: glyphsDrawn("pack"),
    },
    "hand-drawn": {
      note: "Alternative (the glyphs before): Claude Code desktop's shapes, hand-drawn. Merged is a bare stem with one branch node, the draft crosses out its base node; they read as a different family from the panel's other icons.",
      props: { glyphs: "hand-drawn" },
      play: glyphsDrawn("hand-drawn"),
    },
    "pack-solid": {
      note: "Alternative: the shipped shapes in the pack's Solid form (2-wide stems, filled nodes). Heavier than every other row icon in the panel, which are Line; Solid is for selected rows.",
      props: { glyphs: "pack-solid" },
      play: glyphsDrawn("pack-solid"),
    },
  },
});
