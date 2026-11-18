// An agent's view, drawn by the chat pane (`cmux.ui-surface/1`, plans/cmux-next/agent-ui-surfaces-DESIGN.md),
// behind Labs `labs.agentUiSurfaces` (agentUiSurfaces.ts). The card has the permission ask's
// material (permissions/Panel.tsx: the thin rim, the card fill, small answers), a source line that
// names the server and tool it came from ("claimed" when the person did not connect that server),
// the nodes Rust normalized (nodes.tsx), and, while an action waits, the host-written confirm strip:
// what Confirm sends and to whom, Confirm (Return) and Cancel (Escape). Nothing goes to the agent
// or a tool before Confirm. An MCP App's HTML runs in the chat's render frame instead (FrameView).
//
// Streaming: the card reserves the height it reached (`min-height`, grown, never shrunk while the
// surface streams), so the transcript under it does not jump as nodes arrive.
import {
  memo,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
} from "react";
import { DialogButton } from "../../../ui/DialogButton";
import { focusRoute } from "../../../ui/focusRoute";
import { useT } from "../i18n";
import { AlertCircle, Spinner } from "../conversation/icons";
import { ranRenders } from "../conversation/renderFrame";
import { canRender, RENDER_FRAME_URL } from "../conversation/renderCardModel";
import { readConfirmAnswer, UiSurfaceClientContext, type UiSurfaceClient } from "./actions";
import { useSurfaceFrame } from "./frameBridge";
import {
  initialValues,
  readUiSurfacePending,
  sourceLine,
  type UiApprovalNode,
  type UiNode,
  type UiSurface,
  type UiSurfaceAction,
  type UiSurfacePending,
} from "./model";
import { SurfaceActionsContext, SurfaceNode, type SurfaceActions } from "./nodes";
import { SurfaceValues, SurfaceValuesContext } from "./values";
import "./uiSurface.css";

type Props = {
  surface: UiSurface;
  /// The chat's client by default (actions.ts); the gallery and tests hand their own.
  client?: UiSurfaceClient;
};

/// The first approval in the tree: `y` and `n` answer it while focus is in the card.
function firstApproval(node: UiNode | undefined): UiApprovalNode | undefined {
  if (!node) return undefined;
  if (node.type === "approval") return node;
  if ("children" in node)
    for (const child of node.children) {
      const found = firstApproval(child);
      if (found) return found;
    }
  return undefined;
}

const editing = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.isContentEditable ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement ||
    (target instanceof HTMLInputElement && !["checkbox", "radio", "range", "button"].includes(target.type)));

