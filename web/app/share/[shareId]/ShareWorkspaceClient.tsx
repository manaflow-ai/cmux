"use client";

import {
  useCallback,
  useRef,
  useState,
  type CSSProperties,
  type CompositionEvent,
  type FormEvent,
  type KeyboardEvent,
  type PointerEvent,
} from "react";
import type { ShareParticipant, TextSelectionAwareness, WorkspaceSurface } from "../../../services/share/protocol";
import type { RenderedGhosttyTerminal } from "../../../services/share/ghosttyTerminal";
import type { TextDocumentView } from "../../../services/share/textDocument";
import {
  SHARE_CURSOR_PATH_DATA,
  SHARE_CURSOR_HOTSPOT_INSET,
  SHARE_CURSOR_SCALE,
  SHARE_CURSOR_STROKE_WIDTH,
  SHARE_CURSOR_VIEW_BOX,
} from "../../../services/share/cursorShape";
import {
  terminalCommandForKeyboardEvent,
  type TerminalInputCommand,
} from "../../../services/share/terminalInput";
import { sharePointerCoordinates } from "../../../services/share/pointerCoordinates";
import {
  initialShareWorkspaceViewState,
  ShareWorkspaceConnection,
  type ShareConnectionStatus,
} from "./ShareWorkspaceConnection";
import "./share-workspace.css";

export type ShareWorkspaceCopy = {
  readonly connecting: string;
  readonly reconnecting: string;
  readonly pendingTitle: string;
  readonly pendingDescription: string;
  readonly deniedTitle: string;
  readonly deniedDescription: string;
  readonly endedTitle: string;
  readonly endedDescription: string;
  readonly errorTitle: string;
  readonly errorDescription: string;
  readonly workspaceWaiting: string;
  readonly chatTitle: string;
  readonly chatPlaceholder: string;
  readonly send: string;
  readonly participants: string;
  readonly terminalWaiting: string;
  readonly terminalInputLabel: string;
  readonly browserWaiting: string;
  readonly unsupportedPanel: string;
  readonly textBoxLabel: string;
  readonly privacy: string;
};

const COLORS = [
  "#ff5c7a", "#50e3c2", "#7c8cff", "#ffbd4a", "#d477ff", "#55b8ff",
  "#ff7f50", "#68d36e", "#f76bd3", "#31d6ed", "#d6d84c", "#ac91ff",
] as const;

