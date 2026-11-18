// Back to before this turn in a chat on this machine (TurnActions `localRewind`, localRewindModel.ts):
// the prompt's Rewind (the same button as a Cloud chat's, MessageActions.tsx RewindButton) asks
// what goes back before it runs: the conversation (the default), the files, or both. The files'
// count comes from acpmux's dry run when the ask opens; where they can't be reset, their choice is
// disabled with the reason (another live chat uses the folder, no checkpoint for this turn, the
// branch moved, not a git repository). Confirm runs the rewind; the pane then shows the rewound chat
// with the prompt back in the composer, and a line above it says so with Undo
// (`LocalRewindNotice`). The ask's look is an experiment (localRewind.experiment.ts): a popover
// with two checkboxes (the default), a popover with a segmented choice, or a row under the prompt.
import {
  useContext,
  useEffect,
  useId,
  useRef,
  useState,
  useSyncExternalStore,
  type FormEvent,
  type KeyboardEvent,
} from "react";
import { experimentArm } from "../../../experiments/experiment";
import { DialogButton } from "../../../ui/DialogButton";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { ToggleGroup, Toggle } from "../../../ui/Toggle";
import { translate, useT, type Translate } from "../i18n";
import { Spinner, Undo } from "./icons";
import { ROW_ICON } from "./messageActionsModel";
import { localRewindConfirm, type LocalRewindLook } from "./localRewind.experiment";
import {
  blockedText,
  canConfirm,
  failedText,
  filesOffer,
  initialChoice,
  undoNoticeKey,
  type RewindChoice,
  type RewindDryRun,
  type RewindUndo,
} from "./localRewindModel";
import { useTranscriptReadOnly } from "./readOnly";
import { TurnActionsContext } from "./turnActions";

/// Where the ask stands: `checking` while the dry run runs, `ready` once it answered, `running`
/// while the rewind runs, `failed` when it (or the dry run) failed, with the words why.
export type RewindPhase = "checking" | "ready" | "running" | "failed";

/// The look the pane runs: the experiment's arm, read once per page.
let pageLook: LocalRewindLook | undefined;
export function localRewindLook(): LocalRewindLook {
  pageLook ??= experimentArm(localRewindConfirm);
  return pageLook;
}

// The prompt whose inline ask is open (the `inline` look draws it under the bubble, out of the
// action row the button sits in). One at a time, as a popover.
let inlineOpen: string | undefined;
const inlineListeners = new Set<() => void>();
function setInlineOpen(rowId: string | undefined) {
  if (inlineOpen === rowId) return;
  inlineOpen = rowId;
  for (const listener of inlineListeners) listener();
}
const subscribeInline = (listener: () => void) => {
  inlineListeners.add(listener);
  return () => void inlineListeners.delete(listener);
};
const useInlineOpen = () =>
  useSyncExternalStore(
    subscribeInline,
    () => inlineOpen,
    () => undefined,
  );

