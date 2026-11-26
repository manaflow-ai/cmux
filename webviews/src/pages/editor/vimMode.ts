// Vim keys for the code editor (`editor.vimMode`). view.ts imports this module only when the setting
// is on, so the editor's first load never fetches it. monaco-vim (MIT; CodeMirror's vim keymap on a
// Monaco adapter) runs from its TypeScript source on the page's own Monaco: its published dist
// inlines Monaco 0.33 internals, so vite.config.ts points `monaco-vim` at `src/index.ts` and its
// deep imports at Monaco 0.57 (vimShiftCommand.ts). Keys vim does not map (Cmd chords, Cmd-S) fall
// through to Monaco and the app's dispatcher; Escape in Insert goes back to Normal.
import type * as monaco from "monaco-editor/editor/editor.api.js";
import { initVimMode, StatusBar } from "monaco-vim";

type ModeEvent = { mode: string; subMode?: string };

/** The mode as the status bar shows it: NORMAL, INSERT, VISUAL, VISUAL LINE, VISUAL BLOCK, REPLACE. */
export function modeLabel(event: ModeEvent): string {
  if (event.mode === "visual" && event.subMode === "linewise") return "VISUAL LINE";
  if (event.mode === "visual" && event.subMode === "blockwise") return "VISUAL BLOCK";
  return event.mode.toUpperCase();
}

/** monaco-vim's status bar with plain mode names, and the mode on the node (`data-vim-mode`). */
class ModeLine extends StatusBar {
  private readonly line: HTMLElement;
  constructor(
    node: HTMLElement,
    editor: monaco.editor.IStandaloneCodeEditor,
    sanitizer?: ((node: Node) => Node) | null,
  ) {
    super(node, editor as never, sanitizer);
    this.line = node;
    this.setMode({ mode: "normal" });
  }
  override setMode(event: ModeEvent): void {
    this.line.dataset.vimMode = event.mode;
    this.setText(modeLabel(event));
  }
}

export interface VimHandle {
  /** Vim off: Monaco's own keys, the mode line hidden and emptied. */
  dispose(): void;
  /** The editor's options were re-applied (look change): Normal and Visual keep the block cursor. */
  restyle(): void;
}

/** Turns vim on for `editor`; the mode line and the `:` prompt render into `node`. */
export function startVim(editor: monaco.editor.IStandaloneCodeEditor, node: HTMLElement): VimHandle {
  const adapter = initVimMode(editor as never, node, ModeLine as never);
  let mode = "normal";
  adapter.on("vim-mode-change", (event: ModeEvent) => {
    mode = event.mode;
  });
  return {
    dispose: () => {
      adapter.dispose();
      delete node.dataset.vimMode;
    },
    restyle: () => {
      if (mode !== "insert" && mode !== "replace") adapter.enterVimMode();
    },
  };
}
