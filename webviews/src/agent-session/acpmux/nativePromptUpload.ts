import { translate } from "./i18n";
import { pageHostClient, startHostEvents } from "./pageHost";
import { finishedPromptUpload, type PromptUploadState } from "./promptUploadState";

export type BlobBeginParams = {
  sessionId: string;
  fileName: string;
  mimeType: string;
  size: number;
  token: string;
  promptId?: string;
  ticket?: string;
};
export type UploadReply = { uploadId: string; offset?: number; size?: number; path?: string };
export type PromptGesture = { method: "session/prompt"; params: { promptId: string; sessionId: string } };
export type PromptUploadTransport = {
  gesture?(intent: PromptGesture): Promise<string | undefined>;
  beginBlob(params: BlobBeginParams): Promise<UploadReply>;
  cancelBlob?(token: string): Promise<void>;
};
type NativePost = <T>(op: string, params: Record<string, unknown>) => Promise<T>;

export function createNativePromptUploadTransport(
  post: NativePost = (op, params) => {
    const page = pageHostClient();
    if (!page) return Promise.reject(new Error(translate("error.nativeUnavailable")));
    return page.call(op.startsWith("cmux.agent.") ? op : `cmux.agent.${op}`, params);
  },
  ready: () => Promise<void> = async () => {
    const page = pageHostClient();
    if (page) await startHostEvents(page);
  },
): PromptUploadTransport {
  const pulls = new Map<string, AbortController>();
  return {
    async gesture(intent) {
      const reply = await post<{ ticket?: string }>("transport.gesture", { intent });
      return typeof reply?.ticket === "string" ? reply.ticket : undefined;
    },
    async beginBlob(params) {
      if (!params.promptId || !params.ticket) throw new Error(translate("upload.notStarted"));
      const controller = new AbortController();
      pulls.set(params.token, controller);
      try {
        return await finishedPromptUpload(
          params.token,
          params.size,
          async () => {
            await ready();
            if (controller.signal.aborted) throw new Error(translate("upload.cancelled"));
            return post("cmux.agent.uploads.begin", {
              token: params.token,
              name: params.fileName,
              type: params.mimeType,
              size: params.size,
              sessionId: params.sessionId,
              promptId: params.promptId,
              ticket: params.ticket,
            });
          },
          () => post<PromptUploadState>("cmux.agent.uploads.status", { token: params.token }),
          controller.signal,
        );
      } finally {
        if (pulls.get(params.token) === controller) pulls.delete(params.token);
      }
    },
    async cancelBlob(token) {
      pulls.get(token)?.abort();
      await post("cmux.agent.uploads.cancel", { token });
    },
  };
}
