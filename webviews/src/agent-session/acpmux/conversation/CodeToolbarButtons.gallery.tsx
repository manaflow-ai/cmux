// l10n-allow-file: gallery fixtures (sample code, a diff, tool output), not shipped UI.
// The corner buttons of a code card, an edit's diff, a tool's output and a reply table (Leo
// 2026-11-07, on a code card's Wrap and Copy on opaque tiles with a gap between them: "why not just
// have it similar to how we have the, you know, the copy button or whatever, where it doesn't
// really have anything until you highlight over it"). Each surface at rest, under the pointer
// (the block hovered, no button), with one button hovered, and with one pressed. The experiment's
// arms (codeActions.experiment.ts) compare bare touching buttons (shipped), bare spaced ones, bare
// ones shown only on the block's hover, and a faint shared strip.
//
// The `code-veil-*` states hover an unlabeled card whose first line runs past the card, scrolled to
// its start, its middle and its end: the line fades out before the bare glyphs and never paints
// under them (conversation.css `--cv-code-corner-veil`). `hover` ships (the veil comes with the
// glyphs); `always` keeps it at rest too, `cut` has no fade and `wide` fades over 24px.
import { useLayoutEffect, useRef, useState } from "react";
import { File as PierreFile } from "@pierre/diffs";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { DiffHunk, TurnFile } from "../diff";
import { ArtifactContext } from "./artifactPreview";
import { codeActionsLook } from "./codeActions.experiment";
import { CodeHeader } from "./CodeHeader";
import { codeHeaderClass } from "./codeHeaderModel";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, registerAgentDiffTheme } from "../diffTheme";
import { DiffsHost } from "./usePierreCode";
import { cornerUnsafeCSS } from "./highlightedCodeModel";
import { CopyButton } from "./CopyButton";
import { cornerAction } from "./cornerActions";
import { WrapLines } from "./icons";
import { PlainCodeLines } from "./StreamingCode";
import { EditDiff } from "./EditDiff";
import { Markdown } from "./Markdown";
import { ShellBlock } from "./ShellBlock";
import { ToolOutput } from "./ToolOutputBody";

type Surface = "code" | "highlighted" | "diff" | "output" | "table";
/// How the scrolling text under an unlabeled card's corner glyphs is hidden (conversation.css).
type Veil = "hover" | "always" | "cut" | "wide";
type Props = { surface: Surface; veil?: Veil };

const CODE = `An unlabeled block and a labeled one:

\`\`\`
bun run check && bun test test/code-toolbar-buttons.test.ts
\`\`\`

\`\`\`ts
export const retry = (attempt: number) => Math.min(30_000, 250 * 2 ** attempt);
\`\`\`
`;

const TABLE = `| Check | Base | Head |
| --- | ---: | ---: |
| webviews check | 41 s | 43 s |
| bun test | 2 m 10 s | 2 m 12 s |`;

function added(count: number): DiffHunk {
  return {
    lines: Array.from({ length: count }, (_, index) => ({
      type: "add" as const,
      text: `retry(${index + 1}); // back off with full jitter`,
      newLine: index + 1,
    })),
  };
}

const FILE: TurnFile = {
  path: "src/retry-policy.ts",
  displayPath: "src/retry-policy.ts",
  additions: 3,
  deletions: 0,
  created: true,
  edits: [{ toolId: "retry-policy", numbered: true, hunks: [added(3)] }],
};

const OUTPUT = `{"status":"passed","checks":12,"warnings":0}\nwrote coverage/lcov.info\ndone in 4.2s`;

/// Its first line runs past the card, so scrolled anywhere short of its end it reaches the corner.
const SNIPPET =
  "for (const attempt of [0, 1, 2, 3, 4, 5]) await sleep(retry(attempt)).then(() => log.debug(`retry ${attempt} of 6 after backoff`), (error) => log.warn(error));\nreturn fetch(url);";

/// An unlabeled highlighted card's corner, Wrap then Copy, as HighlightedCode.tsx draws it in the
/// app. The gallery has no highlight worker (highlightPool.ts runs only on the app's own schemes),
/// so its fences draw plain with Copy alone; this card keeps the pair Leo saw.
function HighlightedCorner() {
  const [wrap, setWrap] = useState(false);
  return (
    <div className={`cv-codeblock${codeHeaderClass("corner")}`}>
      <CodeHeader look="corner" lang="ts">
        <button
          type="button"
          className={cornerAction()}
          aria-pressed={wrap}
          aria-label="Wrap lines"
          title="Wrap lines"
          onClick={() => setWrap((value) => !value)}
        >
          <WrapLines />
        </button>
        <CopyButton text={SNIPPET} label="Copy code" />
      </CodeHeader>
      <div className="cv-codeblock__body">
        <PlainCodeLines code={SNIPPET} wrap={wrap} />
      </div>
    </div>
  );
}

