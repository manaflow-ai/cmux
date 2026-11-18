// What a surface card sends, and only this: the renderer never builds a payload. A press sends the
// action's id and the field values the card holds; acpmux (Rust) answers with the host-written
// Pending the card shows, and only Confirm sends anything onward. The chat's client implements the
// four methods (direct.ts `uiSurfaceAction` and the rest, App.tsx's `chat.uiSurface.*` actions); a
// gallery or test hands its own through `UiSurfaceClientContext`.
import { createContext } from "react";
import { callNative } from "../callNative";
import type { UiSurfaceValues } from "./model";

export type UiSurfaceClient = {
  uiSurfaceAction(params: { surfaceId: string; actionId: string; values: UiSurfaceValues }): Promise<unknown>;
  /// `values` are the fields now: acpmux refuses the confirm as stale when they change what it sends.
  uiSurfaceConfirm(params: { surfaceId: string; requestId: string; values: UiSurfaceValues }): Promise<unknown>;
  uiSurfaceCancel(params: { surfaceId: string; requestId: string }): Promise<unknown>;
  /// One JSON-RPC message from an MCP App view; the answer is what to post back to it (or nothing).
  uiSurfaceBridge(params: { surfaceId: string; message: unknown }): Promise<unknown>;
  /// A confirmed `link:` target: acpmux checked the https URL; it opens in a browser tab.
  openLink(url: string): void;
  /// A view's `draft`: the text goes into the composer, and the person presses Send.
  draft(text: string): void;
};

export const chatUiSurfaceClient: UiSurfaceClient = {
  uiSurfaceAction: (params) => callNative("chat.uiSurface.action", params),
  uiSurfaceConfirm: (params) => callNative("chat.uiSurface.confirm", params),
  uiSurfaceCancel: (params) => callNative("chat.uiSurface.cancel", params),
  uiSurfaceBridge: (params) => callNative("chat.uiSurface.bridge", params),
  openLink: (url) => void callNative("tab.open", { kind: "browser", text: url, keep: true }).catch(() => undefined),
  // Edit and Resend's own path: before anything typed, with the caret in it (App.tsx).
  draft: (text) => void callNative("chat.editPrompt", { text }).catch(() => undefined),
};

export const UiSurfaceClientContext = createContext<UiSurfaceClient>(chatUiSurfaceClient);

/// acpmux's answer to a Confirm (`UiSurfaceConfirmResult`): where it went, the view's reply, a link.
export type ConfirmAnswer = { sent?: string; reply?: unknown; openUrl?: string };

export function readConfirmAnswer(value: unknown): ConfirmAnswer {
  if (typeof value !== "object" || value === null) return {};
  const answer = value as Record<string, unknown>;
  return {
    ...(typeof answer.sent === "string" ? { sent: answer.sent } : {}),
    ...(answer.reply !== undefined && answer.reply !== null ? { reply: answer.reply } : {}),
    ...(typeof answer.openUrl === "string" && /^https:\/\//i.test(answer.openUrl) ? { openUrl: answer.openUrl } : {}),
  };
}
