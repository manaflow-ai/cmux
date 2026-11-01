// Attachments in the prompt are ID-bound editor atoms. Paste/drop inserts their pending IDs
// at the caret; resolution fills the same node. Deletion takes the payload out, undo restores it,
// and moving a node preserves its place among text. Settings can draw these same payloads in the
// strip instead, without rewriting the draft or its sent order.
import { memo, type ReactNode, type RefObject, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal, flushSync } from "react-dom";
import {
  type ComposerAttachment,
  type DroppedKind,
  inlineTokenIds,
  inlineCopyParent,
  orderedByMarks,
} from "../attachments";
import { FileDoc, ImageIcon, Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import type { MarkdownFieldHandle } from "../MarkdownField";
import { AttachmentChip, RetryButton, UploadProgress, type PendingAttachment } from "./attachmentIntake";
import { keptThumb } from "./imagePool";
import { reordered } from "./stripReorder";

type Options = {
  field: RefObject<MarkdownFieldHandle | null>;
  scope?: string;
  /// The prompt's markdown as the composer holds it.
  text: string;
  attachments: readonly ComposerAttachment[];
  attachmentsRef: RefObject<ComposerAttachment[]>;
  setAttachments(update: (current: ComposerAttachment[]) => ComposerAttachment[]): void;
  pending: readonly PendingAttachment[];
  /// A pending chip's cancel (attachmentIntake.tsx).
  cancel(id: string): void;
  retry(id: string): void;
  /// A cancelled loading chip's file read again under its id (attachmentIntake.tsx `revive`).
  revive(id: string): boolean;
  expand(id: string): void;
  /// Whether a paste or drop now places what it brings in the text (not in shell mode).
  placing(): boolean;
  /// A Codex chat: a PDF's chip says it goes as a file (attachmentIntake.tsx PdfAttachmentChip).
  codex?: boolean;
  /// Why a staged image's original failed to upload, by id: its chip in the text shows Retry, as the
  /// strip's does (attachmentIntake.tsx `originalFailures`).
  originalFailures?: Readonly<Record<string, string>>;
};

export function useInlineAttachments(options: Options) {
  const live = useRef(options);
  live.current = options;
  /// The markdown last seen, from an edit or from outside: what the next edit changed.
  const seen = useRef(options.text);
  /// Attachments taken out of the text or the strip, by id, for an undo or a paste of their node.
  const removed = useRef(new Map<string, ComposerAttachment>());
  /// Placeholders this composer placed in the text, until each is a chip or gone.
  const placed = useRef(new Set<string>());
  /// Placeholders whose node an edit took out while they loaded: an undo brings each back loading.
  const cancelled = useRef(new Set<string>());
  /// Attachments sent with a prompt: an undo of the send's clear brings their nodes back with no
  /// attachment to draw, so they leave the text again. One the host puts back (a refusal, Edit on a
  /// failed prompt) is the composer's again.
  const sentIds = useRef(new Set<string>());
  /// From a send until its clear is done (the same task): the clear takes the text's nodes out, and a
  /// file among them still uploading is not sent (useSendWhenAttached) but stays for the next prompt,
  /// never cancelled. Only the person's own edit cancels one (review of #26667).
  const clearing = useRef(false);
  useLayoutEffect(() => {
    removed.current.clear();
    placed.current.clear();
    cancelled.current.clear();
    sentIds.current.clear();
  }, [options.scope]);
  const [views, setViews] = useState<ReadonlyMap<string, HTMLElement>>(() => new Map());

  // A value from outside (a chat's own draft, a send's clear) is not an edit: nothing is removed
  // for it, its attachments come with it (keptAttachments.ts).
  useLayoutEffect(() => {
    seen.current = options.text;
    placedNow.current = placedIn(options.text, true);
  }, [options.text]);

  const keep = (attachment: ComposerAttachment) => {
    removed.current.delete(attachment.id);
    removed.current.set(attachment.id, attachment);
  };

  // A placeholder that ended as no chip of its id (an image that went as a link to its file) leaves
  // the text; one that became its chip is the chip's.
  useEffect(() => {
    const { attachments, pending, field } = live.current;
    for (const id of placed.current) {
      if (pending.some((chip) => chip.id === id)) continue;
      placed.current.delete(id);
      if (!attachments.some((attachment) => attachment.id === id)) field.current?.removeInline(id);
    }
  }, [options.pending, options.attachments]);

  const sourceFor = (id: string): ComposerAttachment | undefined => {
    let parent: string | undefined = id;
    while (parent !== undefined) {
      const found =
        live.current.attachmentsRef.current.find((item) => item.id === parent) ?? removed.current.get(parent);
      if (found) return found;
      parent = inlineCopyParent(parent);
    }
    return undefined;
  };
  const known = (id: string) =>
    placed.current.has(id) ||
    cancelled.current.has(id) ||
    live.current.pending.some((chip) => chip.id === id) ||
    sourceFor(id) !== undefined;
  /// The attachments placed in the text: the editor's own nodes, never text the person typed or
  /// pasted in a token's shape (review of #26667); read from `markdown`, as the editor reads a value,
  /// before the editor is made. `all`: also the nodes of ids the composer does not know.
  const placedIn = (markdown: string, all = false) => {
    const ids = live.current.field.current?.inlineIds();
    if (!ids) return inlineTokenIds(markdown, all ? undefined : known);
    return all ? ids : ids.filter(known);
  };
  /// The nodes in the text the last edit left, or the value from outside put there, by id.
  const placedNow = useRef<string[]>([]);
  /// Whether `id` went with a prompt and has not been put back.
  const isSent = (id: string) =>
    sentIds.current.has(id) && !live.current.attachmentsRef.current.some((attachment) => attachment.id === id);

  const [api] = useState(() => ({
    /// The person's paste or drop made `chips`: each goes in at the caret, images and files alike, so
    /// the prompt reads text, image, text, file as written (attachmentIntake.tsx `place`).
    place(chips: readonly PendingAttachment[], _kind: DroppedKind) {
      const { placing, field } = live.current;
      const ids = chips.map((chip) => chip.id);
      if (!ids.length || !placing()) return;
      for (const id of ids) placed.current.add(id);
      if (!field.current?.insertInline(ids)) for (const id of ids) placed.current.delete(id);
    },
    ready() {
      const { attachments, field, placing } = live.current;
      if (!placing()) return;
      const marks = new Set(placedIn(field.current?.value() ?? seen.current));
      const fresh = attachments.filter((chip) => !marks.has(chip.id) && !removed.current.has(chip.id));
      if (fresh.length) field.current?.insertInline(fresh.map((chip) => chip.id));
    },
    /// The prompt changed by an edit (MarkdownField `onChange`), to `markdown`.
    edited(markdown: string) {
      seen.current = markdown;
      const nodes = placedIn(markdown, true);
      const stale = nodes.filter(isSent);
      // After the edit's own render: the field is still dispatching it.
      if (stale.length)
        queueMicrotask(() => stale.filter(isSent).forEach((id) => live.current.field.current?.removeInline(id)));
      const was = placedNow.current.filter(known);
      const now = nodes.filter(known);
      placedNow.current = nodes;
      if (!was.length && !now.length) return;
      const kept = new Set(now);
      const had = new Set(was);
      const gone = new Set(was.filter((id) => !kept.has(id)));
      const came = now.filter((id) => !had.has(id));
      const { setAttachments, attachmentsRef, pending, cancel } = live.current;
      if (!clearing.current)
        for (const id of gone)
          if (placed.current.delete(id) || pending.some((chip) => chip.id === id)) {
            cancelled.current.add(id);
            cancel(id);
          }
      // Undo of a loading chip's deletion: it reads again under its id and loads in its node; one whose
      // file is not kept leaves the text, never an empty atom.
      for (const id of came) {
        if (!cancelled.current.delete(id) || sourceFor(id)) continue;
        if (live.current.revive(id)) placed.current.add(id);
        else queueMicrotask(() => live.current.field.current?.removeInline(id));
      }
      for (const attachment of attachmentsRef.current) if (gone.has(attachment.id)) keep(attachment);
      const update = (current: ComposerAttachment[]) => {
        let next = gone.size ? current.filter((attachment) => !gone.has(attachment.id)) : current;
        for (const id of came) {
          if (next.some((attachment) => attachment.id === id)) continue;
          // Undo, or a cut pasted back: the same attachment. A copy pasted beside its original: a
          // copy of it under the node's own id.
          const source = sourceFor(id);
          if (source) next = [...next, { ...source, id }];
        }
        return orderedByMarks(next, now);
      };
      attachmentsRef.current = update(attachmentsRef.current);
      setAttachments(update);
    },
    /// A strip chip's ×: its node leaves the text too.
    remove(id: string) {
      const { attachmentsRef, setAttachments, field } = live.current;
      const attachment = attachmentsRef.current.find((each) => each.id === id);
      if (attachment) keep(attachment);
      attachmentsRef.current = attachmentsRef.current.filter((each) => each.id !== id);
      setAttachments((current) => current.filter((each) => each.id !== id));
      field.current?.removeInline(id);
    },
    /// A loading chip's × in the strip: its place in the text goes with it.
    cancel(id: string) {
      placed.current.delete(id);
      live.current.cancel(id);
      live.current.field.current?.removeInline(id);
    },
    /// The strip's drag: the attachments placed in the text trade places there too.
    reorder(id: string, index: number) {
      const { attachmentsRef, setAttachments, field } = live.current;
      const next = reordered(attachmentsRef.current, id, index);
      attachmentsRef.current = next;
      setAttachments(() => next);
      const inText = new Set(placedIn(seen.current));
      if (inText.size > 1)
        field.current?.orderInline(next.filter((each) => inText.has(each.id)).map((each) => each.id));
    },
    /// The attachments sent with a prompt are gone for good: no undo brings them back. The send's
    /// clear follows in the same task (Composer.tsx `clear`).
    sent(ids: Iterable<string>) {
      for (const id of ids) {
        removed.current.delete(id);
        placed.current.delete(id);
        sentIds.current.add(id);
      }
      clearing.current = true;
      queueMicrotask(() => {
        clearing.current = false;
      });
    },
    /// A failed chip's Retry and a pasted chip's open, stable across renders so the chips keep still
    /// while the person types (InlineChip is memoized).
    retry: (id: string) => live.current.retry(id),
    /// A pasted chip opened: kept first, so an undo that brings its node back brings its text too.
    expand: (id: string) => {
      const attachment = live.current.attachmentsRef.current.find((each) => each.id === id);
      if (attachment) keep(attachment);
      live.current.expand(id);
    },
    known,
    /// The field tells its nodes' elements in a microtask after the change that made them (MarkdownField
    /// `tellInlineViews`): their chips draw before that task's frame paints, so a paste's placeholder
    /// shows in the paste's own frame, as the strip's does (composer-paste-instant.test.tsx).
    onInlineViews: (next: ReadonlyMap<string, HTMLElement>) => flushSync(() => setViews(next)),
  }));

  useLayoutEffect(() => {
    for (const attachment of options.attachments) sentIds.current.delete(attachment.id);
    api.ready();
  }, [options.attachments, api]);
  // Also when placing starts (the strip view switched to inline, shell mode ended): what was added
  // meanwhile goes into the text. Read after each commit, never during render: a consumer's
  // `placing` may read state it declares after this hook.
  const placingWas = useRef<boolean | undefined>(undefined);
  useLayoutEffect(() => {
    const now = live.current.placing();
    if (now === placingWas.current) return;
    placingWas.current = now;
    if (now) api.ready();
  });

  const chips = [...views].map(([id, dom]) =>
    createPortal(
      <InlineChip
        id={id}
        attachment={options.attachments.find((attachment) => attachment.id === id)}
        pending={options.pending.find((chip) => chip.id === id)}
        onRemove={api.remove}
        onCancel={api.cancel}
        onRetry={api.retry}
        onExpand={api.expand}
        codex={options.codex ?? false}
        originalFailed={options.originalFailures?.[id]}
      />,
      dom,
      id,
    ),
  );
  return { ...api, chips: chips as ReactNode };
}

/// An attachment as the text shows it: the strip's own chip (attachmentIntake.tsx AttachmentChip), with
/// its preview, open, play and × (which takes it out of the prompt); a file still being read spins
/// (its × cancels it); one that could not be read says why, with Retry. Memoized: a keystroke
/// re-renders the composer, never a chip whose attachment did not change.
const InlineChip = memo(function InlineChip({
  id,
  attachment,
  pending,
  onRemove,
  onCancel,
  onRetry,
  onExpand,
  codex,
  originalFailed,
}: {
  id: string;
  attachment: ComposerAttachment | undefined;
  pending: PendingAttachment | undefined;
  onRemove(id: string): void;
  onCancel(id: string): void;
  onRetry(id: string): void;
  onExpand(id: string): void;
  codex: boolean;
  originalFailed: string | undefined;
}) {
  const t = useT();

  // A node whose attachment is not here (yet: a chat's kept chips still on their way) draws nothing.
  if (!attachment && !pending) return null;
  const name = imageLabel(t, { name: attachment?.name ?? pending?.name, ...keptThumb(id) });
  const remove = (
    <button
      type="button"
      className="acpmux-md-inline-remove"
      aria-label={t(pending && !pending.failed ? "composer.cancelAttachment" : "composer.removeAttachment", { name })}
      onClick={() => (attachment ? onRemove(id) : onCancel(id))}
    >
      <svg viewBox="0 0 16 16" width="8" height="8" aria-hidden="true">
        <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      </svg>
    </button>
  );
  if (!attachment)
    return (
      <span
        className="acpmux-md-inline-chip"
        data-state={pending!.failed ? "failed" : "loading"}
        aria-busy={pending!.failed ? undefined : "true"}
        aria-label={name}
        /* tooltip-allow: the failed tile is cut to its size; the tooltip has the reason */ title={pending!.failed}
      >
        {pending!.failed ? (
          <>
            {pending!.image ? (
              <ImageIcon size={14} className="acpmux-attachment-failed-icon" />
            ) : (
              <FileDoc size={14} className="acpmux-attachment-failed-icon" />
            )}
            <RetryButton
              className="acpmux-attachment-retry acpmux-md-inline-retry"
              reason={pending!.failed}
              onRetry={() => onRetry(id)}
            />
          </>
        ) : pending!.progress === undefined ? (
          <Spinner loading size={14} className="acpmux-md-inline-spinner" />
        ) : (
          <UploadProgress value={pending!.progress} name={name} size={14} />
        )}
        {remove}
      </span>
    );
  // A huge paste: its name; a click puts its text back in the prompt at its place.
  if (attachment.kind === "pasted")
    return (
      <span
        className="acpmux-md-inline-chip"
        data-state="ready"
        data-kind="file"
        /* tooltip-allow: a long name is cut to the chip */ title={attachment.name}
      >
        <button type="button" className="acpmux-md-inline-retry" onClick={() => onExpand(id)}>
          {attachment.name}
        </button>
        {remove}
      </span>
    );
  // An image, a PDF, a video or a file: the strip's chip, so it previews, opens, plays and falls back
  // (an image that cannot be drawn) as it does there.
  return (
    <span className="acpmux-md-inline-chip" data-state="ready" data-chip="strip">
      <AttachmentChip
        attachment={attachment}
        codex={codex}
        onRemove={onRemove}
        {...(originalFailed ? { onRetry, originalFailed } : {})}
      />
    </span>
  );
});
