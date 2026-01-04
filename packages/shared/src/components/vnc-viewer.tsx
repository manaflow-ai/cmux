import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  forwardRef,
  type CSSProperties,
  type ReactNode,
} from "react";
import clsx from "clsx";
import { useNetwork } from "../hooks/use-network";

// RFB type definition (copied from @novnc/novnc types to avoid static imports)
// The actual module is dynamically imported to avoid top-level await issues
interface RFBOptions {
  credentials?: {
    username?: string;
    password?: string;
    target?: string;
  };
  wsProtocols?: string[];
}

interface RFBInstance {
  scaleViewport: boolean;
  clipViewport: boolean;
  dragViewport: boolean;
  resizeSession: boolean;
  viewOnly: boolean;
  showDotCursor: boolean;
  background: string;
  qualityLevel: number;
  compressionLevel: number;
  readonly capabilities: { power?: boolean };
  disconnect(): void;
  sendCredentials(credentials: {
    username?: string;
    password?: string;
    target?: string;
  }): void;
  sendKey(keysym: number, code: string | null, down?: boolean): void;
  sendCtrlAltDel(): void;
  focus(options?: FocusOptions): void;
  blur(): void;
  clipboardPasteFrom(text: string): void;
  machineShutdown(): void;
  machineReboot(): void;
  machineReset(): void;
  addEventListener(type: string, listener: (event: CustomEvent) => void): void;
  removeEventListener(
    type: string,
    listener: (event: CustomEvent) => void
  ): void;
}

interface RFBConstructor {
  new (
    target: HTMLElement,
    urlOrChannel: string | WebSocket,
    options?: RFBOptions
  ): RFBInstance;
}

let RFBClass: RFBConstructor | null = null;
const loadRFB = async (): Promise<RFBConstructor> => {
  if (RFBClass) return RFBClass;
  const module = (await import("@novnc/novnc")) as { default: RFBConstructor };
  RFBClass = module.default;
  return RFBClass;
};

export type VncConnectionStatus =
  | "disconnected"
  | "connecting"
  | "connected"
  | "error";

export interface VncViewerProps {
  /** WebSocket URL to connect to (wss:// or ws://) - should point to websockify endpoint */
  url: string;
  /** Additional CSS class for the container */
  className?: string;
  /** Inline styles for the container */
  style?: CSSProperties;
  /** Background color for the canvas container */
  background?: string;
  /** Scale the viewport to fit the container */
  scaleViewport?: boolean;
  /** Clip the viewport to the container bounds */
  clipViewport?: boolean;
  /** Allow dragging the viewport when clipped */
  dragViewport?: boolean;
  /** Resize the remote session to match container size */
  resizeSession?: boolean;
  /** View-only mode (no keyboard/mouse input) */
  viewOnly?: boolean;
  /** Show dot cursor when remote cursor is hidden */
  showDotCursor?: boolean;
  /** JPEG quality level (0-9, higher is better quality) */
  qualityLevel?: number;
  /** Compression level (0-9, higher is more compression) */
  compressionLevel?: number;
  /** Auto-connect on mount */
  autoConnect?: boolean;
  /** Auto-reconnect on disconnect */
  autoReconnect?: boolean;
  /** Initial reconnect delay in ms */
  reconnectDelay?: number;
  /** Maximum reconnect delay in ms */
  maxReconnectDelay?: number;
  /** Maximum number of reconnect attempts (0 = infinite) */
  maxReconnectAttempts?: number;
  /** Focus the canvas on click */
  focusOnClick?: boolean;
  /** Loading fallback element */
  loadingFallback?: ReactNode;
  /** Error fallback element */
  errorFallback?: ReactNode;
  /** Called when connection is established */
  onConnect?: (rfb: RFBInstance) => void;
  /** Called when connection is closed */
  onDisconnect?: (rfb: RFBInstance | null, detail: { clean: boolean }) => void;
  /** Called when credentials are required */
  onCredentialsRequired?: (rfb: RFBInstance) => void;
  /** Called when security failure occurs */
  onSecurityFailure?: (
    rfb: RFBInstance | null,
    detail: { status: number; reason: string }
  ) => void;
  /** Called when clipboard data is received from server */
  onClipboard?: (rfb: RFBInstance, text: string) => void;
  /** Called when connection status changes */
  onStatusChange?: (status: VncConnectionStatus) => void;
  /** Called when desktop name is received */
  onDesktopName?: (rfb: RFBInstance, name: string) => void;
  /** Called when capabilities are received */
  onCapabilities?: (
    rfb: RFBInstance,
    capabilities: Record<string, boolean>
  ) => void;
}

