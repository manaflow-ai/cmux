// The NORMAL or INSERT tag at the start of the composer's actions while vim mode is on
// (agentPane.vimMode; composerVim.ts), as vim's own mode line and Claude Code's `-- INSERT --`.
import type { VimMode } from "./composerVim";
import "./vimModeTag.css";

export function VimModeTag({ mode, label }: { mode: VimMode; label: string }) {
  return (
    <span className="acpmux-vim-mode" data-vim-mode={mode} aria-live="polite">
      {label}
    </span>
  );
}
