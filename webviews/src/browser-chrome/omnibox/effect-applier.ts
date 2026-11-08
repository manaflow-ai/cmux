// The only writer of the omnibar field and card (UI/OmnibarEffectApplier.swift). It compares
// before it writes, so a state that matches the field changes nothing, and it never touches the
// field while the input method has marked text there.
import type { OmnibarPresentation, OmnibarStyle } from "./presentation";
import { rangesEqual } from "./text";
import type { BrowserSuggestion, TextRange } from "./types";

/** The omnibar's text field as the applier sees it (the real input, or a fake in tests). */
export interface OmnibarFieldSurface {
  /** The field has keyboard focus. */
  readonly isFieldEditorActive: boolean;
  readonly currentText: string;
  readonly currentSelection: TextRange;
  /** IME composition is pending in the field. */
  readonly hasMarkedText: boolean;
  write(text: string, style: OmnibarStyle): void;
  select(range: TextRange): void;
}

export interface OmnibarPopupSurface {
  showRows(rows: readonly BrowserSuggestion[], highlighted: number | null): void;
  highlightRow(row: number | null): void;
  dismissRows(): void;
}

interface Written {
  text: string;
  style: OmnibarStyle;
  editorActive: boolean;
}

const stylesEqual = (a: OmnibarStyle, b: OmnibarStyle): boolean =>
  a.kind === b.kind && (a.kind === "plain" || a.url === (b as { url: string | null }).url);

function rowsEqual(a: readonly BrowserSuggestion[], b: readonly BrowserSuggestion[]): boolean {
  return (
    a.length === b.length &&
    a.every((row, index) => {
      const other = b[index];
      return (
        row.kind === other.kind &&
        row.title === other.title &&
        row.detail === other.detail &&
        row.url === other.url &&
        row.score === other.score &&
        (row.content ?? null) === (other.content ?? null) &&
        (row.inlineCompletable ?? true) === (other.inlineCompletable ?? true) &&
        (row.tabKey ?? null) === (other.tabKey ?? null)
      );
    })
  );
}

export class OmnibarEffectApplier {
  private written: Written | null = null;
  private shownRows: readonly BrowserSuggestion[] = [];
  private shownHighlight: number | null = null;
  /** Field writes so far (tests: no write while composing, none per keystroke). */
  textWrites = 0;
  selectionWrites = 0;

  constructor(
    private readonly field: OmnibarFieldSurface,
    private readonly popup: OmnibarPopupSurface,
  ) {}

  apply(presentation: OmnibarPresentation): void {
    this.applyPopup(presentation);
    const field = this.field;
    if (field.hasMarkedText) return;
    const signature: Written = {
      text: presentation.text,
      style: presentation.style,
      editorActive: field.isFieldEditorActive,
    };
    // Write only what the field lacks: other text, focus arriving or leaving, or a new resting
    // style. A keystroke the field already holds is never written back (it would reset the caret).
    const editorChanged = this.written?.editorActive !== signature.editorActive;
    const restingStyleChanged =
      !signature.editorActive && (this.written == null || !stylesEqual(this.written.style, signature.style));
    if (field.currentText !== presentation.text || editorChanged || restingStyleChanged) {
      field.write(presentation.text, presentation.style);
      this.textWrites += 1;
    }
    this.written = signature;
    const selection = presentation.selection;
    if (field.isFieldEditorActive && selection && !rangesEqual(field.currentSelection, selection)) {
      field.select(selection);
      this.selectionWrites += 1;
    }
  }

  private applyPopup(presentation: OmnibarPresentation): void {
    if (presentation.rows.length === 0) {
      if (this.shownRows.length > 0) this.popup.dismissRows();
    } else if (!rowsEqual(presentation.rows, this.shownRows)) {
      this.popup.showRows(presentation.rows, presentation.highlighted);
    } else if (presentation.highlighted !== this.shownHighlight) {
      this.popup.highlightRow(presentation.highlighted);
    }
    this.shownRows = presentation.rows;
    this.shownHighlight = presentation.highlighted;
  }
}
