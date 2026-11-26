/// What the composer's access chip decided its face from, on its last render (ComposerPickers.tsx):
/// the debug `chat_state` verb returns it next to the chip text, so a live journey that reads a bare
/// "Mode" (scripts/cmux-next/cloud-composer-journey.py) says which input left it there.
export const chipProbe: { last: Record<string, unknown> | null } = { last: null };
