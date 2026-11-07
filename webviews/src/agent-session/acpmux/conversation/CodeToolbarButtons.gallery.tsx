// l10n-allow-file: gallery fixtures (sample code, a diff, tool output), not shipped UI.
// The corner buttons of a code card, an edit's diff, a tool's output and a reply table (Leo
// 2026-11-07, on a code card's Wrap and Copy on opaque tiles with a gap between them: "why not just
// have it similar to how we have the, you know, the copy button or whatever, where it doesn't
// really have anything until you highlight over it"). Each surface at rest, under the pointer
// (the block hovered, no button), with one button hovered, and with one pressed. The experiment's
// arms (codeActions.experiment.ts) compare bare touching buttons (shipped), bare spaced ones, bare
// ones shown only on the block's hover, and a faint shared strip.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { DiffHunk, TurnFile } from "../diff";
import { ArtifactContext } from "./artifactPreview";
import { codeActionsLook } from "./codeActions.experiment";
import { CodeHeader, codeHeaderClass } from "./CodeHeader";
import { CopyButton } from "./CopyButton";
import { cornerAction } from "./cornerActions";
import { WrapLines } from "./icons";
import { PlainCodeLines } from "./StreamingCode";
import { EditDiff } from "./EditDiff";
import { Markdown } from "./Markdown";
import { ShellBlock } from "./ShellBlock";
import { ToolOutput } from "./ToolOutputBody";

type Surface = "code" | "diff" | "output" | "table";
type Props = { surface: Surface };

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

const SNIPPET = "for (const attempt of [0, 1, 2]) await sleep(retry(attempt));\nreturn fetch(url);";

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

/// The table's Open shows only where the page can open an artifact; the stage's opens nothing.
const openNothing = () => {};

function Stage({ surface }: Props) {
  return (
    <ArtifactContext.Provider value={openNothing}>
      <div className="acpmux-shell" data-gallery-surface={surface} style={{ padding: 16, maxWidth: 640 }}>
        {surface === "code" && (
          <div>
            <HighlightedCorner />
            <Markdown>{CODE}</Markdown>
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

/// The block each surface's buttons belong to, and the toolbar's last button (Copy, or Wrap where
/// a tool output has only Wrap).
const BLOCK: Record<Surface, string> = {
  code: ".cv-codeblock",
  diff: ".cv-edit-diff",
  output: ".cv-shell",
  table: ".cv-table-block",
};
const BUTTONS: Record<Surface, string> = {
  code: ".cv-codeblock .cv-codeblock__actions > button",
  diff: ".cv-edit-diff__header button",
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
    await ctx.hover({ selector: `${BUTTONS[surface]}:last-child` });
  };
const pressed =
  (surface: Surface): Play =>
  async (ctx) => {
    await ctx.hover({ selector: BLOCK[surface] });
    await ctx.pointer.down({ selector: `${BUTTONS[surface]}:first-child` });
  };

const variants = Object.fromEntries(
  (["code", "diff", "output", "table"] as const).flatMap((surface) => [
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
  ]),
);

export default componentEntry<Props>({
  id: "agent-pane.code-toolbar-buttons",
  title: "Code, diff, output and table corner buttons",
  area: "Agent pane",
  pane: true,
  height: 320,
  covers: [
    "agent-session/acpmux/conversation/CodeHeader.tsx",
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
      { name: "Hover the block", run: onBlock("code") },
      { name: "Hover Copy", run: onButton("code") },
    ],
  },
});
