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
import { ContextMenu } from "../../../ui/ContextMenu";
import { FileDoc, ImageIcon, PlayTriangle } from "../conversation/icons";
import { usePaneLanguage, useT } from "../i18n";
import { pasteName } from "../conversation/promptCollapse";
import { imageLabel } from "../imageLabel";
import type { MarkdownFieldHandle } from "../MarkdownField";
import { AttachmentChip, InstantPreview, RetryButton, UploadProgress } from "./attachmentIntake";
import { imageShape, type PendingAttachment } from "./attachmentIntakeModel";
import { videoShapeStyle } from "./videoShape";
import { keptThumb } from "./imagePool";
import { PasteLoadingMark } from "./pasteLoading";
import { PASTE_LOADING_CLASS, usePasteLoadingLook } from "./pasteLoadingLook";
import { reordered } from "./stripReorder";
import { PastedTextChip } from "./PastedTextChip";
import { UIPickChip } from "./UIPickChip";
import { isUIPick } from "./uiPickModel";
import { pastedSize } from "./textAttachmentCardModel";
import { RemoveGlyph } from "./RemoveGlyph";
import { chipRef } from "../conversation/sendMorph";

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
  /// A pasted chip sent as a .txt file instead (composer/pastedChips.ts `keepAsFile`); unset, its chip
  /// offers only Expand.
  keepFile?(id: string): void;
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
  /// The placed placeholders a committed render has drawn as loading since they were placed. Only
  /// these can have ended: one placed in the task of its paste is in no render's `pending` yet, so
  /// a late effect of an earlier render (the last chip's arrival, run after the next paste) never
  /// takes it for one that became no chip and removes its node (composer-attach-no-jump: a second
  /// paste right after the first lost its place at the caret).
  const drawnLoading = useRef(new Set<string>());
  const markPlaced = (id: string) => {
    placed.current.add(id);
    drawnLoading.current.delete(id);
  };
  /// Placeholders whose node an edit took out while they loaded: an undo brings each back loading.
  const cancelled = useRef(new Set<string>());
  /// Attachments sent with a prompt: an undo of the send's clear brings their nodes back with no
  /// attachment to draw, so they leave the text again. One the host puts back (a refusal, Edit on a
  /// failed prompt) is the composer's again.
  const sentIds = useRef(new Set<string>());
  /// From a send until its clear is done (the same task): the clear takes the text's nodes out, and a
  /// file among them still uploading holds the send (useSendWhenAttached) and is never cancelled by
  /// it. Only the person's own edit cancels one (review of #26667).
  const clearing = useRef(false);
  /// Placeholders a paste or drop brought while the text could not take them yet (shell mode, the
  /// editor not made): each goes into the text the moment it can, still loading, so what its read
  /// makes takes that place (`ready`).
  const deferred = useRef(new Set<string>());
  /// The placeholders the last commit drew, by id: one that is an attachment now finished loading.
  const loading = useRef<ReadonlySet<string>>(new Set());
  useLayoutEffect(() => {
    removed.current.clear();
    placed.current.clear();
    cancelled.current.clear();
    sentIds.current.clear();
    deferred.current.clear();
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
    const { field } = live.current;
    // This render's own lists: the effect may run after a later paste placed a new placeholder.
    const { pending, attachments } = options;
    for (const id of placed.current) {
      if (pending.some((chip) => chip.id === id)) {
        drawnLoading.current.add(id);
        continue;
      }
      const chip = attachments.some((attachment) => attachment.id === id);
      if (!chip && !drawnLoading.current.has(id)) continue;
      placed.current.delete(id);
      drawnLoading.current.delete(id);
      if (!chip) field.current?.removeInline(id);
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
    /// The person's paste or drop made `chips`: each goes in at the caret, images, videos, files,
    /// screenshots and pasted text alike, so the prompt reads text, image, text, file as written
    /// (attachmentIntake.tsx `place`). One placement rule for every kind: nothing here reads what a
    /// chip is (test/composer-attachment-placement-one-rule.test.tsx guards it). Where the caret
    /// cannot take them (a code block), or `start` (a chip with no caret of its own: a Pasted text
    /// chip kept as a file where it had no node), they go at the start of the prompt instead, never
    /// into the strip above the text.
    place(chips: readonly PendingAttachment[], kind: DroppedKind | undefined, start = false) {
      const { placing, field } = live.current;
      const ids = chips.map((chip) => chip.id);
      if (!ids.length) return;
      if (!placing() || !field.current?.inlineIds()) {
        for (const id of ids) deferred.current.add(id);
        return;
      }
      for (const id of ids) markPlaced(id);
      // A paste takes the selection's place, as pasted text would; a drop or a pick replaces nothing.
      const went =
        (!start && field.current?.insertInline(ids, kind === "paste")) ||
        field.current?.insertInline(ids, false, "start");
      if (!went) for (const id of ids) placed.current.delete(id);
    },
    ready() {
      const { attachments, pending, field, placing } = live.current;
      if (!placing()) return;
      const marks = new Set(placedIn(field.current?.value() ?? seen.current));
      const fresh = attachments.filter((chip) => !marks.has(chip.id) && !removed.current.has(chip.id));
      // A read that ended while its placeholder had no node (a value from outside took it away, as a
      // chat's draft read or a carried prompt does while a slow read such as a video's runs) goes at
      // the start of the prompt: never put in at the caret then, between the words typed while it
      // loaded (Leo, 2026-11-09: "when it actually loads, it gets smashed in between text that you
      // were typing"), and never left in the strip above the text, where it stayed for good before
      // (Leo, 2026-11-09: "This one went above the whole thing. It's in, like, the special attachment
      // zone. But we didn't say to do that.").
      const orphans = fresh
        .filter((chip) => loading.current.has(chip.id) && !deferred.current.has(chip.id))
        .map((chip) => chip.id);
      const added = fresh.map((chip) => chip.id).filter((id) => !orphans.includes(id));
      // Placeholders that waited for the text to take them go in now, still loading.
      const waiting = field.current?.inlineIds()
        ? pending.filter((chip) => deferred.current.has(chip.id) && !marks.has(chip.id)).map((chip) => chip.id)
        : [];
      for (const id of deferred.current)
        if (waiting.includes(id) || !pending.some((chip) => chip.id === id)) deferred.current.delete(id);
      if (orphans.length) field.current?.insertInline(orphans, false, "start");
      const ids = [...added, ...waiting];
      if (!ids.length) return;
      for (const id of waiting) markPlaced(id);
      // At the caret, or where it cannot take them (a code block) at the start of the prompt.
      if (!field.current?.insertInline(ids) && !field.current?.insertInline(ids, false, "start"))
        for (const id of waiting) placed.current.delete(id);
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
        if (live.current.revive(id)) markPlaced(id);
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
    /// A pasted chip sent as a .txt file: kept first, as an open is, so an undo that brings its node
    /// back brings its text too.
    keepFile: (id: string) => {
      const attachment = live.current.attachmentsRef.current.find((each) => each.id === id);
      if (attachment) keep(attachment);
      live.current.keepFile?.(id);
    },
    known,
    /// The attachments in the text, read from `markdown` (the host's value): with the placeholders this
    /// composer put there whose node the editor holds, which the host's value may not show yet. A pasted
    /// or dropped chip is the text's from the moment it is made, so it is never drawn in the strip above
    /// for a frame (Leo, 2026-11-07: "it pasted above the original picture, which would, like, extend
    /// the composer"). One whose node a value from outside took away (a command's clear) is the strip's
    /// again.
    inText(markdown: string): ReadonlySet<string> {
      const ids = new Set(inlineTokenIds(markdown, known));
      if (placed.current.size) {
        const nodes = new Set(live.current.field.current?.inlineIds() ?? []);
        for (const id of placed.current) if (nodes.has(id)) ids.add(id);
      }
      return ids;
    },
    /// The field tells its nodes' elements in a microtask after the change that made them (MarkdownField
    /// `tellInlineViews`): their chips draw before that task's frame paints, so a paste's placeholder
    /// shows in the paste's own frame, as the strip's does (composer-paste-instant.test.tsx).
    onInlineViews: (next: ReadonlyMap<string, HTMLElement>) => flushSync(() => setViews(next)),
  }));

  useLayoutEffect(() => {
    for (const attachment of options.attachments) sentIds.current.delete(attachment.id);
    api.ready();
  }, [options.attachments, api]);
  // After `ready`, which reads the placeholders the commit before drew.
  useLayoutEffect(() => {
    loading.current = new Set(options.pending.map((chip) => chip.id));
  }, [options.pending]);
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
        {...(options.keepFile ? { onKeepFile: api.keepFile } : {})}
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
  onKeepFile,
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
  onKeepFile?(id: string): void;
  codex: boolean;
  originalFailed: string | undefined;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const look = usePasteLoadingLook();
  /// Whether this chip loaded in place (a paste, a drop): its picture then comes up from the loading
  /// tile's dim instead of popping in. A chip that arrives ready (a draft read back) just shows.
  const loaded = useRef(false);
  // Only a tile that showed (not one held unseen for its size or picture) has a dim to come up from.
  if (pending && !pending.failed && !pending.sizing) loaded.current = true;
  /// Whether its loading tile already showed its own picture: the chip then just stays, with no
  /// second coming up (Leo, 2026-11-11: "this 3 stage attachment thing is still there").
  const pictured = useRef(false);
  if (pending?.preview && pending.image && !pending.failed) pictured.current = true;

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
      <RemoveGlyph />
    </button>
  );
  if (!attachment)
    return (
      <span
        className={pending!.failed ? "acpmux-md-inline-chip" : `acpmux-md-inline-chip ${PASTE_LOADING_CLASS}`}
        data-state={pending!.failed ? "failed" : "loading"}
        {...(pending!.failed ? {} : { "data-paste-look": look })}
        // A loading image is the shape its thumbnail will be (its header's size), so the picture
        // arriving moves nothing.
        {...(!pending!.failed && pending!.image && pending!.size
          ? { "data-sized": "", style: imageShape(pending!.size) }
          : {})}
        // A video is the box its chip, poster and sent tile keep (videoShape.ts), loading or failed.
        {...(pending!.video ? { "data-video-shape": "", style: videoShapeStyle(pending!.videoShape) } : {})}
        {...(!pending!.failed && pending!.sizing ? { "data-sizing": "" } : {})}
        {...(!pending!.failed && pending!.image && pending!.preview ? { "data-instant": "" } : {})}
        aria-busy={pending!.failed ? undefined : "true"}
        aria-label={name}
        /* tooltip-allow: the failed tile is cut to its size; the tooltip has the reason */ title={pending!.failed}
      >
        {pending!.failed ? (
          <>
            {pending!.image ? (
              <ImageIcon size={14} className="acpmux-attachment-failed-icon" />
            ) : pending!.video ? (
              <PlayTriangle size={14} className="acpmux-attachment-failed-icon" />
            ) : (
              <FileDoc size={14} className="acpmux-attachment-failed-icon" />
            )}
            {pending!.retryable && (
              <RetryButton
                className="acpmux-attachment-retry acpmux-md-inline-retry"
                reason={pending!.failed}
                onRetry={() => onRetry(id)}
              />
            )}
          </>
        ) : (
          <>
            {pending!.preview && <InstantPreview src={pending!.preview} />}
            <PasteLoadingMark
              look={look}
              size={14}
              className="acpmux-md-inline-spinner"
              upload={
                pending!.progress === undefined ? undefined : (
                  <UploadProgress value={pending!.progress} name={name} size={14} />
                )
              }
            />
          </>
        )}
        {remove}
      </span>
    );
  // A huge paste: the compact chip that opens its whole text (PastedTextChip.tsx), Edit in Prompt
  // and Keep as .txt in the opened view.
  if (attachment.kind === "pasted") {
    const text = attachment.text ?? "";
    const label = `${t("composer.pastedText")} · ${pastedSize(t, language, text)}`;
    // Its right-click menu has what the strip's has (attachmentIntake.tsx `menu`): Edit in Prompt,
    // Keep as .txt and Remove.
    const items = [
      { id: "open", label: t("composer.pastedText.edit"), onSelect: () => onExpand(id) },
      ...(onKeepFile ? [{ id: "keep", label: t("composer.pastedText.keepFile"), onSelect: () => onKeepFile(id) }] : []),
      {
        id: "remove",
        label: t("composer.removeAttachment", { name }),
        separatorBefore: true,
        onSelect: () => onRemove(id),
      },
    ];
    return (
      <ContextMenu className="acpmux-attachment-menu" items={items}>
        <PastedTextChip
          host="inline"
          text={text}
          name={t("composer.pastedText")}
          accessibleName={`${attachment.name || pasteName(text)}, ${label}`}
          remove={remove}
          onEdit={() => onExpand(id)}
          {...(onKeepFile ? { onKeep: () => onKeepFile(id) } : {})}
        />
      </ContextMenu>
    );
  }
  // An inspector pick: the element and a snippet of its text, opening its whole report in place
  // (UIPickChip.tsx). Its right-click menu removes it, as the strip's does.
  if (attachment.kind === "text" && attachment.text !== undefined && isUIPick(attachment))
    return (
      <ContextMenu
        className="acpmux-attachment-menu"
        items={[{ id: "remove", label: t("composer.removeAttachment", { name }), onSelect: () => onRemove(id) }]}
      >
        <UIPickChip host="inline" name={attachment.name} text={attachment.text} remove={remove} />
      </ContextMenu>
    );
  // An image, a PDF, a video or a file: the strip's chip, so it previews, opens, plays and falls back
  // (an image that cannot be drawn) as it does there.
  return (
    <span
      className="acpmux-md-inline-chip"
      data-state="ready"
      data-chip="strip"
      ref={chipRef(id)}
      {...(loaded.current && !pictured.current ? { "data-loaded": "" } : {})}
    >
      <AttachmentChip
        attachment={attachment}
        codex={codex}
        onRemove={onRemove}
        {...(originalFailed ? { onRetry, originalFailed } : {})}
      />
    </span>
  );
});
