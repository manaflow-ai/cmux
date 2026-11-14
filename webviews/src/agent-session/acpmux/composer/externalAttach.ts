// Files another app sent to this chat (Leo, 2026-11-08: "holy f***. those NEED to be written down
// and FIXED and IMPROVED", on a screenshot that could not reach a chat from another app): the Send to
// cmux Chat service, an image opened with cmux or dropped on its Dock icon. The host holds them and
// sends the page `attachExternal`; the page takes them (`chat.attach.external`) and adds them to the
// composer as a drop's files, so a chat on this Mac links each where it is and its chip says which
// app it came from (`external`, attachmentSources.ts). `chat.composer.get` reads the composer back
// through `composerReadback`.
import type { ComposerAttachment } from "../attachments";

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The files of the host's `{files: [{name, type, data}]}` answer, each `data` its bytes as base64.
/// One without a name, or whose data is not base64, is left out.
export function externalFiles(value: unknown): File[] {
  const files = (value as { files?: unknown } | null | undefined)?.files;
  if (!Array.isArray(files)) return [];
  return files.flatMap((entry: unknown) => {
    const { name, type, data } = (entry ?? {}) as { name?: unknown; type?: unknown; data?: unknown };
    if (typeof name !== "string" || !name || typeof data !== "string") return [];
    try {
      const binary = atob(data);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
      return [new File([bytes], name, typeof type === "string" && type ? { type } : {})];
    } catch {
      return [];
    }
  });
}

/// The files the host holds for this chat, once (`chat.attach.external`); none from an older host.
export async function takeExternalFiles(call: Call): Promise<File[]> {
  try {
    return externalFiles(await call("chat.attach.external", {}));
  } catch {
    return [];
  }
}

/// Takes the host's files into the composer `composer` answers, with the keyboard: on the
/// `attachExternal` command, and when a composer mounts, since a page still loading on the old host
/// never got a command sent before it ran. Without a composer nothing is asked, so the host keeps them.
export function takeExternalInto(
  composer: () => { attachFiles(files: File[], kind: "external"): void; focus(): void } | null | undefined,
  call: Call,
): void {
  if (!composer()) return;
  void takeExternalFiles(call).then((files) => {
    const target = composer();
    if (!files.length || !target) return;
    target.attachFiles(files, "external");
    target.focus();
  });
}

/// What `chat.composer.get` answers of the composer: its text and each chip's name, type, size and
/// the name of the app it came from (empty when none).
export type ComposerReadback = {
  text: string;
  attachments: { name: string; mimeType: string; bytes: number; source: string }[];
};

export function composerReadback(draft: {
  text: string;
  attachments: readonly ComposerAttachment[];
}): ComposerReadback {
  return {
    text: draft.text,
    attachments: draft.attachments.map((chip) => ({
      name: chip.name,
      mimeType: chip.mimeType,
      bytes: chip.size,
      source: chip.source?.name ?? "",
    })),
  };
}