export function ShareWorkspaceClient({
  shareId,
  copy,
}: {
  shareId: string;
  copy: ShareWorkspaceCopy;
}) {
  const [view, setView] = useState(initialShareWorkspaceViewState);
  const [chatDraft, setChatDraft] = useState("");
  const connection = useRef<ShareWorkspaceConnection | null>(null);
  const lastPointerSent = useRef(0);
  const mount = useCallback((node: HTMLElement | null) => {
    connection.current?.dispose();
    connection.current = node ? new ShareWorkspaceConnection(shareId, setView) : null;
  }, [shareId]);

  const sendChat = (event: FormEvent) => {
    event.preventDefault();
    connection.current?.chat(chatDraft);
    setChatDraft("");
  };
  const movePointer = (event: PointerEvent<HTMLDivElement>) => {
    if (!view.scene || view.status !== "approved") return;
    const now = performance.now();
    if (now - lastPointerSent.current < 35) return;
    const point = sharePointerCoordinates(
      event.clientX,
      event.clientY,
      event.currentTarget.getBoundingClientRect(),
    );
    if (!point) return;
    lastPointerSent.current = now;
    connection.current?.pointer(point.x, point.y, view.scene.layoutRevision, pointerTarget(event.target));
  };

  const latestChatByUser = new Map<string, string>();
  for (const message of view.chat.slice(-12)) latestChatByUser.set(message.userId, message.text);

  return (
    <main ref={mount} className="share-page ph-no-capture">
      <header className="share-header">
        <div className="share-brand"><span className="share-brand-mark">c</span>cmux</div>
        <div className="share-participants" aria-label={copy.participants}>
          {[...view.participants.values()].slice(0, 8).map((participant) => (
            <span
              className="share-avatar"
              key={participant.connectionId}
              title={participant.displayName}
              style={{ "--participant-color": color(participant.color) } as CSSProperties}
            >
              {initials(participant.displayName)}
            </span>
          ))}
        </div>
      </header>

      {view.status !== "approved" ? (
        <StatusCard status={view.status} copy={copy} />
      ) : view.scene ? (
        <section className="share-stage-shell">
          <div className="share-workspace-title">
            <span className="share-live-dot" />
            <span>{view.scene.workspaceTitle}</span>
          </div>
          <div
            data-share-canvas
            className="share-scene-canvas"
            onPointerMove={movePointer}
            style={{ aspectRatio: `${view.scene.width} / ${view.scene.height}` }}
          >
            {view.scene.panes.map((pane) => {
              const selected = pane.surfaces.find((surface) => surface.id === pane.selectedSurfaceId) ?? pane.surfaces[0];
              if (!selected) return null;
              return (
                <article
                  key={pane.id}
                  className="share-pane"
                  data-share-target={pane.id}
                  style={paneStyle(pane.frame, view.scene!.width, view.scene!.height)}
                >
                  <div className="share-tabs">
                    {pane.surfaces.map((surface) => (
                      <span className={surface.id === selected.id ? "share-tab share-tab-selected" : "share-tab"} key={surface.id}>
                        {surface.title}
                      </span>
                    ))}
                  </div>
                  <SurfaceView
                    surface={selected}
                    terminal={view.terminals.get(selected.id)}
                    document={selected.docId ? view.documents.get(selected.docId) : undefined}
                    selections={[...view.selections.values()].filter((selection) => selection.docId === selected.docId)}
                    copy={copy}
                    onTextChange={(text) => selected.docId && connection.current?.changeText(selected.docId, text)}
                    onCompositionStart={() => selected.docId && connection.current?.beginTextComposition(selected.docId)}
                    onCompositionEnd={(text) => selected.docId && connection.current?.commitTextComposition(selected.docId, text)}
                    onSelection={(anchor, head) => selected.docId && connection.current?.selection(selected.docId, anchor, head)}
                    onTerminalInput={(command) => connection.current?.terminalInput(selected.id, command)}
                    onTerminalText={(text) => connection.current?.terminalText(selected.id, text)}
                  />
                </article>
              );
            })}
            {[...view.pointers.values()].map((pointer) => (
              <RemotePointer
                key={pointer.participant.connectionId}
                participant={pointer.participant}
                x={pointer.x}
                y={pointer.y}
                message={latestChatByUser.get(pointer.participant.userId)}
              />
            ))}
          </div>
        </section>
      ) : (
        <div className="share-status-card"><span className="share-spinner" />{copy.workspaceWaiting}</div>
      )}

      {view.status === "approved" && (
        <aside className="share-chat">
          <div className="share-chat-header">{copy.chatTitle}</div>
          <div className="share-chat-messages" aria-live="polite">
            {view.chat.map((message) => (
              <div className="share-chat-message" key={message.id}>
                <span style={{ color: color(message.color) }}>{message.displayName}</span>
                <p>{message.text}</p>
              </div>
            ))}
          </div>
          <form className="share-chat-form" onSubmit={sendChat}>
            <input
              value={chatDraft}
              onChange={(event) => setChatDraft(event.target.value)}
              placeholder={copy.chatPlaceholder}
              maxLength={500}
              autoComplete="off"
            />
            <button type="submit" disabled={!chatDraft.trim()}>{copy.send}</button>
          </form>
        </aside>
      )}
      <div className="share-privacy">{copy.privacy}</div>
    </main>
  );
}

function StatusCard({ status, copy }: { status: ShareConnectionStatus; copy: ShareWorkspaceCopy }) {
  const [title, description] = statusCopy(status, copy);
  return (
    <section className="share-status-card">
      {(status === "connecting" || status === "reconnecting") && <span className="share-spinner" />}
      <h1>{title}</h1>
      {description && <p>{description}</p>}
    </section>
  );
}

