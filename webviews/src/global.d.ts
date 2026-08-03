import type { DiffResponse } from "./diff/generated/protocol";
import type { CmuxCodeBridge, createDesktopBridge } from "./surfaces/codeBridge";

export {};

type AgentSessionNativeReply =
  | { ok: true; value: unknown }
  | { ok: false; error?: { code?: string; userMessage?: string } };

declare global {
  var CmuxViewerNavigation: {
    install(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
      shortcuts: Record<string, unknown>;
    }): () => void;
    installManualInputReset(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
    }): () => void;
    performAction(action: string, scroller: HTMLElement): boolean;
    resetSmoothTarget(scroller: HTMLElement): void;
  };

  interface Window {
    cmuxCode?: CmuxCodeBridge;
    desktopBridge?: ReturnType<typeof createDesktopBridge>;
    __cmuxActivateCodeSurface?: () => CmuxCodeBridge;
    __cmuxCodeAutoActivate?: boolean;
    __cmuxCodeStaticBootstrap?: {
      strings: Record<string, string>;
      theme: {
        isDark: boolean;
        variables: Record<string, string>;
      };
    };
    __cmuxPerformDiffViewerNavigationAction?: (action: string) => boolean;
    __cmuxDiffViewer?: {
      codeView?: unknown;
      codeViewItems?: unknown[];
      items?: unknown[];
      state?: unknown;
      streamMetrics?: unknown;
      workerPool?: unknown;
    };
    webkit?: {
      messageHandlers?: {
        agentSession?: {
          postMessage(message: unknown): Promise<AgentSessionNativeReply>;
        };
        cmuxDiff?: {
          postMessage(message: unknown): Promise<DiffResponse>;
        };
        cmuxCode?: {
          postMessage(message: unknown): Promise<unknown>;
        };
      };
    };
  }
}
