/// The composer's bolt glyph (FastToggle.tsx draws the same one for Codex's speed toggle): the `/`
/// menu's Fast row (Composer.tsx SlashMenu) shows it beside the plain name Fast, in the row's ink,
/// and the model button shows it beside the model while Fast mode is on.
///
/// A filled bolt whose corners a round-joined stroke of the same ink softens: slightly blobby, never
/// sharp, and less round than ChatGPT's. Leo 2026-10-20: "I want a cute freaking lightning bolt
/// icon ... I don't want it to be like a sharp one. I think the slightly blobby one is a bit nice,
/// but I don't think we want as blobby as ChatGPT does it." The path is the old outline bolt scaled
/// 0.88 about the box's centre, so the 0.8 stroke round each edge keeps it in the same 16 px box.
export function BoltIcon({ size = 16 }: { size?: number }) {
  return (
    <svg
      className="acpmux-icon"
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="currentColor"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M9.06 2.28 4.13 8.88h3.61l-.88 4.84 5.01-6.6H8.26Z" />
    </svg>
  );
}