function SurfaceView({
  surface,
  terminal,
  document,
  selections,
  copy,
  onTextChange,
  onCompositionStart,
  onCompositionEnd,
  onSelection,
  onTerminalInput,
  onTerminalText,
}: {
  surface: WorkspaceSurface;
  terminal?: RenderedGhosttyTerminal;
  document?: TextDocumentView;
  selections: readonly TextSelectionAwareness[];
  copy: ShareWorkspaceCopy;
  onTextChange: (text: string) => void;
  onCompositionStart: () => void;
  onCompositionEnd: (text: string) => void;
  onSelection: (anchor: number, head: number) => void;
  onTerminalInput: (command: TerminalInputCommand) => void;
  onTerminalText: (text: string) => void;
}) {
  if (surface.kind === "terminal") {
    return terminal
      ? <GhosttyTerminal terminal={terminal} inputLabel={copy.terminalInputLabel} onInput={onTerminalInput} onText={onTerminalText} />
      : <PanelWaiting text={copy.terminalWaiting} />;
  }
  if (surface.kind === "browser") {
    return surface.imageDataUrl
      ? (
          // Browser viewport images arrive as short-lived, authenticated share frames.
          // eslint-disable-next-line @next/next/no-img-element
          <img className="share-browser-snapshot" src={surface.imageDataUrl} alt={surface.title} />
        )
      : <PanelWaiting text={copy.browserWaiting} />;
  }
  if (surface.kind === "textbox") {
    const mode = sharedTextBoxSurfaceMode(!!terminal, !!document);
    const textBox = document
      ? <CollaborativeTextBox
          document={document}
          selections={selections}
          label={copy.textBoxLabel}
          onTextChange={onTextChange}
          onCompositionStart={onCompositionStart}
          onCompositionEnd={onCompositionEnd}
          onSelection={onSelection}
        />
      : null;
    if (mode === "combined" && terminal && document) {
      return (
        <div className="share-terminal-textbox-surface">
          <GhosttyTerminal
            terminal={terminal}
            embedded
            inputLabel={copy.terminalInputLabel}
            onInput={onTerminalInput}
            onText={onTerminalText}
          />
          <CollaborativeTextBox
            document={document}
            selections={selections}
            label={copy.textBoxLabel}
            compact
            onTextChange={onTextChange}
            onCompositionStart={onCompositionStart}
            onCompositionEnd={onCompositionEnd}
            onSelection={onSelection}
          />
        </div>
      );
    }
    if (mode === "textbox" && textBox) return textBox;
    if (mode === "terminal" && terminal) {
      return <GhosttyTerminal terminal={terminal} inputLabel={copy.terminalInputLabel} onInput={onTerminalInput} onText={onTerminalText} />;
    }
    return <PanelWaiting text={copy.workspaceWaiting} />;
  }
  return <PanelWaiting text={copy.unsupportedPanel} />;
}

export function sharedTextBoxSurfaceMode(
  hasTerminal: boolean,
  hasDocument: boolean,
): "combined" | "textbox" | "terminal" | "waiting" {
  if (hasTerminal && hasDocument) return "combined";
  if (hasDocument) return "textbox";
  if (hasTerminal) return "terminal";
  return "waiting";
}