/// The ask as the reader sees it, whatever drives it: the gallery draws each state from props.
export function LocalRewindPanel({
  look,
  phase,
  dry,
  choice,
  error,
  onChoice,
  onConfirm,
  onCancel,
}: {
  look: LocalRewindLook;
  phase: RewindPhase;
  dry: RewindDryRun | undefined;
  choice: RewindChoice;
  error?: string;
  onChoice(choice: RewindChoice): void;
  onConfirm(): void;
  onCancel(): void;
}) {
  const t = useT();
  const whyId = useId();
  const offer = filesOffer(dry);
  const filesOpen = offer?.kind === "available";
  const conversationOpen = dry !== undefined && dry.conversation !== null;
  const busy = phase === "running" || phase === "checking";
  const why = offer?.kind === "blocked" ? blockedText(t, offer) : undefined;
  const caution =
    offer?.kind === "available" && choice.files
      ? offer.baseChanged
        ? t("rewind.blocked.baseChanged")
        : !offer.complete
          ? t("rewind.filesIncomplete")
          : undefined
      : undefined;
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!busy && canConfirm(dry, choice)) onConfirm();
  };
  // The inline row has no popover to close on Escape: the form answers it.
  const onKeyDown = (event: KeyboardEvent<HTMLFormElement>) => {
    if (look !== "inline" || event.key !== "Escape" || phase === "running") return;
    event.preventDefault();
    onCancel();
  };
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape on the inline row's controls.
    <form
      className="cv-rewind-ask"
      data-look={look}
      data-phase={phase}
      aria-busy={busy}
      aria-label={t("turn.rewind")}
      onSubmit={submit}
      onKeyDown={onKeyDown}
    >
      {look !== "inline" && <p className="cv-rewind-ask__title">{t("turn.rewind")}</p>}
      {look === "segmented" ? (
        <SegmentedChoice
          t={t}
          choice={choice}
          conversationOpen={conversationOpen}
          filesOpen={filesOpen}
          disabled={phase === "running"}
          onChoice={onChoice}
        />
      ) : (
        <div className="cv-rewind-ask__choices">
          {look === "checks" && (
            <label className="cv-rewind-ask__check">
              <input
                type="checkbox"
                checked={choice.conversation && conversationOpen}
                disabled={!conversationOpen || phase === "running"}
                onChange={(event) => onChoice({ ...choice, conversation: event.currentTarget.checked })}
              />
              <span>{t("rewind.conversation")}</span>
            </label>
          )}
          <label className="cv-rewind-ask__check" data-blocked={offer?.kind === "blocked" ? "" : undefined}>
            <input
              type="checkbox"
              checked={choice.files && filesOpen}
              disabled={!filesOpen || phase === "running"}
              aria-describedby={why ? whyId : undefined}
              onChange={(event) => onChoice({ ...choice, files: event.currentTarget.checked })}
            />
            <span>
              {offer?.kind === "available"
                ? t("rewind.alsoFilesCount", { count: t("rewind.fileCount", { n: offer.total }) })
                : phase === "checking"
                  ? t("rewind.checking")
                  : t("rewind.alsoFiles")}
            </span>
            {phase === "checking" && <Spinner size={ROW_ICON - 4} loading />}
          </label>
        </div>
      )}
      {look === "segmented" && offer?.kind === "available" && (
        <p className="cv-rewind-ask__note">{t("rewind.fileCount", { n: offer.total })}</p>
      )}
      {phase === "checking" && look === "segmented" && <p className="cv-rewind-ask__note">{t("rewind.checking")}</p>}
      {why && (
        <p
          className="cv-rewind-ask__note"
          id={whyId}
          data-blocked-reason={offer?.kind === "blocked" ? offer.reason : undefined}
        >
          {why}
        </p>
      )}
      {caution && (
        <p className="cv-rewind-ask__note" data-caution="">
          {caution}
        </p>
      )}
      {phase === "failed" && error && (
        <p className="cv-rewind-ask__error" role="alert">
          {error}
        </p>
      )}
      <div className="cv-rewind-ask__actions">
        <DialogButton dialogKey="escape" data-secondary="" disabled={phase === "running"} onClick={onCancel}>
          {t("rewind.cancel")}
        </DialogButton>
        <DialogButton
          dialogKey="return"
          type="submit"
          disabled={busy || !canConfirm(dry, choice)}
          aria-busy={phase === "running"}
        >
          {phase === "running" ? (
            <>
              <Spinner size={ROW_ICON - 4} loading />
              {t("rewind.running")}
            </>
          ) : (
            t("rewind.confirm")
          )}
        </DialogButton>
      </div>
    </form>
  );
}

type Segment = "conversation" | "files" | "both";
const segmentOf = (choice: RewindChoice): Segment =>
  choice.conversation && choice.files ? "both" : choice.files ? "files" : "conversation";

function SegmentedChoice({
  t,
  choice,
  conversationOpen,
  filesOpen,
  disabled,
  onChoice,
}: {
  t: Translate;
  choice: RewindChoice;
  conversationOpen: boolean;
  filesOpen: boolean;
  disabled: boolean;
  onChoice(choice: RewindChoice): void;
}) {
  const pick = (segment: Segment) => onChoice({ conversation: segment !== "files", files: segment !== "conversation" });
  return (
    <ToggleGroup
      variant="segmented"
      size="sm"
      className="cv-rewind-ask__segments"
      aria-label={t("turn.rewind")}
      value={[segmentOf(choice)]}
      onValueChange={(value) => {
        const next = value[0];
        if (next === "conversation" || next === "files" || next === "both") pick(next);
      }}
    >
      <Toggle value="conversation" disabled={disabled || !conversationOpen}>
        {t("rewind.conversation")}
      </Toggle>
      <Toggle value="files" disabled={disabled || !filesOpen}>
        {t("rewind.files")}
      </Toggle>
      <Toggle value="both" disabled={disabled || !filesOpen || !conversationOpen}>
        {t("rewind.both")}
      </Toggle>
    </ToggleGroup>
  );
}

