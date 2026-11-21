// The + menu's captures (Attach Screenshot…, Attach Window…, Record Screen…) as the host answers
// them (`composer.capture`, AgentPaneCapture.swift). Record Screen… (Leo, 2026-11-07: "could we also
// have a more native screenshot/screensharer (ergonomic one)/video recording of the app type
// thing/route?") answers the path of the movie it kept in ~/Movies/cmux, which goes in as a video
// link chip; a still (from any of the three) answers its bytes, which go in as an image.
import { attachmentSource, linkAttachment, withSource, type ComposerAttachment } from "../attachments";
import type { CaptureMode } from "../composerPlusRegistry";

export type Capture = { kind: "still"; file: File } | { kind: "recording"; attachment: ComposerAttachment };

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// What `mode`'s capture gives the chat `chat()` names when it starts, or undefined: cancelled,
/// failed, or the pane showing another chat by the time the host answers (a recording can take
/// minutes; a chat switched to meanwhile, a Cloud one that cannot read this Mac's path, gets nothing).
export async function takeCapture(
  mode: CaptureMode,
  call: Call,
  chat: () => string | undefined,
): Promise<Capture | undefined> {
  const startedIn = chat();
  const shot = (await call("composer.capture", { mode }).catch(() => null)) as {
    name?: unknown;
    mimeType?: unknown;
    data?: unknown;
    path?: unknown;
    source?: unknown;
  } | null;
  if (!shot || chat() !== startedIn) return undefined;
  const source = attachmentSource(shot.source);
  if (mode === "video" && typeof shot.path === "string" && shot.path.startsWith("/"))
    return { kind: "recording", attachment: { ...linkAttachment(shot.path, false), ...(source ? { source } : {}) } };
  if (typeof shot.data !== "string" || !shot.data) return undefined;
  const bytes = Uint8Array.from(atob(shot.data), (char) => char.charCodeAt(0));
  const name = typeof shot.name === "string" && shot.name ? shot.name : "Screenshot.png";
  const type = typeof shot.mimeType === "string" && shot.mimeType ? shot.mimeType : "image/png";
  // cmux took it: its chip wears cmux's icon (composer/attachmentSources.ts).
  return { kind: "still", file: withSource(new File([bytes], name, { type }), source) };
}
