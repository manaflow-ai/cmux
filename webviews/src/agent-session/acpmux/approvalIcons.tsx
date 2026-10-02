// The approval menu's glyphs (16px box, stroke in currentColor), after Codex's in
// manaflow-ai/codex-atlas-clone (src/sota/icons.tsx). Full access reuses ShieldIcon.

const Glyph = ({ children }: { children: React.ReactNode }) => (
  <svg
    className="acpmux-icon"
    width={16}
    height={16}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.25}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
  >
    {children}
  </svg>
);

/// A raised hand: the agent asks first.
export const HandIcon = () => (
  <Glyph>
    <path d="M5.4 8.6V3.9a1 1 0 0 1 2 0v3.6M7.4 7.2V2.8a1 1 0 0 1 2 0v4.4M9.4 7.2V3.6a1 1 0 0 1 2 0v4.6M11.4 8.2V5.6a1 1 0 0 1 2 0v3.6c0 2.9-2 4.9-4.6 4.9-1.6 0-2.8-.7-3.7-2L3 9.6a1 1 0 0 1 1.5-1.3l.9.9" />
  </Glyph>
);

/// A badge with a prompt: the agent approves what it judges safe.
export const ApproveIcon = () => (
  <Glyph>
    <path d="M8 1.9 13.3 4.9v6.2L8 14.1 2.7 11.1V4.9Z" />
    <path d="M5.6 6.4 7.2 8 5.6 9.6M8.4 9.8h2" />
  </Glyph>
);