/// An unlabeled card as HighlightedCode.tsx draws it once highlighted: Pierre's lines in their shadow
/// root, the horizontal scrollbar hanging below the body's box into the card's bottom inset
/// (`codeUnsafeCSS`, 6px in WebKit). The gallery has no highlight worker, so Pierre highlights on
/// the main thread here; the markup and the shadow CSS are the app's. The corner veil's mask must
/// leave that scrollbar painted (cross-model review of #37521).
function PierreCorner() {
  const host = useRef<HTMLDivElement>(null);
  const [painted, setPainted] = useState(false);
  useLayoutEffect(() => {
    const el = host.current;
    if (!el) return;
    registerAgentDiffTheme();
    const file = new PierreFile(
      {
        theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
        themeType: document.documentElement.dataset.theme === "light" ? "light" : "dark",
        disableFileHeader: true,
        disableLineNumbers: true,
        overflow: "scroll",
        unsafeCSS: cornerUnsafeCSS,
        onPostRender: (node, _instance, phase) => {
          if (phase !== "unmount" && node.shadowRoot?.querySelector("[data-line]")) setPainted(true);
        },
      },
      undefined,
      true,
    );
    file.render({ fileContainer: el, file: { name: "snippet.ts", contents: SNIPPET, lang: "ts" } });
    return () => {
      file.cleanUp();
      el.shadowRoot?.replaceChildren();
    };
  }, []);
  return (
    <div className={`cv-codeblock${codeHeaderClass("corner")}`} data-gallery-pierre={painted ? "painted" : "pending"}>
      <CodeHeader look="corner" lang="ts">
        <button
          type="button"
          className={cornerAction()}
          aria-pressed={false}
          aria-label="Wrap lines"
          title="Wrap lines"
        >
          <WrapLines />
        </button>
        <CopyButton text={SNIPPET} label="Copy code" />
      </CodeHeader>
      <DiffsHost ref={host} className="cv-codeblock__body selectable" />
    </div>
  );
}

/// The table's Open shows only where the page can open an artifact; the stage's opens nothing.
const openNothing = () => {};

function Stage({ surface, veil = "hover" }: Props) {
  return (
    <ArtifactContext.Provider value={openNothing}>
      <div
        className="acpmux-shell"
        data-gallery-surface={surface}
        data-corner-veil={veil === "hover" ? undefined : veil}
        style={{ padding: 16, maxWidth: 640 }}
      >
        {surface === "code" && (
          // A set width: the stage frame sizes to its content, and the long first line must scroll
          // inside its card rather than widen it.
          <div style={{ width: "min(608px, calc(100vw - 32px))" }}>
            <HighlightedCorner />
            <Markdown>{CODE}</Markdown>
          </div>
        )}
        {surface === "highlighted" && (
          <div style={{ width: "min(608px, calc(100vw - 32px))" }}>
            <PierreCorner />
          </div>
        )}
        {surface === "diff" && <EditDiff file={FILE} />}
        {surface === "output" && (
          <>
            <ShellBlock command="bun test" output={"12 pass\n0 fail\nRan 12 tests in 4.2s"} exitCode={0} />
            <ToolOutput result={{ text: OUTPUT, lang: "text" }} />
          </>
        )}
        {surface === "table" && <Markdown>{TABLE}</Markdown>}
      </div>
    </ArtifactContext.Provider>
  );
}

/// The block each surface's buttons belong to, and its toolbar's buttons. The plays pick the first
/// and last by `:first-of-type`/`:last-of-type`, never `:first-child`: a diff's header starts with
/// the file's name and counts before its buttons.
const BLOCK: Record<Surface, string> = {
  code: ".cv-codeblock",
  highlighted: ".cv-codeblock",
  diff: ".cv-edit-diff",
  output: ".cv-shell",
  table: ".cv-table-block",
};
const BUTTONS: Record<Surface, string> = {
  code: ".cv-codeblock .cv-codeblock__actions > button",
  highlighted: ".cv-codeblock .cv-codeblock__actions > button",
  diff: ".cv-edit-diff__header > button",
  output: ".cv-shell__actions > button",
  table: ".cv-table-tools > button",
};

const onBlock =
  (surface: Surface): Play =>
  async (ctx) => {
    await ctx.hover({ selector: BLOCK[surface] });
  };
const onButton =
  (surface: Surface): Play =>
  async (ctx) => {
    await ctx.hover({ selector: BLOCK[surface] });
    await ctx.hover({ selector: `${BUTTONS[surface]}:last-of-type` });
  };
const pressed =
  (surface: Surface): Play =>
  async (ctx) => {
    await ctx.hover({ selector: BLOCK[surface] });
    await ctx.pointer.down({ selector: `${BUTTONS[surface]}:first-of-type` });
  };

