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
  uiSurfaceConfirm(params: { surfaceId: string; requestId: string }): Promise<unknown>;
  uiSurfaceCancel(params: { surfaceId: string; requestId: string }): Promise<unknown>;
  /// One JSON-RPC message from an MCP App view; the answer is what to post back to it (or nothing).
  uiSurfaceBridge(params: { surfaceId: string; message: unknown }): Promise<unknown>;
};

export const chatUiSurfaceClient: UiSurfaceClient = {
  uiSurfaceAction: (params) => callNative("chat.uiSurface.action", params),
  uiSurfaceConfirm: (params) => callNative("chat.uiSurface.confirm", params),
  uiSurfaceCancel: (params) => callNative("chat.uiSurface.cancel", params),
  uiSurfaceBridge: (params) => callNative("chat.uiSurface.bridge", params),
};

export const UiSurfaceClientContext = createContext<UiSurfaceClient>(chatUiSurfaceClient);