export interface VncViewerHandle {
  /** Connect to the VNC server */
  connect: () => void;
  /** Disconnect from the VNC server */
  disconnect: () => void;
  /** Get current connection status */
  getStatus: () => VncConnectionStatus;
  /** Check if currently connected */
  isConnected: () => boolean;
  /** Send clipboard text to remote server */
  clipboardPaste: (text: string) => void;
  /** Send Ctrl+Alt+Del */
  sendCtrlAltDel: () => void;
  /** Send a key event */
  sendKey: (keysym: number, code: string, down?: boolean) => void;
  /** Focus the VNC canvas */
  focus: () => void;
  /** Blur the VNC canvas */
  blur: () => void;
  /** Get the underlying RFB instance */
  getRfb: () => RFBInstance | null;
  /** Get the canvas element used for rendering */
  getCanvas: () => HTMLCanvasElement | null;
  /** Machine power actions */
  machineShutdown: () => void;
  machineReboot: () => void;
  machineReset: () => void;
}

/**
 * VncViewer - A React component for connecting to VNC servers via websockify
 *
 * Features:
 * - Auto-connect and auto-reconnect with exponential backoff
 * - Full clipboard support (Cmd+V paste)
 * - Keyboard and mouse input
 * - Viewport scaling and resizing
 */
