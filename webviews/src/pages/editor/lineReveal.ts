import type { editor } from "monaco-editor/editor/editor.api.js";
import { fileLocation, type FileLocation } from "../../fileLocation";

/** A transient whole-line decoration; one timeout, cancelled on a new jump, load or disposal. */
export class LineReveal {
  private decorations: editor.IEditorDecorationsCollection | null = null;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private layout: { dispose(): void } | undefined;

  constructor(private readonly editor: editor.IStandaloneCodeEditor) {}

  reveal(value: FileLocation): void {
    const location = fileLocation(value);
    const model = this.editor.getModel();
    if (!location || !model) return;
    this.clear();
    const lineNumber = Math.min(location.line, model.getLineCount());
    const column = Math.min(location.column ?? 1, model.getLineMaxColumn(lineNumber));
    const endLineNumber = Math.min(location.endLine ?? lineNumber, model.getLineCount());
    const center = () => {
      this.editor.setPosition({ lineNumber, column });
      // The position, not only the line: a column far right on a long line scrolls sideways too.
      // Immediate scrolling obeys the motion gate even when editor.smoothScrolling is enabled.
      this.editor.revealPositionInCenter({ lineNumber, column }, 1 /* ScrollType.Immediate */);
    };
    center();
    // The page's keyboard focus goes to the editor (a Find result is typed into next), as base's
    // reveal did. The host still decides whether the page itself takes the window's focus.
    this.editor.focus();
    if (this.editor.getLayoutInfo().height === 0) {
      this.layout = this.editor.onDidLayoutChange(({ height }) => {
        if (height === 0) return;
        this.layout?.dispose();
        this.layout = undefined;
        center();
      });
    }
    this.decorations = this.editor.createDecorationsCollection([
      {
        range: { startLineNumber: lineNumber, startColumn: 1, endLineNumber, endColumn: 1 },
        options: { isWholeLine: true, className: "ed-line-reveal" },
      },
    ]);
    this.timer = setTimeout(() => this.clearHighlight(), 1500);
  }

  private clearHighlight(): void {
    clearTimeout(this.timer);
    this.timer = undefined;
    this.decorations?.clear();
    this.decorations = null;
  }

  clear(): void {
    this.clearHighlight();
    this.layout?.dispose();
    this.layout = undefined;
  }
}
