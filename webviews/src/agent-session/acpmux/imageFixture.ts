// l10n-allow-file: debug fixture messages, not shipped UI.
// A reply holding a wide, short screenshot, for `debug.agent_pane seed_rows` with `fixture: "image"`: a
// capture opens it in the real app's image viewer (scripts/cmux-next/media/tours/image-viewer-lightbox.json).
// Leo, 2026-11-27, of the viewer over a pasted "Screenshot · 1042×216": "ok the screenshots thing needs to
// not opaque out everything else. just have what normal standards are for this. some lowered opaity?"
import type { AcpmuxRow } from "./model";

export const IMAGE_FIXTURE_NAME = "Screenshot · 1042×216";
const SCREENSHOT = `<svg xmlns="http://www.w3.org/2000/svg" width="521" height="108" viewBox="0 0 521 108"><rect width="521" height="108" fill="#1f2937"/><rect x="12" y="12" width="497" height="28" rx="6" fill="#374151"/><circle cx="28" cy="26" r="6" fill="#f87171"/><rect x="44" y="20" width="180" height="12" rx="3" fill="#e5e7eb"/><rect x="12" y="52" width="320" height="12" rx="3" fill="#9ca3af"/><rect x="12" y="74" width="420" height="12" rx="3" fill="#6b7280"/></svg>`;

export function imageRows(at: number): AcpmuxRow[] {
  return [
    { id: "image-ask", version: 1, at, kind: "user", text: "Screenshot the settings row" },
    {
      id: "image-reply",
      version: 1,
      at: at + 3_000,
      kind: "assistant",
      text: `Here it is; the second line is cut off at the right edge.\n\n![${IMAGE_FIXTURE_NAME}](data:image/svg+xml;base64,${btoa(SCREENSHOT)})`,
    },
    { id: "image-summary", version: 1, at: at + 3_000, kind: "turnSummary", durationMs: 3_000, toolCount: 0 },
  ] as AcpmuxRow[];
}
