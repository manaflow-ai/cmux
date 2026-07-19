"use client";

// Root client component for cmux.com/share/<code>: cmux-shaped shell
// (sidebar of shared workspaces + workspace pane area), remote cursors, and
// the floating session chat.

import { useRef, useState, type ReactNode } from "react";
import { useTranslations } from "next-intl";

import { participantColor } from "./share-colors";
import { ChatPanel } from "./share-chat";
import type { ShareClient } from "./share-connection";
import { CursorLayer } from "./share-cursors";
import {
  createPaneRectRegistry,
  LayoutView,
  PaneRegistryProvider,
} from "./share-panes";
import type { CursorPos, Participant } from "./share-protocol";
import { useShareClient, useStoreValue } from "./use-store";

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
  const cursors = useStoreValue(client.cursors);
  const t = useTranslations("share");
  const [registry] = useState(createPaneRectRegistry);
  const [workspaceEl, setWorkspaceEl] = useState<HTMLElement | null>(null);
  const [bubbleDraft, setBubbleDraft] = useState<{
    pos: CursorPos;
    clientX: number;
    clientY: number;
  } | null>(null);
  const lastPointer = useRef<{ pos: CursorPos; clientX: number; clientY: number } | null>(null);

  const activeLayout = session.activeWs ? (session.layouts[session.activeWs] ?? null) : null;
  const canType = session.you?.role === "editor";
  const host = session.participants.find((p) => p.isHost);

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

      <div className="flex min-h-0 flex-1">
        <aside className="flex w-52 shrink-0 flex-col border-r border-neutral-800">
          <p className="px-3 pb-1 pt-3 text-[10px] uppercase tracking-wider text-neutral-500">
            {t("workspaces")}
          </p>
          <nav className="min-h-0 flex-1 overflow-y-auto">
            {session.shared.map((workspace) => {
              const here = session.participants.filter(
                (p) => p.connected && p.focusWs === workspace.id,
              );
              const selected = workspace.id === session.activeWs;
              return (
                <button
                  key={workspace.id}
                  type="button"
                  onClick={() => client.setActiveWorkspace(workspace.id)}
                  className={`flex w-full items-center gap-2 px-3 py-1.5 text-left text-xs ${
                    selected
                      ? "bg-neutral-800/80 text-white"
                      : "text-neutral-400 hover:bg-neutral-900 hover:text-neutral-200"
                  }`}
                >
                  <span className="truncate">{workspace.title || workspace.id}</span>
                  <span className="ml-auto flex gap-1">
                    {here.map((p) => (
                      <span
                        key={p.user}
                        title={p.email}
                        className="h-2 w-2 rounded-full"
                        style={{ backgroundColor: participantColor(p.color) }}
                      />
                    ))}
                  </span>
                </button>
              );
            })}
          </nav>
          <p className="px-3 pb-1 pt-2 text-[10px] uppercase tracking-wider text-neutral-500">
            {t("participants")}
          </p>
          <div className="max-h-48 overflow-y-auto pb-2">
            {session.participants.map((p) => (
              <ParticipantRow
                key={p.user}
                participant={p}
                self={p.user === session.you?.user}
                following={session.followUser === p.user}
                onFollowToggle={() =>
                  client.follow(session.followUser === p.user ? null : p.user)
                }
              />
            ))}
          </div>
        </aside>

        <main
          ref={setWorkspaceEl}
          className="relative min-w-0 flex-1"
          onPointerMove={(e) => {
            const target = (e.target as HTMLElement).closest<HTMLElement>("[data-share-pane]");
            const key = target?.dataset.sharePane;
            if (!target || !key) return;
            const [ws, pane] = key.split(" ");
            if (!ws || !pane) return;
            const rect = target.getBoundingClientRect();
            lastPointer.current = {
              pos: {
                ws,
                pane,
                x: Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)),
                y: Math.min(1, Math.max(0, (e.clientY - rect.top) / rect.height)),
              },
              clientX: e.clientX,
              clientY: e.clientY,
            };
            // One shared path for presence cursors across every pane kind.
            client.sendCursor(lastPointer.current.pos);
          }}
          onPointerLeave={() => {
            lastPointer.current = null;
            client.sendCursor(null);
          }}
          onKeyDown={(e) => {
            // "/" over the workspace (not while typing into a pane or input)
            // opens a Figma-style bubble at the pointer.
            if (e.key !== "/" || bubbleDraft) return;
            const tag = (e.target as HTMLElement).tagName;
            if (tag === "INPUT" || tag === "TEXTAREA") return;
            if ((e.target as HTMLElement).getAttribute("role") === "textbox") return;
            if (!lastPointer.current || !workspaceEl) return;
            e.preventDefault();
            const rect = workspaceEl.getBoundingClientRect();
            setBubbleDraft({
              pos: lastPointer.current.pos,
              clientX: lastPointer.current.clientX - rect.left,
              clientY: lastPointer.current.clientY - rect.top,
            });
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
                participants={session.participants}
                selfUser={session.you?.user ?? null}
              />
            </PaneRegistryProvider>
          ) : (
            <div className="flex h-full items-center justify-center text-xs text-neutral-500">
              {t("noWorkspaces")}
            </div>
          )}

          <CursorLayer
            cursors={cursors}
            participants={session.participants}
            selfUser={session.you?.user ?? null}
            activeWs={session.activeWs}
            registry={registry}
            container={workspaceEl}
          />

          {bubbleDraft ? (
            <BubbleComposer
              x={bubbleDraft.clientX}
              y={bubbleDraft.clientY}
              color={participantColor(session.you?.color ?? 0)}
              onSubmit={(text) => {
                client.sendChat(text, bubbleDraft.pos);
                setBubbleDraft(null);
              }}
              onCancel={() => setBubbleDraft(null)}
            />
          ) : null}

          <ChatPanel
            chat={session.chat}
            participants={session.participants}
            selfUser={session.you?.user ?? null}
            onSend={(text) => client.sendChat(text)}
          />
        </main>
      </div>
    </div>
  );
}