/// The surface the stage draws, so the experiment's steps press the buttons of the variant Compare
/// shows (a diff, an output or a table has no `.cv-codeblock`).
const activeSurface = (ctx: Parameters<Play>[0]): Surface => {
  const surface = ctx.document.querySelector<HTMLElement>("[data-gallery-surface]")?.dataset.gallerySurface;
  return surface === "highlighted" || surface === "diff" || surface === "output" || surface === "table"
    ? surface
    : "code";
};

/// The unlabeled card hovered (at its centre, on its text, not its glyphs), then its first line
/// scrolled to `at`. The hover comes first: hovering a line inside the scroller would scroll it
/// back into view.
const CORNER_CARD = ".cv-codeblock--corner:first-child";
const veiled =
  (at: "start" | "mid" | "end"): Play =>
  async (ctx) => {
    await ctx.hover({ selector: CORNER_CARD });
    const scroller = ctx.find({ selector: `${CORNER_CARD} .cv-code-plain` }) as HTMLElement;
    const end = scroller.scrollWidth - scroller.clientWidth;
    const left = at === "start" ? 0 : at === "mid" ? Math.round(end / 2) : end;
    scroller.scrollLeft = left;
    await ctx.waitFor(() => Math.abs(scroller.scrollLeft - left) < 1);
  };

/// The highlighted card painted, then at rest (the pointer off the stage) or hovered on its text.
const PIERRE_CARD = "[data-gallery-pierre]";
const pierre =
  (hover: boolean): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector('[data-gallery-pierre="painted"]'));
    if (hover) await ctx.hover({ selector: PIERRE_CARD });
  };

const VEILS: { veil: Veil; at: "start" | "mid" | "end"; note: string }[] = [
  { veil: "hover", at: "start", note: "veil (ships): the long first line at its start fades out before the glyphs." },
  { veil: "hover", at: "mid", note: "veil (ships): scrolled halfway, the line still never runs under the glyphs." },
  { veil: "hover", at: "end", note: "veil (ships): scrolled to its end, the line stops short of the glyphs." },
  { veil: "always", at: "mid", note: "veil always on, at rest too: scrolled halfway." },
  { veil: "cut", at: "mid", note: "a hard cut under the glyphs, no fade: scrolled halfway." },
  { veil: "wide", at: "mid", note: "a 24px fade before the glyphs: scrolled halfway." },
];

const variants = {
  ...Object.fromEntries(
    (["code", "diff", "output", "table"] as const)
      .flatMap((surface) => [
        [surface, { note: `${surface}: at rest.`, props: { surface } }],
        [
          `${surface}-block-hover`,
          {
            note: `${surface}: the pointer on the block, on no button.`,
            props: { surface },
            play: onBlock(surface),
          },
        ],
        [
          `${surface}-button-hover`,
          {
            note: `${surface}: the pointer on its last button.`,
            props: { surface },
            play: onButton(surface),
          },
        ],
        [
          `${surface}-pressed`,
          {
            note: `${surface}: its first button held down.`,
            props: { surface },
            play: pressed(surface),
          },
        ],
      ])
      .concat(
        VEILS.map(({ veil, at, note }) => [
          `code-veil-${veil}-${at}`,
          { note, props: { surface: "code" as const, veil }, play: veiled(at) },
        ]),
      ),
  ),
  "highlighted-rest": {
    note: "highlighted: an unlabeled highlighted card whose first line overflows, at rest; its scrollbar shows under its lines.",
    props: { surface: "highlighted" as const },
    play: pierre(false),
  },
  "highlighted-hover": {
    note: "highlighted: the same card hovered: the veil fades its first line before the glyphs, and the scrollbar still shows.",
    props: { surface: "highlighted" as const },
    play: pierre(true),
  },
};

export default componentEntry<Props>({
  id: "agent-pane.code-toolbar-buttons",
  title: "Code, diff, output and table corner buttons",
  area: "Agent pane",
  pane: true,
  height: 320,
  covers: [
    "agent-session/acpmux/conversation/CodeHeader.tsx",
    "agent-session/acpmux/conversation/HighlightedCode.tsx",
    "agent-session/acpmux/conversation/cornerActions.ts",
    "agent-session/acpmux/conversation/CopyButton.tsx",
    "agent-session/acpmux/conversation/BlockParts.tsx",
    "agent-session/acpmux/conversation/EditDiff.tsx",
    "agent-session/acpmux/conversation/ToolOutputBody.tsx",
    "agent-session/acpmux/conversation/ShellBlock.tsx",
    "agent-session/acpmux/conversation/TableBlock.tsx",
  ],
  load: async () => Stage,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants,
  experiment: {
    definition: codeActionsLook,
    script: [
      { name: "Hover the block", run: (ctx) => onBlock(activeSurface(ctx))(ctx) },
      { name: "Hover the last button", run: (ctx) => onButton(activeSurface(ctx))(ctx) },
    ],
  },
});
