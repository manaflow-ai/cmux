export const MESSAGE_WINDOW_MS = 1_000;
export const HOST_MESSAGES_PER_WINDOW = 600;
export const VIEWER_MESSAGES_PER_WINDOW = 120;
export const HOST_BYTES_PER_WINDOW = 8 * 1_024 * 1_024;
export const VIEWER_BYTES_PER_WINDOW = 512 * 1_024;

export type MessageWindow = {
  readonly startedAt: number;
  readonly count: number;
  readonly bytes: number;
};

export type EventWindow = {
  readonly startedAt: number;
  readonly count: number;
};

export function consumeMessageBudget(
  current: MessageWindow,
  role: "host" | "viewer",
  frameBytes: number,
  now: number,
): { readonly ok: true; readonly window: MessageWindow } | { readonly ok: false } {
  if (!Number.isSafeInteger(frameBytes) || frameBytes < 0) return { ok: false };
  const sameWindow = now - current.startedAt < MESSAGE_WINDOW_MS;
  const window: MessageWindow = {
    startedAt: sameWindow ? current.startedAt : now,
    count: sameWindow ? current.count + 1 : 1,
    bytes: sameWindow ? current.bytes + frameBytes : frameBytes,
  };
  const countLimit = role === "host" ? HOST_MESSAGES_PER_WINDOW : VIEWER_MESSAGES_PER_WINDOW;
  const byteLimit = role === "host" ? HOST_BYTES_PER_WINDOW : VIEWER_BYTES_PER_WINDOW;
  return window.count <= countLimit && window.bytes <= byteLimit
    ? { ok: true, window }
    : { ok: false };
}

export function consumeEventBudget(
  current: EventWindow,
  limit: number,
  now: number,
): { readonly ok: true; readonly window: EventWindow } | { readonly ok: false } {
  if (!Number.isSafeInteger(limit) || limit < 1) return { ok: false };
  const sameWindow = now - current.startedAt < MESSAGE_WINDOW_MS;
  const window = {
    startedAt: sameWindow ? current.startedAt : now,
    count: sameWindow ? current.count + 1 : 1,
  };
  return window.count <= limit ? { ok: true, window } : { ok: false };
}

export function canQueueSocketFrame(
  bufferedBytes: number | undefined,
  frameBytes: number,
  maximumBytes: number,
): boolean {
  if (!Number.isSafeInteger(frameBytes) || frameBytes < 0 || maximumBytes < 1) return false;
  if (frameBytes >= maximumBytes) return false;
  return bufferedBytes === undefined || bufferedBytes + frameBytes < maximumBytes;
}