function ParticipantDots({ participants }: { participants: Participant[] }): ReactNode {
  return (
    <div className="flex -space-x-1">
      {participants
        .filter((p) => p.connected)
        .map((p) => (
          <span
            key={p.user}
            title={p.email}
            className="h-4 w-4 rounded-full border border-[#0a0a0a] text-center text-[9px] font-semibold leading-4 text-white"
            style={{ backgroundColor: participantColor(p.color) }}
          >
            {(p.email || p.user).slice(0, 1).toUpperCase()}
          </span>
        ))}
    </div>
  );
}

function ParticipantRow({
  participant,
  self,
  following,
  onFollowToggle,
}: {
  participant: Participant;
  self: boolean;
  following: boolean;
  onFollowToggle: () => void;
}): ReactNode {
  const t = useTranslations("share");
  return (
    <div className="flex items-center gap-2 px-3 py-1 text-[11px]">
      <span
        className={`h-2 w-2 shrink-0 rounded-full ${participant.connected ? "" : "opacity-30"}`}
        style={{ backgroundColor: participantColor(participant.color) }}
      />
      <span className={`truncate ${participant.connected ? "text-neutral-300" : "text-neutral-600"}`}>
        {participant.email || participant.user}
        {participant.isHost ? ` · ${t("hostBadge")}` : ""}
        {self ? ` · ${t("chatYou")}` : ""}
      </span>
      {!self && participant.connected ? (
        <button
          type="button"
          onClick={onFollowToggle}
          className={`ml-auto shrink-0 rounded px-1.5 py-0.5 text-[10px] ${
            following
              ? "bg-[#2d8cff] text-white"
              : "text-neutral-500 hover:bg-neutral-800 hover:text-neutral-300"
          }`}
        >
          {following ? t("followingLabel") : t("followLabel")}
        </button>
      ) : null}
    </div>
  );
}

function BubbleComposer({
  x,
  y,
  color,
  onSubmit,
  onCancel,
}: {
  x: number;
  y: number;
  color: string;
  onSubmit: (text: string) => void;
  onCancel: () => void;
}): ReactNode {
  const t = useTranslations("share");
  const [text, setText] = useState("");
  return (
    <div style={{ position: "absolute", left: x, top: y, zIndex: 60 }}>
      <input
        ref={(el) => el?.focus()}
        value={text}
        onChange={(e) => setText(e.target.value)}
        onBlur={onCancel}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            if (text.trim()) onSubmit(text);
            else onCancel();
          } else if (e.key === "Escape") {
            e.preventDefault();
            onCancel();
          }
          e.stopPropagation();
        }}
        placeholder={t("bubblePlaceholder")}
        className="w-56 rounded-2xl rounded-tl-sm border-0 px-3 py-2 text-xs text-white shadow-xl outline-none placeholder:text-white/60"
        style={{ backgroundColor: color }}
      />
    </div>
  );
}