export const UiSurfaceCard = memo(function UiSurfaceCard({ surface, client: given }: Props) {
  const t = useT();
  const fromContext = useContext(UiSurfaceClientContext);
  const client = given ?? fromContext;
  const card = useRef<HTMLElement>(null);
  const { surfaceId, status, root } = surface;

  // Field values, local until a confirmed action sends them (values.ts).
  const [values] = useState(() => new SurfaceValues(initialValues(root)));
  useEffect(() => values.adopt(initialValues(root)), [values, root]);

  // The request on its way, the Pending acpmux answered (or the surface carries), what was sent.
  const [asking, setAsking] = useState<string>();
  const [answer, setAnswer] = useState<UiSurfacePending | null>(null);
  const [answered, setAnswered] = useState<ReadonlySet<string>>(() => new Set());
  const [failure, setFailure] = useState<string>();
  const [sending, setSending] = useState(false);
  // A request Cancel or Confirm closed stays closed while Rust's next update still carries it.
  const [closed, setClosed] = useState<string>();
  const carried = surface.pending && surface.pending.requestId !== closed ? surface.pending : null;
  const pending = answer ?? carried;
  // The committed request for the handlers below, synced after each commit (never written during render).
  const pendingRef = useRef(pending);
  useLayoutEffect(() => {
    pendingRef.current = pending;
  }, [pending]);
  // An MCP App view's post, while its frame is mounted (FrameView hands it over).
  const viewPost = useRef<((message: unknown) => void) | null>(null);
  const setViewPost = useCallback((post: ((message: unknown) => void) | null) => {
    viewPost.current = post;
  }, []);

  const cancel = useCallback(() => {
    const current = pendingRef.current;
    if (!current) return;
    setAnswer(null);
    setClosed(current.requestId);
    setFailure(undefined);
    void client.uiSurfaceCancel({ surfaceId, requestId: current.requestId }).catch(() => undefined);
  }, [client, surfaceId]);

  // A changed value drops the request (DESIGN: "Cancel or a changed value drops the request").
  useEffect(() => values.onEdit(() => cancel()), [values, cancel]);

  const act = useCallback(
    (action: UiSurfaceAction) => {
      if (asking) return;
      if (pendingRef.current) cancel();
      setAsking(action.id);
      setFailure(undefined);
      client.uiSurfaceAction({ surfaceId, actionId: action.id, values: values.snapshot() }).then(
        (result) => {
          setAsking(undefined);
          setAnswer(readUiSurfacePending(result) ?? null);
        },
        (error: unknown) => {
          setAsking(undefined);
          setFailure(error instanceof Error ? error.message : String(error));
        },
      );
    },
    [asking, cancel, client, surfaceId, values],
  );

  const confirm = useCallback(() => {
    const current = pendingRef.current;
    if (!current || sending) return;
    setSending(true);
    client.uiSurfaceConfirm({ surfaceId, requestId: current.requestId, values: values.snapshot() }).then(
      (raw) => {
        setSending(false);
        setAnswer(null);
        setClosed(current.requestId);
        setAnswered((done) => new Set([...done, current.actionId]));
        // `tool` and `link` carry the view's reply to its own request; `link` opens a checked URL.
        const result = readConfirmAnswer(raw);
        if (result.reply !== undefined) viewPost.current?.(result.reply);
        if (result.openUrl) client.openLink(result.openUrl);
      },
      (error: unknown) => {
        setSending(false);
        setFailure(error instanceof Error ? error.message : String(error));
      },
    );
  }, [client, sending, surfaceId, values]);

  const actions = useMemo<SurfaceActions>(
    () => ({
      act,
      waiting: asking ?? pending?.actionId,
      answered,
      locked: status !== "ready" || asking !== undefined || sending,
    }),
    [act, asking, pending?.actionId, answered, status, sending],
  );

  // The strip takes focus when the press that asked for it came from inside the card, so Return
  // and Escape answer it at once; focus elsewhere (the composer) is never taken.
  const strip = useRef<HTMLDivElement>(null);
  const requestId = pending?.requestId;
  useEffect(() => {
    if (!requestId || !card.current?.contains(document.activeElement)) return;
    focusRoute(
      strip.current?.querySelector<HTMLButtonElement>("[data-uis-confirm]"),
      "person",
      "the confirm strip the person just asked for, so Return and Escape answer it",
    );
  }, [requestId]);

  const approval = useMemo(() => firstApproval(root), [root]);
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.nativeEvent.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
    if (pendingRef.current) {
      if (event.key === "Enter" && !(event.target instanceof HTMLTextAreaElement)) {
        event.preventDefault();
        confirm();
      } else if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        cancel();
      }
      return;
    }
    if (!approval || editing(event.target) || actions.locked) return;
    const pick = event.key === "y" ? approval.approve : event.key === "n" ? approval.deny : undefined;
    if (!pick || answered.has(approval.approve?.id ?? "") || answered.has(approval.deny?.id ?? "")) return;
    event.preventDefault();
    act(pick);
  };

  // The reserved height: grows with the content while streaming, released once the surface settles.
  const [reserve, setReserve] = useState(0);
  useLayoutEffect(() => {
    if (status !== "streaming") {
      if (reserve) setReserve(0);
      return;
    }
    const height = card.current?.offsetHeight ?? 0;
    if (height > reserve) setReserve(height);
  });

  const source = sourceLine(surface.source);
  const claimed = surface.source.claimed === true;
  const error = status === "error" ? (surface.error ?? t("uiSurface.error")) : undefined;
  return (
    <section
      ref={card}
      className="uis-card"
      data-status={status}
      data-ui-surface={surfaceId}
      aria-label={surface.title ?? (source ? t("uiSurface.from", { source }) : t("uiSurface.card"))}
      aria-busy={status === "streaming" || undefined}
      style={reserve ? { minHeight: reserve } : undefined}
      onKeyDown={onKeyDown}
    >
      {(surface.title || source || status === "streaming") && (
        <header className="uis-head">
          {surface.title && <strong className="uis-title">{surface.title}</strong>}
          {source && (
            <span className="uis-source">
              {t("uiSurface.from", { source })}
              {claimed && (
                <span className="uis-claimed" title={t("uiSurface.claimedHint")}>
                  {t("uiSurface.claimed")}
                </span>
              )}
            </span>
          )}
          {status === "streaming" && (
            <span className="uis-status" role="status">
              <Spinner size={12} loading />
              {t("uiSurface.drawing")}
            </span>
          )}
        </header>
      )}
      <SurfaceValuesContext.Provider value={values}>
        <SurfaceActionsContext.Provider value={actions}>
          {/* A page with no render frame (the dev server, the gallery) draws Rust's fallback root instead. */}
          {surface.frame && canRender() ? (
            <FrameView surface={surface} client={client} onPost={setViewPost} onPending={setAnswer} />
          ) : (
            root && (
              <div className="uis-body">
                <SurfaceNode node={root} />
              </div>
            )
          )}
        </SurfaceActionsContext.Provider>
      </SurfaceValuesContext.Provider>
      {error && (
        <p className="uis-error" role="alert">
          <AlertCircle size={12} />
          {error}
        </p>
      )}
      {failure && (
        <p className="uis-error" role="alert">
          <AlertCircle size={12} />
          {failure}
        </p>
      )}
      {pending && (
        <div ref={strip} className="uis-confirm" role="group" aria-label={t("uiSurface.confirmLabel")}>
          <p className="uis-confirm-summary" aria-live="polite">
            {pending.summary}
          </p>
          <div className="acpmux-ask-actions">
            <DialogButton dialogKey="escape" className="acpmux-ask-action" onClick={cancel} disabled={sending}>
              {t("uiSurface.cancel")}
            </DialogButton>
            <DialogButton
              dialogKey="return"
              className="acpmux-ask-action is-primary"
              data-uis-confirm=""
              onClick={confirm}
              disabled={sending}
            >
              {t("uiSurface.confirm")}
            </DialogButton>
          </div>
        </div>
      )}
    </section>
  );
});