export const VncViewer = forwardRef<VncViewerHandle, VncViewerProps>(
  function VncViewer(
    {
      url,
      className,
      style,
      background = "#000000",
      scaleViewport = true,
      clipViewport = false,
      dragViewport = false,
      resizeSession = false,
      viewOnly = false,
      showDotCursor = false,
      qualityLevel = 6,
      compressionLevel = 2,
      autoConnect = true,
      autoReconnect = true,
      reconnectDelay = 1000,
      maxReconnectDelay = 30000,
      maxReconnectAttempts = 0,
      focusOnClick = true,
      loadingFallback,
      errorFallback,
      onConnect,
      onDisconnect,
      onCredentialsRequired,
      onSecurityFailure,
      onClipboard,
      onStatusChange,
      onDesktopName,
      onCapabilities,
    },
    ref
  ) {
    const containerRef = useRef<HTMLDivElement>(null);
    const rfbRef = useRef<RFBInstance | null>(null);
    const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(
      null
    );
    const reconnectAttemptsRef = useRef(0);
    const currentReconnectDelayRef = useRef(reconnectDelay);
    const isUnmountedRef = useRef(false);
    const urlRef = useRef(url);
    const shouldReconnectRef = useRef(autoReconnect);
    const connectInternalRef = useRef<(() => Promise<void>) | null>(null);

    const [status, setStatus] = useState<VncConnectionStatus>("disconnected");
    const [errorMessage, setErrorMessage] = useState<string | null>(null);
    const [reconnectAttempt, setReconnectAttempt] = useState(0);
    const network = useNetwork();
    const isOffline = !network.online;

    useEffect(() => {
      urlRef.current = url;
    }, [url]);

    useEffect(() => {
      shouldReconnectRef.current = autoReconnect;
    }, [autoReconnect]);

    const updateStatus = useCallback(
      (newStatus: VncConnectionStatus, error?: string) => {
        setStatus(newStatus);
        if (newStatus === "error") {
          setErrorMessage(error ?? "Connection failed");
        } else if (newStatus === "connected") {
          setErrorMessage(null);
          setReconnectAttempt(0);
        }
        onStatusChange?.(newStatus);
      },
      [onStatusChange]
    );

    const clearReconnectTimer = useCallback(() => {
      if (reconnectTimerRef.current) {
        clearTimeout(reconnectTimerRef.current);
        reconnectTimerRef.current = null;
      }
    }, []);

    const scheduleReconnect = useCallback(
      (error?: string) => {
        if (isUnmountedRef.current || !shouldReconnectRef.current) {
          return;
        }

        if (
          maxReconnectAttempts > 0 &&
          reconnectAttemptsRef.current >= maxReconnectAttempts
        ) {
          updateStatus("error", error ?? "Max reconnect attempts reached");
          return;
        }

        clearReconnectTimer();

        const delay = currentReconnectDelayRef.current;
        reconnectTimerRef.current = setTimeout(() => {
          if (isUnmountedRef.current) return;
          reconnectAttemptsRef.current++;
          setReconnectAttempt(reconnectAttemptsRef.current);
          currentReconnectDelayRef.current = Math.min(
            currentReconnectDelayRef.current * 2,
            maxReconnectDelay
          );
          connectInternalRef.current?.();
        }, delay);
      },
      [
        clearReconnectTimer,
        maxReconnectAttempts,
        maxReconnectDelay,
        updateStatus,
      ]
    );

    const connectInternal = useCallback(async () => {
      if (isUnmountedRef.current || !containerRef.current) {
        return;
      }

      if (rfbRef.current) {
        try {
          rfbRef.current.disconnect();
        } catch (e) {
          console.error("[VncViewer] Error disconnecting existing RFB:", e);
        }
        rfbRef.current = null;
      }

      updateStatus("connecting");

      try {
        const RFB = await loadRFB();
        if (isUnmountedRef.current) return;

        const wsUrl = urlRef.current;
        const rfb = new RFB(containerRef.current, wsUrl, {
          credentials: undefined,
          wsProtocols: ["binary"],
        });

        rfb.scaleViewport = scaleViewport;
        rfb.clipViewport = clipViewport;
        rfb.dragViewport = dragViewport;
        rfb.resizeSession = resizeSession;
        rfb.viewOnly = viewOnly;
        rfb.showDotCursor = showDotCursor;
        rfb.qualityLevel = qualityLevel;
        rfb.compressionLevel = compressionLevel;

        rfb.addEventListener("connect", () => {
          if (isUnmountedRef.current) return;
          reconnectAttemptsRef.current = 0;
          currentReconnectDelayRef.current = reconnectDelay;
          updateStatus("connected");
          onConnect?.(rfb);
        });

        rfb.addEventListener("disconnect", (e) => {
          if (isUnmountedRef.current) return;
          const detail = (e as CustomEvent<{ clean: boolean }>).detail;
          const isClean = detail?.clean ?? false;
          rfbRef.current = null;
          updateStatus("disconnected");
          onDisconnect?.(rfb, detail ?? { clean: false });

          if (!isClean && shouldReconnectRef.current) {
            scheduleReconnect("Connection lost unexpectedly");
          }
        });

        rfb.addEventListener("credentialsrequired", () => {
          if (isUnmountedRef.current) return;
          onCredentialsRequired?.(rfb);
        });

        rfb.addEventListener("securityfailure", (e) => {
          if (isUnmountedRef.current) return;
          const detail = (e as CustomEvent<{ status: number; reason: string }>)
            .detail;
          console.error("[VncViewer] Security failure:", detail);
          updateStatus("error", detail?.reason ?? "Security failure");
          onSecurityFailure?.(rfb, detail ?? { status: 0, reason: "Unknown" });
        });

        rfb.addEventListener("clipboard", (e) => {
          if (isUnmountedRef.current) return;
          const detail = (e as CustomEvent<{ text: string }>).detail;
          onClipboard?.(rfb, detail?.text ?? "");
        });

        rfb.addEventListener("desktopname", (e) => {
          if (isUnmountedRef.current) return;
          const detail = (e as CustomEvent<{ name: string }>).detail;
          onDesktopName?.(rfb, detail?.name ?? "");
        });

        rfb.addEventListener("capabilities", (e) => {
          if (isUnmountedRef.current) return;
          const detail = (
            e as CustomEvent<{ capabilities: Record<string, boolean> }>
          ).detail;
          onCapabilities?.(rfb, detail?.capabilities ?? {});
        });

        rfbRef.current = rfb;
      } catch (error) {
        console.error("[VncViewer] Failed to create RFB connection:", error);
        const errorMsg =
          error instanceof Error ? error.message : "Failed to connect";
        updateStatus("error", errorMsg);
        if (shouldReconnectRef.current) {
          scheduleReconnect(errorMsg);
        }
      }
    }, [
      scaleViewport,
      clipViewport,
      dragViewport,
      resizeSession,
      viewOnly,
      showDotCursor,
      qualityLevel,
      compressionLevel,
      reconnectDelay,
      updateStatus,
      scheduleReconnect,
      onConnect,
      onDisconnect,
      onCredentialsRequired,
      onSecurityFailure,
      onClipboard,
      onDesktopName,
      onCapabilities,
    ]);

    useEffect(() => {
      connectInternalRef.current = connectInternal;
    }, [connectInternal]);

    const connect = useCallback(() => {
      clearReconnectTimer();
      reconnectAttemptsRef.current = 0;
      currentReconnectDelayRef.current = reconnectDelay;
      connectInternal();
    }, [clearReconnectTimer, reconnectDelay, connectInternal]);

    const prevOnlineRef = useRef(network.online);
    useEffect(() => {
      if (network.online && !prevOnlineRef.current) {
        if (status === "error" || status === "disconnected") {
          connect();
        }
      }
      prevOnlineRef.current = network.online;
    }, [network.online, status, connect]);

    const disconnect = useCallback(() => {
      clearReconnectTimer();
      shouldReconnectRef.current = false;
      if (rfbRef.current) {
        try {
          rfbRef.current.disconnect();
        } catch (e) {
          console.error("[VncViewer] Error during disconnect:", e);
        }
        rfbRef.current = null;
      }
      updateStatus("disconnected");
    }, [clearReconnectTimer, updateStatus]);

    const clipboardPaste = useCallback((text: string) => {
      const rfb = rfbRef.current;
      if (!rfb) return;

      try {
        rfb.clipboardPasteFrom(text);

        const XK_Meta_L = 0xffe7;
        const XK_Meta_R = 0xffe8;
        const XK_Super_L = 0xffeb;
        const XK_Super_R = 0xffec;
        const XK_Control_L = 0xffe3;
        const XK_v = 0x0076;

        setTimeout(() => {
          rfb.sendKey(XK_Meta_L, "MetaLeft", false);
          rfb.sendKey(XK_Meta_R, "MetaRight", false);
          rfb.sendKey(XK_Super_L, "OSLeft", false);
          rfb.sendKey(XK_Super_R, "OSRight", false);

          rfb.sendKey(XK_Control_L, "ControlLeft", true);
          rfb.sendKey(XK_v, "KeyV", true);
          rfb.sendKey(XK_v, "KeyV", false);
          rfb.sendKey(XK_Control_L, "ControlLeft", false);
        }, 50);
      } catch (e) {
        console.error("[VncViewer] Error pasting to clipboard:", e);
      }
    }, []);

    const sendKeyCombo = useCallback(
      (keysym: number, code: string, withShift = false) => {
        const rfb = rfbRef.current;
        if (!rfb) return;

        const XK_Shift_L = 0xffe1;
        const XK_Meta_L = 0xffe7;
        const XK_Meta_R = 0xffe8;
        const XK_Super_L = 0xffeb;
        const XK_Super_R = 0xffec;
        const XK_Control_L = 0xffe3;

        rfb.sendKey(XK_Meta_L, "MetaLeft", false);
        rfb.sendKey(XK_Meta_R, "MetaRight", false);
        rfb.sendKey(XK_Super_L, "OSLeft", false);
        rfb.sendKey(XK_Super_R, "OSRight", false);

        rfb.sendKey(XK_Control_L, "ControlLeft", true);
        if (withShift) rfb.sendKey(XK_Shift_L, "ShiftLeft", true);
        rfb.sendKey(keysym, code, true);
        rfb.sendKey(keysym, code, false);
        if (withShift) rfb.sendKey(XK_Shift_L, "ShiftLeft", false);
        rfb.sendKey(XK_Control_L, "ControlLeft", false);
      },
      []
    );

    const isVncFocused = useCallback(() => {
      const container = containerRef.current;
      if (!container) return false;
      const active = document.activeElement;
      return container === active || container.contains(active);
    }, []);

    const sendCtrlKey = useCallback(
      (keysym: number, code: string, releaseMeta = false) => {
        const rfb = rfbRef.current;
        if (!rfb) return;

        const XK_Control_L = 0xffe3;

        if (releaseMeta) {
          rfb.sendKey(0xffe7, "MetaLeft", false);
          rfb.sendKey(0xffe8, "MetaRight", false);
          rfb.sendKey(0xffeb, "OSLeft", false);
          rfb.sendKey(0xffec, "OSRight", false);
          rfb.sendKey(0xffe9, "AltLeft", false);
          rfb.sendKey(0xffea, "AltRight", false);
        }

        rfb.sendKey(XK_Control_L, "ControlLeft", true);
        rfb.sendKey(keysym, code, true);
        rfb.sendKey(keysym, code, false);
        rfb.sendKey(XK_Control_L, "ControlLeft", false);
      },
      []
    );

    useEffect(() => {
      const isMac = /Mac|iPhone|iPad|iPod/i.test(
        navigator.platform || navigator.userAgent
      );
      if (!isMac) return;

      const handleKeyDown = async (e: KeyboardEvent) => {
        if (!isVncFocused()) return;
        if (viewOnly) return;

        const rfb = rfbRef.current;
        const code = e.code;

        const handleShortcut = (_logMsg: string, action: () => void) => {
          e.preventDefault();
          e.stopPropagation();
          if (!rfb) return;
          action();
        };

        if (e.metaKey && e.shiftKey && !e.altKey && !e.ctrlKey) {
          if (code === "BracketLeft") {
            handleShortcut("Cmd+Shift+[ → Ctrl+PageUp", () => {
              sendKeyCombo(0xff55, "PageUp");
            });
            return;
          }
          if (code === "BracketRight") {
            handleShortcut("Cmd+Shift+] → Ctrl+PageDown", () => {
              sendKeyCombo(0xff56, "PageDown");
            });
            return;
          }
          if (code === "KeyZ") {
            handleShortcut("Cmd+Shift+Z → Ctrl+Shift+Z", () => {
              sendKeyCombo(0x007a, "KeyZ", true);
            });
            return;
          }
          const cmdShiftMap: Record<string, [number, string]> = {
            KeyF: [0x0066, "KeyF"],
            KeyS: [0x0073, "KeyS"],
            KeyP: [0x0070, "KeyP"],
            KeyG: [0x0067, "KeyG"],
          };
          if (cmdShiftMap[code]) {
            const [keysym, keyCode] = cmdShiftMap[code];
            handleShortcut(`Cmd+Shift+${code} → Ctrl+Shift+${code}`, () => {
              sendKeyCombo(keysym, keyCode, true);
            });
            return;
          }
        }

        if (e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey) {
          if (code === "ArrowLeft") {
            handleShortcut("Cmd+Left → Home", () =>
              sendKeyCombo(0xff50, "Home")
            );
            return;
          }
          if (code === "ArrowRight") {
            handleShortcut("Cmd+Right → End", () =>
              sendKeyCombo(0xff57, "End")
            );
            return;
          }
          if (code === "ArrowUp") {
            handleShortcut("Cmd+Up → Ctrl+Home", () =>
              sendKeyCombo(0xff50, "Home")
            );
            return;
          }
          if (code === "ArrowDown") {
            handleShortcut("Cmd+Down → Ctrl+End", () =>
              sendKeyCombo(0xff57, "End")
            );
            return;
          }

          if (code === "Backspace") {
            handleShortcut("Cmd+Backspace → Shift+Home, Backspace", () => {
              const rfb = rfbRef.current;
              if (!rfb) return;

              const XK_Shift_L = 0xffe1;
              const XK_Home = 0xff50;
              const XK_BackSpace = 0xff08;
              const XK_Meta_L = 0xffe7;
              const XK_Meta_R = 0xffe8;
              const XK_Super_L = 0xffeb;
              const XK_Super_R = 0xffec;

              rfb.sendKey(XK_Meta_L, "MetaLeft", false);
              rfb.sendKey(XK_Meta_R, "MetaRight", false);
              rfb.sendKey(XK_Super_L, "OSLeft", false);
              rfb.sendKey(XK_Super_R, "OSRight", false);

              rfb.sendKey(XK_Shift_L, "ShiftLeft", true);
              rfb.sendKey(XK_Home, "Home", true);
              rfb.sendKey(XK_Home, "Home", false);
              rfb.sendKey(XK_Shift_L, "ShiftLeft", false);

              rfb.sendKey(XK_BackSpace, "Backspace", true);
              rfb.sendKey(XK_BackSpace, "Backspace", false);
            });
            return;
          }

          if (code === "KeyV") {
            e.preventDefault();
            e.stopPropagation();
            try {
              const text = await navigator.clipboard.readText();
              if (text && rfb) {
                clipboardPaste(text);
              }
            } catch (err) {
              console.error("[VncViewer] Clipboard read failed:", err);
            }
            return;
          }

          const cmdMap: Record<string, [number, string]> = {
            KeyA: [0x0061, "KeyA"],
            KeyB: [0x0062, "KeyB"],
            KeyC: [0x0063, "KeyC"],
            KeyD: [0x0064, "KeyD"],
            KeyF: [0x0066, "KeyF"],
            KeyG: [0x0067, "KeyG"],
            KeyH: [0x0068, "KeyH"],
            KeyI: [0x0069, "KeyI"],
            KeyK: [0x006b, "KeyK"],
            KeyL: [0x006c, "KeyL"],
            KeyN: [0x006e, "KeyN"],
            KeyO: [0x006f, "KeyO"],
            KeyP: [0x0070, "KeyP"],
            KeyR: [0x0072, "KeyR"],
            KeyS: [0x0073, "KeyS"],
            KeyT: [0x0074, "KeyT"],
            KeyU: [0x0075, "KeyU"],
            KeyW: [0x0077, "KeyW"],
            KeyX: [0x0078, "KeyX"],
            KeyY: [0x0079, "KeyY"],
            KeyZ: [0x007a, "KeyZ"],
            Slash: [0x002f, "Slash"],
            BracketLeft: [0x005b, "BracketLeft"],
            BracketRight: [0x005d, "BracketRight"],
            Minus: [0x002d, "Minus"],
            Equal: [0x003d, "Equal"],
            Digit0: [0x0030, "Digit0"],
            Digit1: [0x0031, "Digit1"],
            Digit2: [0x0032, "Digit2"],
            Digit3: [0x0033, "Digit3"],
            Digit4: [0x0034, "Digit4"],
            Digit5: [0x0035, "Digit5"],
            Digit6: [0x0036, "Digit6"],
            Digit7: [0x0037, "Digit7"],
            Digit8: [0x0038, "Digit8"],
            Digit9: [0x0039, "Digit9"],
          };
          if (cmdMap[code]) {
            const [keysym, keyCode] = cmdMap[code];
            handleShortcut(`Cmd+${code} → Ctrl+${code}`, () =>
              sendKeyCombo(keysym, keyCode)
            );
            return;
          }
        }

        if (e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey) {
          if (code === "ArrowLeft") {
            handleShortcut("Option+Left → Ctrl+Left", () =>
              sendCtrlKey(0xff51, "ArrowLeft", true)
            );
            return;
          }
          if (code === "ArrowRight") {
            handleShortcut("Option+Right → Ctrl+Right", () =>
              sendCtrlKey(0xff53, "ArrowRight", true)
            );
            return;
          }
          if (code === "Backspace") {
            handleShortcut("Option+Backspace → Ctrl+Backspace", () =>
              sendCtrlKey(0xff08, "Backspace", true)
            );
            return;
          }
          if (code === "Delete") {
            handleShortcut("Option+Delete → Ctrl+Delete", () =>
              sendCtrlKey(0xffff, "Delete", true)
            );
            return;
          }
        }

        if (e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey) {
          const readlineMap: Record<string, [number, string]> = {
            KeyA: [0x0061, "KeyA"],
            KeyE: [0x0065, "KeyE"],
            KeyK: [0x006b, "KeyK"],
            KeyU: [0x0075, "KeyU"],
            KeyW: [0x0077, "KeyW"],
            KeyY: [0x0079, "KeyY"],
            KeyL: [0x006c, "KeyL"],
            KeyC: [0x0063, "KeyC"],
            KeyD: [0x0064, "KeyD"],
          };
          if (readlineMap[code]) {
            const [keysym, keyCode] = readlineMap[code];
            handleShortcut(`Ctrl+${code} → Ctrl+${code}`, () =>
              sendCtrlKey(keysym, keyCode, false)
            );
            return;
          }
        }
      };

      document.addEventListener("keydown", handleKeyDown, { capture: true });
      return () => {
        document.removeEventListener("keydown", handleKeyDown, {
          capture: true,
        });
      };
    }, [clipboardPaste, sendKeyCombo, sendCtrlKey, isVncFocused, viewOnly]);

    useEffect(() => {
      const container = containerRef.current;
      if (!container) return;

      const handleDocumentPaste = (e: ClipboardEvent) => {
        if (!container.contains(document.activeElement)) return;
        if (!rfbRef.current) return;
        if (viewOnly) return;

        const text =
          e.clipboardData?.getData("text/plain") ||
          e.clipboardData?.getData("text");
        if (text) {
          e.preventDefault();
          e.stopPropagation();
          clipboardPaste(text);
        }
      };

      document.addEventListener("paste", handleDocumentPaste, {
        capture: true,
      });
      return () =>
        document.removeEventListener("paste", handleDocumentPaste, {
          capture: true,
        });
    }, [clipboardPaste, viewOnly]);

    const focus = useCallback(() => {
      rfbRef.current?.focus();
    }, []);

    const blur = useCallback(() => {
      rfbRef.current?.blur();
    }, []);
    const getCanvas = useCallback((): HTMLCanvasElement | null => {
      // noVNC creates a canvas element inside the container
      return containerRef.current?.querySelector("canvas") ?? null;
    }, []);

    useImperativeHandle(
      ref,
      () => ({
        connect,
        disconnect,
        getStatus: () => status,
        isConnected: () => status === "connected",
        clipboardPaste,
        sendCtrlAltDel: () => rfbRef.current?.sendCtrlAltDel(),
        sendKey: (keysym, code, down) =>
          rfbRef.current?.sendKey(keysym, code, down),
        focus,
        blur,
        getRfb: () => rfbRef.current,
        getCanvas,
        machineShutdown: () => rfbRef.current?.machineShutdown(),
        machineReboot: () => rfbRef.current?.machineReboot(),
        machineReset: () => rfbRef.current?.machineReset(),
      }),
      [connect, disconnect, status, clipboardPaste, focus, blur, getCanvas]
    );

    useEffect(() => {
      isUnmountedRef.current = false;

      if (autoConnect) {
        const timer = setTimeout(() => {
          if (!isUnmountedRef.current) {
            connect();
          }
        }, 100);
        return () => clearTimeout(timer);
      }
      return undefined;
    }, [autoConnect, connect]);

    useEffect(() => {
      return () => {
        isUnmountedRef.current = true;
        clearReconnectTimer();
        if (rfbRef.current) {
          try {
            rfbRef.current.disconnect();
          } catch (e) {
            console.error("[VncViewer] Error during unmount cleanup:", e);
          }
          rfbRef.current = null;
        }
      };
    }, [clearReconnectTimer]);

    useEffect(() => {
      if (status === "connected" || status === "connecting") {
        connect();
      }
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [url]);

    const handleContainerClick = useCallback(() => {
      if (focusOnClick && rfbRef.current) {
        focus();
      }
    }, [focusOnClick, focus]);

    const showLoading =
      (status === "connecting" || status === "disconnected") && !isOffline;
    const showError = status === "error" || isOffline;

    const defaultLoadingFallback = useMemo(
      () => (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="flex flex-col items-center gap-2">
            <div className="h-5 w-5 animate-spin rounded-full border-[1.5px] border-neutral-600 border-t-transparent" />
            <span className="text-xs text-neutral-500">
              {status === "connecting"
                ? reconnectAttempt > 0
                  ? `Reconnecting (${reconnectAttempt})...`
                  : "Connecting..."
                : ""}
            </span>
            {reconnectAttempt > 0 && errorMessage && (
              <span className="text-xs text-neutral-600 max-w-[240px] text-center">
                {errorMessage}
              </span>
            )}
          </div>
        </div>
      ),
      [status, reconnectAttempt, errorMessage]
    );

    const defaultErrorFallback = useMemo(
      () => (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="flex flex-col items-center gap-3 text-center px-4">
            {isOffline ? (
              <>
                <div className="flex h-10 w-10 items-center justify-center rounded-full bg-amber-500/10">
                  <svg
                    className="h-5 w-5 text-amber-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    strokeWidth={2}
                  >
                    <path
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      d="M18.364 5.636a9 9 0 010 12.728m0 0l-2.829-2.829m2.829 2.829L21 21M15.536 8.464a5 5 0 010 7.072m0 0l-2.829-2.829m-4.243 2.829a4.978 4.978 0 01-1.414-2.83m-1.414 5.658a9 9 0 01-2.167-9.238m7.824 2.167a1 1 0 111.414 1.414m-1.414-1.414L3 3m8.293 8.293l1.414 1.414"
                    />
                  </svg>
                </div>
                <div className="flex flex-col gap-1">
                  <span className="text-sm font-medium text-neutral-200">
                    Network offline
                  </span>
                  <span className="text-xs text-neutral-400 max-w-[280px]">
                    Check your internet connection. Will reconnect automatically
                    when online.
                  </span>
                </div>
              </>
            ) : (
              <>
                <div className="flex h-10 w-10 items-center justify-center rounded-full bg-red-500/10">
                  <svg
                    className="h-5 w-5 text-red-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    strokeWidth={2}
                  >
                    <path
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                    />
                  </svg>
                </div>
                <div className="flex flex-col gap-1">
                  <span className="text-sm font-medium text-neutral-200">
                    Connection failed
                  </span>
                  {errorMessage && (
                    <span className="text-xs text-neutral-400 max-w-[280px]">
                      {errorMessage}
                    </span>
                  )}
                </div>
                <button
                  type="button"
                  onClick={connect}
                  className="mt-1 rounded-md bg-neutral-700 px-4 py-2 text-sm font-medium text-white hover:bg-neutral-600 transition-colors"
                >
                  Retry connection
                </button>
              </>
            )}
          </div>
        </div>
      ),
      [connect, errorMessage, isOffline]
    );

    const handleContextMenu = useCallback((e: React.MouseEvent) => {
      e.preventDefault();
    }, []);

    return (
      <div
        className={clsx("overflow-hidden", className)}
        style={{ background, ...style }}
        onClick={handleContainerClick}
        onContextMenu={handleContextMenu}
        data-drag-disable-pointer
      >
        <div
          ref={containerRef}
          className="absolute inset-0"
          style={{ background }}
          tabIndex={0}
          data-drag-disable-pointer
        />

        {showLoading && (loadingFallback ?? defaultLoadingFallback)}

        {showError && (errorFallback ?? defaultErrorFallback)}
      </div>
    );
  }
);

export default VncViewer;
