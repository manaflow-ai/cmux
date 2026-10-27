export type PromptUploadState = {
  token: string;
  uploadId?: string;
  state: "uploading" | "finished" | "failed" | "cancelled";
  size: number;
  error?: { code: string; message: string; host?: string; path?: string };
};
export type FinishedPromptUpload = { uploadId: string; size: number; offset: number };
const waiting = new Map<string, Set<(state: PromptUploadState) => void>>();

export function receivePromptUploadState(value: unknown): void {
  if (!value || typeof value !== "object") return;
  const state = value as PromptUploadState;
  if (typeof state.token !== "string" || !waiting.has(state.token)) return;
  for (const receive of waiting.get(state.token)!) receive(state);
}

/// Listen before starting the host pull: its terminal event can arrive before begin answers.
/// The status read also recovers a terminal push lost while the page subscribed.
export function finishedPromptUpload(
  token: string,
  size: number,
  begin: () => Promise<unknown>,
  status: () => Promise<PromptUploadState>,
  signal?: AbortSignal,
): Promise<FinishedPromptUpload> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const cleanup = () => {
      waiting.get(token)?.delete(receive);
      if (!waiting.get(token)?.size) waiting.delete(token);
      signal?.removeEventListener("abort", aborted);
    };
    const fail = (error: unknown) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    };
    const receive = (state: PromptUploadState) => {
      if (settled || state.token !== token || state.state === "uploading") return;
      if (state.state !== "finished") {
        if (state.state !== "failed" && state.state !== "cancelled") return;
        fail(Object.assign(new Error(state.error?.message ?? "Upload cancelled"), state.error));
        return;
      }
      if (typeof state.uploadId !== "string" || !state.uploadId.trim()) {
        fail(Object.assign(new Error("The host returned no upload id"), { code: "upload.noId" }));
        return;
      }
      if (state.size !== size) {
        fail(Object.assign(new Error("The host returned an incomplete upload"), { code: "upload.incomplete" }));
        return;
      }
      settled = true;
      cleanup();
      resolve({ uploadId: state.uploadId, size, offset: size });
    };
    const aborted = () => fail(Object.assign(new Error("Upload cancelled"), { code: "upload.cancelled" }));
    const listeners = waiting.get(token) ?? new Set();
    listeners.add(receive);
    waiting.set(token, listeners);
    signal?.addEventListener("abort", aborted, { once: true });
    if (signal?.aborted) {
      aborted();
      return;
    }
    try {
      begin()
        .then(() => (settled ? undefined : status()))
        .then((state) => {
          if (state) receive(state);
        }, fail);
    } catch (error) {
      fail(error);
    }
  });
}
