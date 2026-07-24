"use client";

// Root client component for cmux.com/share/<code>: one server-selected
// workspace, its exact split tree, remote cursors, and floating session chat.

import { useCallback, useRef, useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";

import { participantColor } from "./share-colors";
import { ChatPanel } from "./share-chat";
import type { ShareClient } from "./share-connection";
import { CursorLayer } from "./share-cursors";
import {
  createPaneRectRegistry,
  LayoutView,
  paneKeyOf,
  paneRefFromKey,
  PaneRegistryProvider,
} from "./share-panes";
import {
  MAX_CHAT_TEXT_CHARS,
  type CursorPos,
  type Participant,
} from "./share-protocol";
import { useShareClient, useStoreValue } from "./use-store";

interface KeydownListenerTarget {
  addEventListener(type: "keydown", listener: (event: KeyboardEvent) => void): void;
  removeEventListener(type: "keydown", listener: (event: KeyboardEvent) => void): void;
}

export function installKeydownListener(
  target: KeydownListenerTarget,
  listener: (event: KeyboardEvent) => void,
): () => void {
  target.addEventListener("keydown", listener);
  return () => target.removeEventListener("keydown", listener);
}

function elementTarget(target: EventTarget | null): Element | null {
  return target &&
    typeof (target as Element).getAttribute === "function" &&
    typeof (target as Element).tagName === "string"
    ? (target as Element)
    : null;
}

/** True when slash belongs to the currently focused editing surface. */
export function hasEditableShortcutFocus(target: EventTarget | null): boolean {
  let element = elementTarget(target);
  while (element) {
    if (element.getAttribute("role")?.toLowerCase() === "textbox") return true;
    const contentEditable = element.getAttribute("contenteditable");
    if (contentEditable !== null) return contentEditable.toLowerCase() !== "false";
    if (element.tagName === "INPUT" || element.tagName === "TEXTAREA") {
      const control = element as HTMLInputElement | HTMLTextAreaElement;
      return !control.disabled && !control.readOnly;
    }
    element = element.parentElement;
  }
  return false;
}

export function shouldOpenBubbleShortcut({
  key,
  hasEditableFocus,
  hasPointer,
  hasDraft,
}: {
  key: string;
  hasEditableFocus: boolean;
  hasPointer: boolean;
  hasDraft: boolean;
}): boolean {
  return key === "/" && !hasEditableFocus && hasPointer && !hasDraft;
}

export function ShareViewer({ code }: { code: string }): ReactNode {
  const client = useShareClient(code);
  const session = useStoreValue(client.session);
  const t = useTranslations("share");

  switch (session.status) {
    case "connecting":
      return <StatusScreen title={t("connectingTitle")} body={t("connectingBody")} pulse />;
    case "pending":
      return <StatusScreen title={t("pendingTitle")} body={t("pendingBody")} pulse />;
    case "denied":
      return <StatusScreen title={t("deniedTitle")} body={t("deniedBody")} />;
    case "kicked":
      return <StatusScreen title={t("kickedTitle")} body={t("kickedBody")} />;
    case "unavailable":
      return <StatusScreen title={t("unavailableTitle")} body={t("unavailableBody")} />;
    case "ended":
      return (
        <StatusScreen
          title={t("endedTitle")}
          body={session.endedReason === "host-gone" ? t("endedHostGoneBody") : t("endedBody")}
        />
      );
    case "active":
      return <ActiveViewer client={client} />;
  }
}

function StatusScreen({
  title,
  body,
  pulse,
}: {
  title: string;
  body: string;
  pulse?: boolean;
}): ReactNode {
  return (
    <div className="flex h-dvh flex-col items-center justify-center gap-2 bg-[#0a0a0a] text-center text-[#ededed]">
      <h1 className={`text-sm font-medium ${pulse ? "animate-pulse" : ""}`}>{title}</h1>
      <p className="max-w-sm text-xs text-neutral-400">{body}</p>
    </div>
  );
}

function ActiveViewer({ client }: { client: ShareClient }): ReactNode {
  const session = useStoreValue(client.session);
  const t = useTranslations("share");
  const canInteract = !session.reconnecting;
  const [registry] = useState(createPaneRectRegistry);
  const [workspaceEl, setWorkspaceEl] = useState<HTMLElement | null>(null);
  const [cursorLayoutRevision, setCursorLayoutRevision] = useState(0);
  const [bubbleDraft, setBubbleDraft] = useState<{
    pos: CursorPos;
    clientX: number;
    clientY: number;
  } | null>(null);
  const bubbleDraftRef = useRef(bubbleDraft);
  const lastPointer = useRef<{
    target: HTMLElement;
    paneKey: string;
    clientX: number;
    clientY: number;
  } | null>(null);
  const shortcutCleanupRef = useRef<(() => void) | null>(null);
  const resizeCleanupRef = useRef<(() => void) | null>(null);

  const resolvePointer = useCallback((): {
    pos: CursorPos;
    clientX: number;
    clientY: number;
  } | null => {
    const pointer = lastPointer.current;
    if (!pointer) return null;
    const paneRef = paneRefFromKey(pointer.paneKey);
    if (!paneRef) return null;
    const rect = pointer.target.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return null;
    return {
      pos: {
        ws: paneRef[0],
        pane: paneRef[1],
        x: Math.min(1, Math.max(0, (pointer.clientX - rect.left) / rect.width)),
        y: Math.min(1, Math.max(0, (pointer.clientY - rect.top) / rect.height)),
      },
      clientX: pointer.clientX,
      clientY: pointer.clientY,
    };
  }, []);

  const mountWorkspace = useCallback(
    (element: HTMLElement | null): void => {
      shortcutCleanupRef.current?.();
      shortcutCleanupRef.current = null;
      resizeCleanupRef.current?.();
      resizeCleanupRef.current = null;
      setWorkspaceEl(element);
      if (!element) return;
      const ownerWindow = element.ownerDocument.defaultView;
      if (!ownerWindow) return;
      const resizeObserver = new ResizeObserver(() => {
        setCursorLayoutRevision((revision) => revision + 1);
      });
      resizeObserver.observe(element);
      resizeCleanupRef.current = () => resizeObserver.disconnect();
      shortcutCleanupRef.current = installKeydownListener(ownerWindow, (event) => {
        if (!canInteract) return;
        const pointer = resolvePointer();
        const paneElement = pointer
          ? registry.get(paneKeyOf(pointer.pos.ws, pointer.pos.pane))
          : null;
        const hasPointer =
          pointer !== null &&
          paneElement !== null &&
          element.contains(paneElement);
        const hasEditableFocus =
          hasEditableShortcutFocus(element.ownerDocument.activeElement) ||
          hasEditableShortcutFocus(event.target);
        if (
          !shouldOpenBubbleShortcut({
            key: event.key,
            hasEditableFocus,
            hasPointer,
            hasDraft: bubbleDraftRef.current !== null,
          }) ||
          !pointer
        ) {
          return;
        }
        event.preventDefault();
        const rect = element.getBoundingClientRect();
        const draft = {
          pos: pointer.pos,
          clientX: pointer.clientX - rect.left,
          clientY: pointer.clientY - rect.top,
        };
        bubbleDraftRef.current = draft;
        setBubbleDraft(draft);
      });
    },
    [canInteract, registry, resolvePointer],
  );

  const activeLayout = session.activeWs ? (session.layouts[session.activeWs] ?? null) : null;
  const canType = session.you?.role === "editor" && canInteract;
  const host = session.participants.find((participant) => participant.isHost);

  return (
    <div className="flex h-dvh flex-col bg-[#0a0a0a] font-mono text-[13px] text-[#ededed]">
      <header className="flex h-9 shrink-0 items-center gap-3 border-b border-neutral-800 px-3">
        <span className="text-xs font-semibold tracking-wide">cmux</span>
        <span className="text-[11px] text-neutral-500">
          {t("sharedBy", { email: host?.email ?? "" })}
        </span>
        {session.reconnecting ? (
          <span className="text-[11px] text-amber-400">{t("reconnecting")}</span>
        ) : null}
        {host && !host.connected ? (
          <span className="text-[11px] text-amber-400">{t("hostDisconnected")}</span>
        ) : null}
        <div className="ml-auto flex items-center gap-2">
          <span className="text-[11px] text-neutral-500">
            {canType ? t("roleEditor") : t("roleViewer")}
          </span>
          <ParticipantDots participants={session.participants} />
        </div>
      </header>

      <main
        ref={mountWorkspace}
        className="relative min-h-0 min-w-0 flex-1"
        onPointerMove={(event) => {
          const target = (event.target as HTMLElement).closest<HTMLElement>(
            "[data-share-pane]",
          );
          const key = target?.dataset.sharePane;
          if (!target || !key) {
            if (lastPointer.current) {
              lastPointer.current = null;
              client.sendCursor(null);
            }
            return;
          }
          lastPointer.current = {
            target,
            paneKey: key,
            clientX: event.clientX,
            clientY: event.clientY,
          };
          client.sendCursorSample(() => resolvePointer()?.pos ?? null);
        }}
        onPointerLeave={() => {
          lastPointer.current = null;
          client.sendCursor(null);
        }}
        tabIndex={-1}
      >
        {session.activeWs ? (
          <PaneRegistryProvider value={registry}>
            <LayoutView
              client={client}
              ws={session.activeWs}
              node={activeLayout?.tree ?? null}
              canType={canType}
            />
          </PaneRegistryProvider>
        ) : (
          <div className="flex h-full items-center justify-center text-xs text-neutral-500">
            {t("emptyWorkspace")}
          </div>
        )}

        <CursorStoreLayer
          client={client}
          participants={session.participants}
          selfUser={session.you?.user ?? null}
          activeWs={session.activeWs}
          registry={registry}
          container={workspaceEl}
          layoutRevision={cursorLayoutRevision}
        />

        {bubbleDraft ? (
          <BubbleComposer
            x={bubbleDraft.clientX}
            y={bubbleDraft.clientY}
            color={participantColor(session.you?.color ?? 0)}
            disabled={!canInteract}
            onSubmit={(text) => {
              const admitted = client.sendChat(text, bubbleDraft.pos);
              if (admitted) {
                bubbleDraftRef.current = null;
                setBubbleDraft(null);
              }
              return admitted;
            }}
            onCancel={() => {
              bubbleDraftRef.current = null;
              setBubbleDraft(null);
            }}
          />
        ) : null}

        <ChatPanel
          chat={session.chat}
          participants={session.participants}
          selfUser={session.you?.user ?? null}
          onSend={(text) => client.sendChat(text)}
          disabled={!canInteract}
        />
      </main>
    </div>
  );
}

function CursorStoreLayer({
  client,
  participants,
  selfUser,
  activeWs,
  registry,
  container,
  layoutRevision,
}: {
  client: ShareClient;
  participants: Participant[];
  selfUser: string | null;
  activeWs: string | null;
  registry: ReturnType<typeof createPaneRectRegistry>;
  container: HTMLElement | null;
  layoutRevision: number;
}): ReactNode {
  const cursors = useStoreValue(client.cursors);
  void layoutRevision;
  return (
    <CursorLayer
      cursors={cursors}
      participants={participants}
      selfUser={selfUser}
      activeWs={activeWs}
      registry={registry}
      container={container}
    />
  );
}

function ParticipantDots({ participants }: { participants: Participant[] }): ReactNode {
  return (
    <div className="flex -space-x-1">
      {participants
        .filter((participant) => participant.connected)
        .map((participant) => (
          <span
            key={participant.user}
            title={participant.email}
            className="h-4 w-4 rounded-full border border-[#0a0a0a] text-center text-[9px] font-semibold leading-4 text-white"
            style={{ backgroundColor: participantColor(participant.color) }}
          >
            {(participant.email || participant.user).slice(0, 1).toUpperCase()}
          </span>
        ))}
    </div>
  );
}

function BubbleComposer({
  x,
  y,
  color,
  disabled,
  onSubmit,
  onCancel,
}: {
  x: number;
  y: number;
  color: string;
  disabled: boolean;
  onSubmit: (text: string) => boolean;
  onCancel: () => void;
}): ReactNode {
  const t = useTranslations("share");
  const [text, setText] = useState("");
  return (
    <div style={{ position: "absolute", left: x, top: y, zIndex: 60 }}>
      <input
        ref={(element) => element?.focus()}
        value={text}
        readOnly={disabled}
        aria-disabled={disabled}
        maxLength={MAX_CHAT_TEXT_CHARS}
        onChange={(event) => setText(event.target.value)}
        onBlur={onCancel}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            event.preventDefault();
            if (disabled) return;
            if (text.trim()) onSubmit(text);
            else onCancel();
          } else if (event.key === "Escape") {
            event.preventDefault();
            onCancel();
          }
          event.stopPropagation();
        }}
        placeholder={t("bubblePlaceholder")}
        className="w-56 rounded-2xl rounded-tl-sm border-0 px-3 py-2 text-xs text-white shadow-xl outline-none placeholder:text-white/60 read-only:cursor-not-allowed read-only:opacity-60"
        style={{ backgroundColor: color }}
      />
    </div>
  );
}
