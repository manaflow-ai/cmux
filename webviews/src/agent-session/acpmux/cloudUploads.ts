// Files dropped or pasted into a chat moved to a Cloud machine that the composer can't attach
// (cmuxterm-hq#1874 slice 6): their bytes go to the host as `chat.upload {files: [{name, data}]}`
// (CmuxNextAgentPane AgentPaneUpload), which takes them only for a moved chat and only with the
// person's gesture, copies them to the chat's machine, and answers where each went there.
import { base64 } from "./attachments";

export const MAX_UPLOAD_FILE_BYTES = 32 * 1024 * 1024;
export const MAX_UPLOAD_TOTAL_BYTES = 64 * 1024 * 1024;

/// The machine paths of the files sent, the host's error text, or undefined when this chat takes
/// no uploads (or the files are past the limits), so the composer shows its own note.
export type UploadResult = { paths: string[] } | { error: string } | undefined;

/// Codes for a chat that takes no uploads or files the host refused to read as an upload.
const NOT_TAKEN = new Set(["unsupported", "native.invalid_request"]);

export async function uploadToMachine(
  files: File[],
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): Promise<UploadResult> {
  const total = files.reduce((sum, file) => sum + file.size, 0);
  if (files.length === 0 || total > MAX_UPLOAD_TOTAL_BYTES) return undefined;
  if (files.some((file) => file.size > MAX_UPLOAD_FILE_BYTES || !file.name)) return undefined;
  let payload: { name: string; data: string }[];
  try {
    payload = await Promise.all(
      files.map(async (file) => ({ name: file.name, data: base64(new Uint8Array(await file.arrayBuffer())) })),
    );
  } catch {
    // A dropped folder arrives as a File whose bytes cannot be read.
    return undefined;
  }
  try {
    const value = (await call("chat.upload", { files: payload })) as { uploads?: { path?: unknown }[] } | null;
    const paths = (value?.uploads ?? []).flatMap((upload) => (typeof upload.path === "string" ? [upload.path] : []));
    return paths.length === files.length ? { paths } : undefined;
  } catch (error) {
    const code = (error as { code?: unknown } | null)?.code;
    if (typeof code === "string" && NOT_TAKEN.has(code)) return undefined;
    return { error: error instanceof Error ? error.message : String(error) };
  }
}
