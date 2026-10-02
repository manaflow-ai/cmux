// Icon buttons of the transcript.
import type { CSSProperties, ReactNode } from "react";
import { ArrowDown, Copy } from "./icons";

export function IconButton({ children, label, style }: { children: ReactNode; label: string; style?: CSSProperties }) {
  return (
    <button type="button" className="cv-iconbtn" aria-label={label} style={style}>
      {children}
    </button>
  );
}

/** Copy button (16px icon in a 28px hit box). */
export function CopyButton({ label = "Copy" }: { label?: string }) {
  return (
    <IconButton label={label}>
      <Copy />
    </IconButton>
  );
}

/** Round "scroll to bottom" button; place it with `style` in thread coordinates. */
export function ScrollToBottom({ style }: { style?: CSSProperties }) {
  return (
    <button type="button" className="cv-scrolldown" aria-label="Scroll to bottom" style={style}>
      <ArrowDown size={16} strokeWidth={1.3} />
    </button>
  );
}