/// The ask for prompt `rowId`, driven: the dry run when it mounts, then the rewind on Confirm. A
/// rewind that went closes it (the pane shows the rewound chat); one that failed says why and keeps
/// it open to try again.
function LocalRewindAsk({ rowId, look, onClose }: { rowId: string; look: LocalRewindLook; onClose(): void }) {
  const { localRewind } = useContext(TurnActionsContext);
  const [phase, setPhase] = useState<RewindPhase>("checking");
  const [dry, setDry] = useState<RewindDryRun>();
  const [choice, setChoice] = useState<RewindChoice>({ conversation: true, files: false });
  const [error, setError] = useState<string>();
  const mounted = useRef(true);
  const dryRun = localRewind?.dryRun;
  useEffect(() => {
    mounted.current = true;
    if (!dryRun) return;
    dryRun(rowId).then(
      (answer) => {
        if (!mounted.current) return;
        setDry(answer);
        setChoice(initialChoice(answer));
        setPhase("ready");
      },
      (reason: unknown) => {
        if (!mounted.current) return;
        setError(failedText(translate, reason));
        setPhase("failed");
      },
    );
    return () => {
      mounted.current = false;
    };
  }, [dryRun, rowId]);
  const confirm = () => {
    if (!localRewind) return;
    setPhase("running");
    setError(undefined);
    localRewind.apply(rowId, choice).then(
      () => {
        if (mounted.current) onClose();
      },
      (reason: unknown) => {
        if (!mounted.current) return;
        setError(failedText(translate, reason));
        setPhase("failed");
      },
    );
  };
  return (
    <LocalRewindPanel
      look={look}
      phase={phase}
      dry={dry}
      choice={choice}
      error={error}
      onChoice={setChoice}
      onConfirm={confirm}
      onCancel={onClose}
    />
  );
}

/// The prompt's Rewind in a chat on this machine: the same 24 px button as a Cloud chat's, which
/// opens the ask (a popover anchored to it, or the row under the prompt in the inline look). Drawn
/// only on a prompt acpmux took a rewind checkpoint for, never in a read-only transcript.
export function LocalRewindButton({ rowId, look = localRewindLook() }: { rowId: string; look?: LocalRewindLook }) {
  const t = useT();
  const { localRewind } = useContext(TurnActionsContext);
  const readOnly = useTranscriptReadOnly();
  const [open, setOpen] = useState(false);
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const inline = useInlineOpen();
  // A press on the button while its popover is open closes it, never closes and reopens it.
  const trigger = usePopoverTrigger(open, setOpen);
  if (!localRewind || !localRewind.ready.has(rowId) || readOnly) return null;
  const shown = look === "inline" ? inline === rowId : open;
  const opener =
    look === "inline" ? { "aria-expanded": shown, onClick: () => setInlineOpen(shown ? undefined : rowId) } : trigger;
  const label = t("turn.rewind");
  return (
    <>
      <button
        ref={setButton}
        type="button"
        className="cv-iconbtn cv-iconbtn--compact cv-turn-rewind"
        aria-label={label}
        title={label}
        {...opener}
        // Keeps the prompt's action row shown while the ask is open (conversation.css).
        data-popup-open={shown ? "" : undefined}
        data-rewind-state="idle"
        data-rewind-local=""
      >
        <Undo size={ROW_ICON} />
        <span className="cv-turn-rewind__label" aria-hidden="true">
          {t("turn.rewindShort")}
        </span>
      </button>
      {look !== "inline" && (
        <Popover
          open={open}
          onOpenChange={(next) => setOpen(next)}
          anchor={open ? button : null}
          label={label}
          id={trigger["aria-controls"]}
          side="bottom"
          align="end"
          className="cv-rewind-popover"
        >
          {open && <LocalRewindAsk rowId={rowId} look={look} onClose={() => setOpen(false)} />}
        </Popover>
      )}
    </>
  );
}

/// The inline look's ask, under prompt `rowId`'s bubble (UserBubble.tsx), while its Rewind opened it.
export function LocalRewindInline({ rowId }: { rowId: string }) {
  const inline = useInlineOpen();
  const { localRewind } = useContext(TurnActionsContext);
  if (inline !== rowId || !localRewind) return null;
  return (
    <div className="cv-rewind-inline">
      <LocalRewindAsk rowId={rowId} look="inline" onClose={() => setInlineOpen(undefined)} />
    </div>
  );
}

/// The line over the composer after a rewind: what went back, and Undo, which puts the files back
/// (when they were reset) and reopens the chat as it was. `undoing` while Undo runs.
export function LocalRewindNotice({
  undo,
  undoing,
  onUndo,
  onDismiss,
}: {
  undo: RewindUndo;
  undoing: boolean;
  onUndo(): void;
  onDismiss(): void;
}) {
  const t = useT();
  return (
    <output className="acpmux-host-line cv-rewind-notice" aria-live="polite" data-rewind-notice="">
      <span className="acpmux-host-line-message">
        {t(undoNoticeKey(undo), { count: t("rewind.fileCount", { n: undo.files }) })}
      </span>
      <DialogButton dialogKey={null} disabled={undoing} aria-busy={undoing} onClick={onUndo}>
        {undoing ? t("rewind.undoing") : t("rewind.undo")}
      </DialogButton>
      <DialogButton dialogKey={null} data-secondary="" disabled={undoing} onClick={onDismiss}>
        {t("rewind.dismiss")}
      </DialogButton>
    </output>
  );
}