function GhosttyTerminal({
  terminal,
  embedded = false,
  inputLabel,
  onInput,
  onText,
}: {
  terminal: RenderedGhosttyTerminal;
  embedded?: boolean;
  inputLabel: string;
  onInput: (command: TerminalInputCommand) => void;
  onText: (text: string) => void;
}) {
  const [scale, setScale] = useState(1);
  const resizeObserver = useRef<ResizeObserver | null>(null);
  const inputProxy = useRef<HTMLTextAreaElement | null>(null);
  const composing = useRef(false);
  const mount = useCallback((node: HTMLDivElement | null) => {
    resizeObserver.current?.disconnect();
    resizeObserver.current = null;
    if (!node) return;
    const grid = node.querySelector<HTMLElement>("[data-ghostty-grid]");
    if (!grid) return;
    const measure = () => {
      if (!node.isConnected) return;
      const naturalWidth = grid.offsetWidth;
      const naturalHeight = grid.offsetHeight;
      if (naturalWidth <= 0 || naturalHeight <= 0) return;
      const next = Math.min(1, (node.clientWidth - 20) / naturalWidth, (node.clientHeight - 16) / naturalHeight);
      setScale(Math.max(0.05, Number.isFinite(next) ? next : 1));
    };
    measure();
    if (typeof ResizeObserver !== "undefined") {
      resizeObserver.current = new ResizeObserver(measure);
      resizeObserver.current.observe(node);
      resizeObserver.current.observe(grid);
    }
  }, []);
  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const command = terminalCommandForKeyboardEvent(event.nativeEvent);
    if (!command) return;
    event.preventDefault();
    event.stopPropagation();
    onInput(command);
  };
  const focusInput = () => inputProxy.current?.focus({ preventScroll: true });
  const cursor = terminal.cursor;
  const cursorColumn = cursor ? Math.max(0, cursor.column - (cursor.wide ? 1 : 0)) : 0;
  return (
    <div
      ref={mount}
      className={embedded ? "share-terminal share-terminal-embedded" : "share-terminal"}
      data-share-target={terminal.surfaceId}
      role="application"
      aria-label={inputLabel}
      tabIndex={0}
      onFocus={(event) => {
        if (event.target === event.currentTarget) focusInput();
      }}
      onPointerDown={(event) => {
        if (event.button === 0) focusInput();
      }}
      onKeyDown={handleKeyDown}
      style={{ background: terminal.background, color: terminal.foreground } as CSSProperties}
    >
      <textarea
        ref={inputProxy}
        className="share-terminal-input-proxy"
        aria-label={inputLabel}
        tabIndex={-1}
        autoCapitalize="none"
        autoComplete="off"
        autoCorrect="off"
        spellCheck={false}
        onCompositionStart={() => { composing.current = true; }}
        onCompositionEnd={(event) => {
          composing.current = false;
          const value = event.currentTarget.value || event.data;
          event.currentTarget.value = "";
          if (value) onText(value);
        }}
        onInput={(event) => {
          if (composing.current) return;
          const value = event.currentTarget.value;
          event.currentTarget.value = "";
          if (value) onText(value);
        }}
      />
      <div
        className="share-terminal-scale"
        data-ghostty-grid
        style={{
          "--terminal-scale": scale,
          width: `${terminal.columns}ch`,
          height: `${terminal.rows * 1.28}em`,
        } as CSSProperties}
      >
        <div className="share-terminal-html" dangerouslySetInnerHTML={{ __html: terminal.html }} />
        {cursor && (
          <span
            aria-hidden="true"
            className={`share-terminal-cursor share-terminal-cursor-${cursor.style}${cursor.blinking ? " share-terminal-cursor-blink" : ""}`}
            style={{
              left: `${cursorColumn}ch`,
              top: `${cursor.row * 1.28}em`,
              width: cursor.wide ? "2ch" : undefined,
              borderColor: cursor.color,
              backgroundColor: cursor.color,
            }}
          />
        )}
      </div>
    </div>
  );
}

