// l10n-allow-file: gallery labels and row titles are fixture content, not shipped UI.
import { componentEntry } from "../gallery/format";
import { OrbitDots } from "./OrbitDots";
import { StatusGlyph } from "./StatusGlyph";
import { STATUS_GLYPH_SETS } from "./statusGlyphs.generated";

type State = "working" | "waiting" | "permission" | "done" | "error" | "idle";
type Row = { title: string; state: State; sessions?: { title: string; state: State }[] };

/** A sidebar's workspaces: an agent at work with two sessions, then each other state. */
const ROWS: Row[] = [
  {
    title: "cmux-next",
    state: "working",
    sessions: [
      { title: "Fix the sidebar hover card", state: "working" },
      { title: "zsh", state: "idle" },
    ],
  },
  { title: "deploy", state: "permission" },
  { title: "review the branch", state: "waiting" },
  { title: "api", state: "error" },
  { title: "web", state: "done" },
  { title: "docs", state: "idle" },
];

type Look = "before" | "after" | "reduced";

/** One row's mark in `look`: before, the Codex-like set on the right (a grey spinner for work);
 * after, the Orbit set on the left; reduced, the static look on the left. */
function Mark({ state, look }: { state: State; look: Look }) {
  if (state === "idle") return null;
  if (state === "working") {
    if (look === "after") return <OrbitDots label="Working" />;
    if (look === "reduced") return <StatusGlyph name="working" label="Working" />;
    return <span className="running-dots-spinner" aria-hidden="true" />;
  }
  const pick = STATUS_GLYPH_SETS.codex[state];
  return <StatusGlyph name={pick.glyph} tint={pick.tint} label={state} />;
}

function Item({ title, state, look, session = false }: { title: string; state: State; look: Look; session?: boolean }) {
  const left = look !== "before";
  return (
    <li className="running-dots-row" data-session={session || undefined}>
      {left && (
        <span className="running-dots-slot">
          <Mark state={state} look={look} />
        </span>
      )}
      <span className="running-dots-title">{title}</span>
      {!left && (
        <span className="running-dots-slot">
          <Mark state={state} look={look} />
        </span>
      )}
    </li>
  );
}

function Sidebar({ look }: { look: Look }) {
  return (
    <ul className="running-dots-sidebar" data-look={look}>
      {ROWS.map((row) => [
        <Item key={row.title} title={row.title} state={row.state} look={look} />,
        ...(row.sessions ?? []).map((session) => (
          <Item key={`${row.title}/${session.title}`} title={session.title} state={session.state} look={look} session />
        )),
      ])}
    </ul>
  );
}

function RunningDotsSheet({ looks = ["before", "after"] }: { looks?: Look[] }) {
  const titles: Record<Look, string> = {
    before: "Before: Codex-like, on the right",
    after: "After: Orbiting dots, on the left",
    reduced: "Reduce Motion: the static look",
  };
  return (
    <div className="running-dots-stage">
      {looks.map((look) => (
        <figure key={look} className="running-dots-panel">
          <figcaption>{titles[look]}</figcaption>
          <Sidebar look={look} />
        </figure>
      ))}
      <figure className="running-dots-panel running-dots-zoom">
        <figcaption>The mark at 6x</figcaption>
        <OrbitDots size={60} />
      </figure>
    </div>
  );
}

export default componentEntry<{ looks?: Look[] }>({
  id: "ui.running-dots",
  title: "Running dots",
  area: "UI primitives",
  height: 360,
  covers: ["ui/OrbitDots.tsx#OrbitDots"],
  load: async () => RunningDotsSheet,
  styles: () => Promise.all([import("./ui.css"), import("./OrbitDots.gallery.css")]),
  variants: {
    rows: {
      note: "Leo 2026-10-18: a running row's mark on the left, like Claude Code's four orange dots that slowly turn and regroup. The web copy of the app's Orbit set (StatusIndicatorLayer+Orbit.swift) on sidebar rows and the sessions under them, next to the Codex-like look it replaces. One turn per 3.6 s, a regroup per 1.8 s, nothing fades.",
      props: {},
    },
    "reduce-motion": {
      note: "Under Reduce Motion or the Static mode nothing moves: the static look's working glyph takes the slot.",
      props: { looks: ["after", "reduced"] },
    },
  },
});
