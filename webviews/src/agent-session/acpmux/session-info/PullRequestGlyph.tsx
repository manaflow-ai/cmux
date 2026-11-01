// A pull request's state as Claude Code desktop's Changes draws it: by the glyph's shape, colored
// by the row (sessionInfo.css `[data-state]`), never by a word. Open is the pack's
// `git.pullrequest`; merged has one stem curving into the merge; a draft crosses out its base
// node; closed (and an open one with conflicts) crosses out its head. Drawn here because the icon
// pack (icons/cmuxIcons.json) has only the open glyph; the strokes match it (24 grid, 1.5 wide,
// cropped like a row icon).
import { ROW_VIEWBOX } from "../icons/iconSize";

export type PullRequestGlyphState = "open" | "draft" | "merged" | "closed" | "conflicting";

const NODE = 2.25;
const node = (cx: number, cy: number) => <circle cx={cx} cy={cy} r={NODE} />;
/// The head branch's stem, from the base's side over to the right node, with the pack's arrow.
const HEAD = "M17.5 16L17.5 9.5C17.5 7.843 16.157 6.5 14.5 6.5L11.5 6.5";
const ARROW = "M13.5 4L11 6.5L13.5 9";
const cross = (cx: number, cy: number) =>
  `M${cx - 2} ${cy - 2}L${cx + 2} ${cy + 2}M${cx + 2} ${cy - 2}L${cx - 2} ${cy + 2}`;

function strokes(state: PullRequestGlyphState) {
  switch (state) {
    case "merged":
      return (
        <>
          {node(6.5, 5.5)}
          <path d="M6.5 7.75L6.5 20.75M6.5 9.5C6.5 13 9.5 15.5 15.25 15.5" />
          {node(17.5, 15.5)}
        </>
      );
    case "draft":
      return (
        <>
          <path d={`${cross(6.5, 5.5)}M6.5 11L6.5 17`} />
          <path d={HEAD} />
          {node(17.5, 18.5)}
        </>
      );
    case "closed":
    case "conflicting":
      return (
        <>
          {node(6.5, 5.5)}
          <path d="M6.5 7.75L6.5 16.25" />
          {node(6.5, 18.5)}
          <path d={`${cross(17.5, 5.5)}M17.5 10.5L17.5 16.25`} />
          {node(17.5, 18.5)}
        </>
      );
    default:
      return (
        <>
          <path d={`M6.5 7.75L6.5 16.25${HEAD}${ARROW}`} />
          {node(6.5, 5.5)}
          {node(6.5, 18.5)}
          {node(17.5, 18.5)}
        </>
      );
  }
}

export function PullRequestGlyph({ state, size }: { state: PullRequestGlyphState; size: number }) {
  return (
    <svg
      className="acpmux-session-info-pr__glyph"
      data-glyph={state}
      width={size}
      height={size}
      viewBox={ROW_VIEWBOX}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      overflow="visible"
      aria-hidden="true"
      focusable="false"
    >
      {strokes(state)}
    </svg>
  );
}
