"use client";

import { useMemo, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { ChatPanel } from "./chat-panel";
import { CursorChatInput } from "./cursor-chat-input";
import { CursorLayer } from "./cursor-layer";
import { PaneTile } from "./pane-tile";
import { PresenceStrip } from "./presence-strip";
import { displayName } from "./palette";
import { SurfaceStore } from "./surface-store";
import { useAccessToken } from "./use-access-token";
import { useElementSize } from "./use-element-size";
import { useShareSocket } from "./use-share-socket";
import { useWindowKeydown } from "./use-window-keydown";

const BASE_FONT_SIZE = 13;

function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target.isContentEditable
  );
}

function StatusOverlay({
  title,
  detail,
  spinner,
}: {
  title: string;
  detail?: string;
  spinner?: boolean;
}) {
  return (
    <div className="absolute inset-0 z-40 flex flex-col items-center justify-center gap-3 bg-neutral-950/90">
      {spinner ? (
        <div
          className="h-6 w-6 animate-spin rounded-full border-2 border-neutral-700 border-t-neutral-200"
          aria-hidden="true"
        />
      ) : null}
      <p className="text-[14px] font-medium text-neutral-200">{title}</p>
      {detail ? <p className="text-[12px] text-neutral-500">{detail}</p> : null}
    </div>
  );
}

export function ShareViewer({
  shareId,
  wsBase,
  userEmail,
}: {
  shareId: string;
  wsBase: string;
  userEmail: string;
}) {
  const t = useTranslations("share");
  const accessToken = useAccessToken();
  const store = useMemo(() => new SurfaceStore(), []);
  const [viewportRef, viewportSize] = useElementSize();

  const {
    status,
    workspace,
    participants,
    cursors,
    bubbles,
    chatEntries,
    textboxes,
    sendCursor,
    sendChat,
  } = useShareSocket({ shareId, wsBase, accessToken, store });

  const [chatInputOpen, setChatInputOpen] = useState(false);
  const myCursorRef = useRef({ x: 0.5, y: 0.5 });
  const [chatInputPos, setChatInputPos] = useState({ x: 0.5, y: 0.5 });

  const participantById = useMemo(
    () => new Map(participants.map((p) => [p.id, p] as const)),
    [participants],
  );
  const selfParticipantId = useMemo(
    () => participants.find((p) => p.email === userEmail)?.id ?? null,
    [participants, userEmail],
  );

  useWindowKeydown((event) => {
    if (event.key === "/" && !chatInputOpen && !isTypingTarget(event.target)) {
      event.preventDefault();
      setChatInputPos({ ...myCursorRef.current });
      setChatInputOpen(true);
    }
  });

  const host = participants.find((p) => p.role === "host");
  const hostName = host ? displayName(host) : t("hostFallback");

  const workspaceWidth = workspace?.size.width ?? 0;
  const workspaceHeight = workspace?.size.height ?? 0;
  const scale =
    workspace && viewportSize.width > 0 && viewportSize.height > 0
      ? Math.min(
          viewportSize.width / workspaceWidth,
          viewportSize.height / workspaceHeight,
          1,
        )
      : 1;

  const handlePointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    if (!workspace || workspaceWidth === 0 || workspaceHeight === 0) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const x = Math.min(
      1,
      Math.max(0, (event.clientX - rect.left) / rect.width),
    );
    const y = Math.min(
      1,
      Math.max(0, (event.clientY - rect.top) / rect.height),
    );
    myCursorRef.current = { x, y };
    sendCursor(x, y);
  };

  const sendChatAtCursor = (text: string) => {
    const { x, y } = myCursorRef.current;
    sendChat(text, x, y);
  };

  return (
    <div
      ref={viewportRef}
      className="relative flex h-dvh w-full items-center justify-center overflow-hidden bg-neutral-950"
    >
      {status === "connecting" ? (
        <StatusOverlay title={t("status.connecting")} spinner />
      ) : null}
      {status === "pending" ? (
        <StatusOverlay
          title={t("status.pending", { host: hostName })}
          detail={t("status.pendingDetail")}
          spinner
        />
      ) : null}
      {status === "denied" ? (
        <StatusOverlay title={t("status.denied")} />
      ) : null}
      {status === "ended" ? (
        <StatusOverlay title={t("status.ended")} />
      ) : null}

      {workspace ? (
        <div
          className="relative"
          style={{
            width: workspaceWidth,
            height: workspaceHeight,
            transform: `scale(${scale})`,
            transformOrigin: "center center",
          }}
          onPointerMove={handlePointerMove}
        >
          {workspace.panes.map((pane) => (
            <div
              key={pane.id}
              className="absolute overflow-hidden rounded-md border border-neutral-800"
              style={{
                left: pane.rect.x * workspaceWidth,
                top: pane.rect.y * workspaceHeight,
                width: pane.rect.w * workspaceWidth,
                height: pane.rect.h * workspaceHeight,
              }}
            >
              <PaneTile
                pane={pane}
                store={store}
                fontSize={BASE_FONT_SIZE}
                textbox={textboxes.get(pane.id) ?? null}
              />
            </div>
          ))}

          <CursorLayer
            cursors={cursors}
            bubbles={bubbles}
            participants={participantById}
            workspaceWidth={workspaceWidth}
            workspaceHeight={workspaceHeight}
            selfParticipantId={selfParticipantId}
          />

          {chatInputOpen ? (
            <CursorChatInput
              x={chatInputPos.x}
              y={chatInputPos.y}
              workspaceWidth={workspaceWidth}
              workspaceHeight={workspaceHeight}
              onSend={sendChatAtCursor}
              onClose={() => setChatInputOpen(false)}
            />
          ) : null}
        </div>
      ) : null}

      {status === "live" || workspace ? (
        <>
          <PresenceStrip participants={participants} />
          <ChatPanel
            entries={chatEntries}
            participants={participantById}
            onSend={sendChatAtCursor}
          />
        </>
      ) : null}
    </div>
  );
}