function CollaborativeTextBox({
  document,
  selections,
  label,
  onTextChange,
  onCompositionStart,
  onCompositionEnd,
  onSelection,
  compact = false,
}: {
  document: TextDocumentView;
  selections: readonly TextSelectionAwareness[];
  label: string;
  onTextChange: (text: string) => void;
  onCompositionStart: () => void;
  onCompositionEnd: (text: string) => void;
  onSelection: (anchor: number, head: number) => void;
  compact?: boolean;
}) {
  const [composition, setComposition] = useState<string | null>(null);
  const composing = useRef(false);
  const value = composition ?? document.text;
  const completeComposition = (event: CompositionEvent<HTMLTextAreaElement>) => {
    const next = event.currentTarget.value;
    composing.current = false;
    setComposition(null);
    onCompositionEnd(next);
  };
  return (
    <div className={compact ? "share-textbox share-textbox-compact" : "share-textbox"} data-share-target={document.docId}>
      <div className="share-remote-selections" aria-hidden="true">
        {selections.map((selection) => {
          const caret = textCaret(value, selection.headUTF16);
          return (
            <span
              className="share-text-caret"
              key={selection.participant.connectionId}
              style={{
                left: `calc(${compact ? 10 : 16}px + ${caret.column}ch)`,
                top: `calc(${compact ? 8 : 14}px + ${caret.line} * ${compact ? 1.4 : 1.5}em)`,
                borderColor: color(selection.participant.color),
              }}
            >
              <span style={{ background: color(selection.participant.color) }}>{selection.participant.displayName}</span>
            </span>
          );
        })}
      </div>
      <textarea
        aria-label={label}
        value={value}
        wrap="off"
        spellCheck={false}
        onCompositionStart={(event) => {
          composing.current = true;
          setComposition(event.currentTarget.value);
          onCompositionStart();
        }}
        onCompositionEnd={completeComposition}
        onChange={(event) => composing.current ? setComposition(event.target.value) : onTextChange(event.target.value)}
        onSelect={(event) => onSelection(event.currentTarget.selectionStart, event.currentTarget.selectionEnd)}
      />
    </div>
  );
}

function RemotePointer({
  participant,
  x,
  y,
  message,
}: {
  participant: ShareParticipant;
  x: number;
  y: number;
  message?: string;
}) {
  const participantColor = color(participant.color);
  return (
    <div
      className="share-remote-pointer"
      style={{
        left: `${x * 100}%`,
        top: `${y * 100}%`,
        transform: `translate(-${SHARE_CURSOR_HOTSPOT_INSET}px, -${SHARE_CURSOR_HOTSPOT_INSET}px)`,
      }}
    >
      <svg width="24" height="30" viewBox={SHARE_CURSOR_VIEW_BOX} aria-hidden="true">
        <g transform={`scale(${SHARE_CURSOR_SCALE})`}>
          <path
            d={SHARE_CURSOR_PATH_DATA}
            fill={participantColor}
            stroke="#fff"
            strokeWidth={SHARE_CURSOR_STROKE_WIDTH}
            strokeLinejoin="round"
            style={{ paintOrder: "stroke fill" }}
          />
        </g>
      </svg>
      <span className="share-pointer-name" style={{ background: participantColor }}>{participant.displayName}</span>
      {message && <span className="share-pointer-bubble">{message}</span>}
    </div>
  );
}

function PanelWaiting({ text }: { text: string }) {
  return <div className="share-panel-waiting">{text}</div>;
}

function statusCopy(status: ShareConnectionStatus, copy: ShareWorkspaceCopy): readonly [string, string] {
  switch (status) {
    case "connecting": return [copy.connecting, ""];
    case "reconnecting": return [copy.reconnecting, ""];
    case "pending": return [copy.pendingTitle, copy.pendingDescription];
    case "denied": return [copy.deniedTitle, copy.deniedDescription];
    case "ended": return [copy.endedTitle, copy.endedDescription];
    case "error": return [copy.errorTitle, copy.errorDescription];
    case "approved": return [copy.workspaceWaiting, ""];
  }
}

function paneStyle(frame: { x: number; y: number; width: number; height: number }, width: number, height: number): CSSProperties {
  return {
    left: `${frame.x / width * 100}%`,
    top: `${frame.y / height * 100}%`,
    width: `${frame.width / width * 100}%`,
    height: `${frame.height / height * 100}%`,
  };
}

function pointerTarget(target: EventTarget): string | undefined {
  return target instanceof Element ? target.closest<HTMLElement>("[data-share-target]")?.dataset.shareTarget : undefined;
}

function textCaret(text: string, offset: number): { line: number; column: number } {
  const before = text.slice(0, Math.max(0, Math.min(offset, text.length)));
  const lines = before.split("\n");
  return { line: lines.length - 1, column: [...(lines.at(-1) ?? "")].length };
}

function initials(name: string): string {
  return name.split(/\s+/u).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "?";
}

function color(index: number): string {
  return COLORS[Math.abs(Math.floor(index)) % COLORS.length] ?? COLORS[0];
}
