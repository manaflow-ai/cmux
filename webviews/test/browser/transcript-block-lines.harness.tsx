// l10n-allow-file: test fixture output, not shipped UI.
// Long blocks inside a transcript column (transcript-block-lines-window-browser.test.ts): a finished
// Shell block whose output wraps, a call's output and a read past the highlight limits, each in its
// own eight-line box, with a reader's row under them in a scrolling column, as a transcript holds
// them; and a read within the limits ("code"), which Pierre highlights in its shadow root. `window.__blockLines.draw(kind, lines)` draws one; the test scrolls its box and reads the
// page back.
import { createRoot } from "react-dom/client";
import { ShellBlock } from "../../src/agent-session/acpmux/conversation/ShellBlock";
import { ToolOutput } from "../../src/agent-session/acpmux/conversation/ToolOutputBody";
import { FileResultCard } from "../../src/agent-session/acpmux/conversation/FileResultCard";
import { paintFindHighlights } from "../../src/agent-session/acpmux/conversation/chatFind";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";

// The pane's English strings, as its head installs them (i18n.ts): a windowed box's name.
globalThis.__cmuxPaneStrings = { en: strings.en };

export type BlockKind = "shell" | "output" | "read" | "code";

/// Every seventh line is long enough to wrap in the column, so a wrapped output's lines differ in height.
export const sourceLine = (index: number) =>
  index % 7 === 3 ? `line ${index} ${"wrapped words ".repeat(14)}`.trimEnd() : `line ${index}`;
const source = (lines: number) => Array.from({ length: lines }, (_, index) => sourceLine(index)).join("\n");

/// A highlighted read's line `index`: TypeScript with a block comment over three lines in every
/// hundred, so a line inside one is colored as a comment only when the lines before it were read.
export const codeLine = (index: number) =>
  index % 100 === 40
    ? `/* comment ${index} opens`
    : index % 100 === 41
      ? `const inside${index} = ${index};`
      : index % 100 === 42
        ? `closes ${index} */`
        : `const line${index} = ${index};`;
const codeSource = (lines: number) => Array.from({ length: lines }, (_, index) => codeLine(index)).join("\n");

/// `reveal` is Find in Chat's: a new one opens the block whole (blockPartsModel.ts `usePreview`).
function Block({ kind, lines, reveal }: { kind: BlockKind; lines: number; reveal: number }) {
  const text = source(lines);
  if (kind === "shell") return <ShellBlock command="seq" output={`${text}\n`} reveal={reveal} />;
  if (kind === "output") return <ToolOutput result={{ text, lang: "text" }} reveal={reveal} />;
  if (kind === "code")
    return (
      <FileResultCard
        id="read"
        reveal={reveal}
        card={{ kind: "read", read: { path: "/tmp/big.ts", start: 1, end: lines, code: codeSource(lines) } }}
      />
    );
  return (
    <FileResultCard
      id="read"
      reveal={reveal}
      card={{ kind: "read", read: { path: "/tmp/big.txt", start: 1, end: lines, code: text } }}
    />
  );
}

const root = createRoot(document.getElementById("root")!);

(window as unknown as { __blockLines: unknown }).__blockLines = {
  draw(kind: BlockKind, lines: number, reveal = 0) {
    root.render(
      <div id="column" data-row-id="row" style={{ height: 600, width: 640, overflowY: "auto" }}>
        <div className="cv-md" style={{ height: 200 }} />
        <Block kind={kind} lines={lines} reveal={reveal} />
        <div id="reader" style={{ height: 800 }}>
          the reader's row
        </div>
      </div>,
    );
  },
  /// Unmounts the block and the column around it.
  clear() {
    root.render(null);
  },
  /// Paints Find's highlights for `query` over the column, as the transcript does once a row mounts;
  /// the active match's text, or null.
  find(query: string, occurrence: number) {
    const range = paintFindHighlights(document.getElementById("root")!, query, {
      rowId: "row",
      card: false,
      occurrence,
    });
    return range?.toString() ?? null;
  },
};
