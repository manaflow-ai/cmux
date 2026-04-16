// Typed JS ↔ Swift bridge for the Monaco surface.
//
// Swift side:
//  * WKScriptMessageHandler named "cmux" receives the messages below.
//  * evaluateJavaScript calls `window.cmuxMonaco.apply(...)` to push commands in.

export type InboundMessage =
  | { type: "ready" }
  | {
      type: "changed";
      value: string;
      cursor: { offset: number; length: number };
      versionId: number;
    }
  // Lightweight dirty ping. Fires synchronously on every keystroke so Swift
  // can decide whether the tab has pending edits before the buffer-carrying
  // `changed` message catches up. Also fires on undo-returns-to-saved.
  | { type: "dirty"; isDirty: boolean; versionId: number }
  | { type: "saveRequested" }
  | {
      type: "viewState";
      cursor: { offset: number; length: number };
      scrollTopFraction: number;
      monacoViewState: string; // JSON-encoded ICodeEditorViewState
    }
  | { type: "debugLog"; msg: string };

export type OutboundCommand =
  | {
      kind: "setText";
      value: string;
      languageId: string;
      preserveViewState: boolean;
    }
  | {
      kind: "setCursor";
      offset: number;
      length: number;
    }
  | {
      kind: "restoreViewState";
      monacoViewState: string;
      scrollTopFraction: number | null;
      cursorOffset: number | null;
      cursorLength: number | null;
    }
  | {
      kind: "setTheme";
      isDark: boolean;
      backgroundHex: string;
      foregroundHex: string;
      cursorHex?: string;
      selectionBackgroundHex?: string;
      /** Ghostty ANSI palette (indices 0..15), lowercase `#rrggbb` strings. Optional. */
      ansi?: string[];
      fontFamily?: string;
      fontSize?: number;
    }
  | {
      kind: "setLanguage";
      languageId: string;
    }
  | {
      kind: "focus";
    };

interface WebKitMessageHandlers {
  cmux: { postMessage(_: unknown): void };
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: WebKitMessageHandlers };
    cmuxMonaco?: {
      apply(command: OutboundCommand): void;
      flushPendingEdits(): void;
      getValue(): string;
      markSaved(): void;
    };
  }
}

export function postToSwift(message: InboundMessage): void {
  const handler = window.webkit?.messageHandlers?.cmux;
  if (!handler) {
    // eslint-disable-next-line no-console
    console.warn("cmux bridge: message handler not available", message.type);
    return;
  }
  handler.postMessage(message);
}