/// An MCP App view: Run first (the frame shares the pane's web process, as a render card's does),
/// then the view in the render frame, its messages forwarded to acpmux (frameBridge.ts).
function FrameView({
  surface,
  client,
  onPost,
  onPending,
}: {
  surface: UiSurface;
  client: UiSurfaceClient;
  onPost: (post: ((message: unknown) => void) | null) => void;
  onPending: (pending: UiSurfacePending) => void;
}) {
  const t = useT();
  const frameSpec = surface.frame!;
  const [running, setRunning] = useState(() => ranRenders.has(frameSpec.html));
  const forward = useCallback(
    (message: unknown) => client.uiSurfaceBridge({ surfaceId: surface.surfaceId, message }),
    [client, surface.surfaceId],
  );
  // A view's `ui/message` or `ui/open-link` comes back as Rust's Pending, shown in the card's strip;
  // its offered text (`draft`) goes to the composer, never sent by the page.
  const host = useMemo(() => ({ onPending, onDraft: (text: string) => client.draft(text) }), [client, onPending]);
  const { frame, height, blocked } = useSurfaceFrame(
    frameSpec.html,
    frameSpec.csp,
    frameSpec.height,
    forward,
    host,
    onPost,
  );
  return (
    <div className="uis-frame">
      {running ? (
        <iframe
          ref={frame}
          className="uis-frame-view"
          src={RENDER_FRAME_URL}
          title={surface.title ?? sourceLine(surface.source)}
          sandbox="allow-scripts"
          referrerPolicy="no-referrer"
          style={{ height }}
        />
      ) : (
        <div className="uis-frame-wait" style={{ height: frameSpec.height ?? undefined }}>
          <button
            type="button"
            className="acpmux-ask-action is-secondary"
            onClick={() => {
              ranRenders.add(frameSpec.html);
              setRunning(true);
            }}
          >
            {t("render.run")}
          </button>
        </div>
      )}
      {blocked && (
        <p className="uis-error" role="status">
          {t("uiSurface.blocked", { reason: blocked })}
        </p>
      )}
    </div>
  );
}
