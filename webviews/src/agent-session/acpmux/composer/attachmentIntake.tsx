// The prompt's attachments, one implementation for every composer (Leo 2026-10-19: "i cant paste in
// pictures in the new tab area but it works in the existing chats"): a chat's composer (Composer.tsx)
// and the New Tab page's field (newtab/NewTabScreen.tsx) take a pasted or dropped image or file the
// same way, show it as the same chip, and send it with the prompt.
import React, { useCallback, useContext, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { ContextMenu } from "../../../ui/ContextMenu";
import { Dialog } from "../../../ui/Dialog";
import {
  filesFrom,
  inlineCopyParent,
  isImageFile,
  pastedImageFiles,
  installFileDropLifecycle,
  sourceOfFile,
  thumbnail,
  withSource,
  type AttachmentError,
  type AttachmentSource,
  type ComposerAttachment,
  type DroppedKind,
  type LinkItem,
  type SourceKind,
} from "../attachments";
import type { UploadCancelled, UploadProgressReport, UploadResult } from "../cloudUploads";
import { ImageViewerContext } from "../conversation/imageViewerContext";
import { Close, FileDoc, ImageIcon, Retry, Spinner } from "../conversation/icons";
import { type StringKey, type Translate, usePaneLanguage, useT } from "../i18n";
import { imageLabel } from "../imageLabel";
import { pasteLines, pasteName } from "../conversation/promptCollapse";
import { keptThumb, keepThumb } from "./imagePool";
import { useStripReorder } from "./stripReorder";
import { intakeFiles, type IntakeError } from "./intakeFiles";
import { pastesPlaced } from "./composerCopy";
import { attachSources } from "./attachmentSources";
import { type DropOverlayState, HIDDEN_DROP, landDropOverlay, stepDropOverlay } from "./dropOverlayState";
import { FADE_BAND_PX } from "../MarkdownField";
import { useScrollEdges } from "../summary/scrollEdges";
import { callChipHost } from "../chips/host";
import { isVideoAttachment, useVideoInfo, useVideoReading } from "./videoAttachments";
import { VideoAttachmentTile } from "./VideoAttachmentTile";
import { FileAttachment } from "../FileAttachment";
import { TextAttachmentCard } from "./TextAttachmentCard";

const ATTACHMENT_LABELS = {
  attachments: "composer.attachments",
  removeAttachment: "composer.removeAttachment",
  openAttachment: "composer.openAttachment",
  sentAsFileForCodex: "composer.sentAsFileForCodex",
  tooLarge: "composer.tooLarge",
  unsupported: "composer.unsupported",
  imagesUnsupported: "composer.imagesUnsupported",
  pastedText: "composer.pastedText",
  pastedLines: "transcript.pastedLines",
  editPasted: "composer.pastedText.edit",
  cancelAttachment: "composer.cancelAttachment",
  retryAttachment: "composer.retryAttachment",
  originalFailed: "composer.originalFailed",
  retryOriginal: "composer.retryOriginal",
  reorderHint: "composer.reorderAttachmentsHint",
  moved: "composer.attachmentMoved",
} as const satisfies Record<string, StringKey>;

export function attachmentErrorText(error: AttachmentError, t: Translate): string {
  return t(ATTACHMENT_LABELS[error.reason], { name: error.name });
}

function intakeErrorText(error: IntakeError, t: Translate): string {
  return "text" in error ? error.text : attachmentErrorText(error, t);
}

export type AttachmentIntakeOptions = {
  place?(chips: readonly PendingAttachment[]): void;
  /// The agent takes images (`promptCapabilities.image`); false refuses an image with a note.
  allowImages: boolean;
  /// Whether a paste on `target` is this composer's: undefined is not; `uploads` false keeps its
  /// files for the next prompt and uploads nothing (a chat's shell mode).
  pasteTarget(target: Node): { uploads: boolean } | undefined;
  /// The chat's host saves what the composer can't attach (cloudUploads.ts); its chip sends the path.
  upload?(files: File[], cancelled?: UploadCancelled, progress?: UploadProgressReport): Promise<UploadResult>;
  /// For a chat on this Mac: where the files of the person's drop or paste are (composer/intakeFiles.ts
  /// droppedPaths), so a folder or a file no block takes goes as a link to it, tried before `upload`.
  localPaths?(kind: DroppedKind, files: File[]): Promise<LinkItem[] | undefined>;
  /// The chat column a file drag lifts the drop overlay over (composer/dropOverlayState.ts): over
  /// it a drop attaches; elsewhere in the pane the overlay only arms. Unset: the whole page.
  dropZone?(): Element | null;
  /// True while the composer takes nothing (a Cloud start is out, App.tsx `cloudStarting`): a paste
  /// or a file drop stages no attachment then, since the tab closes with only the sent prompt.
  locked?(): boolean;
  /// The chat the composer shows. A file is the chat's it was pasted or dropped in: its placeholder
  /// shows only there, and a read that ends after the composer moved to another chat hands its
  /// chips to `elsewhere` instead of this chat's strip.
  scope?: string;
  /// Keeps chips whose read ended after the composer left `scope` for that chat (keptAttachments.ts).
  elsewhere?(scope: string, attachments: ComposerAttachment[]): void;
  /// A chat on this Mac, whose attached videos the host may read (composer/videoAttachments.ts);
  /// `localPaths` says so too. Quick Chat has no `localPaths` but is on this Mac.
  localChat?: boolean;
  /// When the composer moves to another chat: whether the files still being read move with it (a
  /// harness switch's new session carries the prompt). A chat that had no id yet always carries.
  carries?(): boolean;
  /// Overrides the fresh-chat default for a recovery that deliberately carries text only.
  suppressCarry?(from?: string, to?: string): boolean;
};

/** Append a batch while replacing the same attachment id and collapsing repeated local path links
 * (for example, highlighting the same element or dropping the same folder twice). */
export function appendAttachments(
  current: readonly ComposerAttachment[],
  added: readonly ComposerAttachment[],
): ComposerAttachment[] {
  const result = [...current];
  const ids = new Map<string, number>();
  const links = new Map<string, number>();
  result.forEach((attachment, index) => {
    ids.set(attachment.id, index);
    if (attachment.kind === "link" && attachment.path) links.set(attachment.path, index);
  });
  for (const attachment of added) {
    const previous =
      ids.get(attachment.id) ??
      (attachment.kind === "link" && attachment.path ? links.get(attachment.path) : undefined);
    if (previous !== undefined) {
      result[previous] = attachment;
      ids.set(attachment.id, previous);
      if (attachment.kind === "link" && attachment.path) links.set(attachment.path, previous);
      continue;
    }
    ids.set(attachment.id, result.length);
    if (attachment.kind === "link" && attachment.path) links.set(attachment.path, result.length);
    result.push(attachment);
  }
  return result;
}

/// A chip shown the moment a file is pasted, dropped or chosen, while the composer reads, scales or
/// saves it (intakeFiles.ts can take a large screenshot hundreds of ms): the chip it becomes, or
/// the refusal's note, takes its place. Leo 2026-10-21: "ME PASTING IT DOESN'T JUST PASTE RIGHT
/// INTO THE COMPOSER IMMEDIATELY". It spins while it loads and its × cancels it; one that could not
/// be attached stays, saying why (`failed`), with Retry (Leo, 2026-10-24: "why don't you put a
/// spinner on the attachment rather than this placeholder that doesn't do anything... I can't even
/// cancel these").
export type PendingAttachment = {
  id: string;
  name: string;
  image: boolean;
  scope?: string;
  failed?: string;
  /// Streaming to the session's machine (a file of any size): a send goes without waiting for it,
  /// and it stays for the next prompt (Leo, 2026-10-25: "...prevent new things from happening").
  uploading?: boolean;
  /// How much of it reached the session's machine, 0 to 1, while it streams: its tile shows it.
  progress?: number;
  /// Made by the host for its chat (attachLater, a file on that chat's machine): it stays with that
  /// chat, never carried to another with the prompt. A send waits for it even once it failed, until
  /// its Retry makes it or its × takes it out, so a prompt never goes without the recording it was
  /// sent with.
  bound?: boolean;
};

/// What Retry needs of a pending chip: its file and how it came in.
/// Whether chip `chip` (an image whose original may still upload) was taken out of its chat's
/// strip, by its x or a send, so its original goes nowhere. Not when it went to another chat
/// (`stagedHere` false), the strip has not drawn it yet (`everDrawn` false), or the strip is
/// another chat's (`showing` is not the chat it was pasted in): there it is only out of view.
export function chipRemoved(state: {
  chip: string;
  stagedHere: boolean;
  everDrawn: boolean;
  pastedIn: string | undefined;
  showing: string | undefined;
  strip: readonly ComposerAttachment[];
}): boolean {
  if (!state.stagedHere || !state.everDrawn || state.pastedIn !== state.showing) return false;
  return !state.strip.some((attachment) => attachment.id === state.chip);
}

/// Reads `given` into chips (useAttachmentIntake's `attach`); `again`, a failed chip's Retry.
type Intake = (given: (File | MadeFile)[], uploads?: boolean, kind?: SourceKind, again?: string) => Promise<void>;

/// How many cancelled loading chips keep their file for an undo (`revive`).
const PARKED_MAX = 16;

/// `file`: a promise while its bytes are still being made (MadeFile). `make`: a chip the host makes
/// (attachLater), with the note its failure shows.
type PendingSource =
  | FileSource
  | { make: () => Promise<ComposerAttachment | undefined>; name: string; failure: string; stop?: () => void };

/// A file chip's source. `name` and `type` too, for a file whose bytes are still being made (a
/// promise): an undo can read it again as the MadeFile it came as (`revive`).
type FileSource = { file: File | Promise<File>; uploads: boolean; name: string; type: string };

/// A file whose bytes are still being made (pastedText.ts pastedTextFile): its tile shows at once,
/// by its name and type, and it is read once `file` settles.
export type MadeFile = { name: string; type: string; file: Promise<File> };

/// Whether `file` is a MadeFile, by its shape: a File from another window (a test's DOM, a drop
/// from a frame) is not `instanceof` this one's File.
function isMadeFile(file: File | MadeFile): file is MadeFile {
  return "file" in file && typeof (file as MadeFile).file?.then === "function";
}

/// The prompt's staged attachments: what a paste on the composer's field or a file drop anywhere on
/// the page adds (the document-level drop contract, attachments.ts), with the note a refusal leaves.
/// `attach(files, uploads, kind)` adds files another way (the + menu's chooser, which uploads like a
/// drop, or a capture). `pending`: the files still being read, shown at once (PendingAttachment).
export function useAttachmentIntake(options: AttachmentIntakeOptions) {
  const t = useT();
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const [pending, setPending] = useState<PendingAttachment[]>([]);
  const [attachError, setAttachError] = useState<string | undefined>();
  const [dropping, setDropping] = useState(false);
  /// The drop overlay's state (composer/DropOverlay.tsx). Kept in a ref too: a refused drag's
  /// `dropEffect` is set inside the drag event, before any render.
  const [drop, setDropState] = useState<DropOverlayState>(HIDDEN_DROP);
  const dropRef = useRef<DropOverlayState>(HIDDEN_DROP);
  const [showDrop] = useState(() => (next: DropOverlayState) => {
    if (next === dropRef.current) return;
    dropRef.current = next;
    setDropState(next);
  });
  const live = useRef({ options, t });
  live.current = { options, t };
  /// Each batch still being read, with the chat it belongs to (`scope`). A `bound` one (attachLater:
  /// a file on that chat's machine) stays with its chat when a switch carries the prompt.
  const batches = useRef(new Set<{ scope?: string; bound?: boolean }>());
  /// Each pending chip's file, for Retry; a chip cancelled by its × is gone from here, so what its
  /// read makes later is dropped.
  const sources = useRef(new Map<string, PendingSource>());
  const cancellationListeners = useRef(new Set<() => void>());
  /// Files of chips cancelled while still loading (their node deleted from the prompt), by id: an
  /// undo that brings the node back reads its file again under the same id (`revive`).
  const parked = useRef(new Map<string, PendingSource>());
  /// Each staged image whose original's upload failed: its file, for Retry, while its chip is in the
  /// strip (a chip that leaves it, by its x, a send or a chat switch, takes its file with it), and
  /// why it failed (`originalFailures`, what its chip shows). This page's own state, never the
  /// chip's: a draft, a wake or another chat gets the preview back without a Retry it has no file for.
  const originals = useRef(new Map<string, File>());
  const [originalFailures, setOriginalFailures] = useState<Readonly<Record<string, string>>>({});
  /// The staged images whose original is still streaming to the chat's machine, by chip id: a send
  /// too large for one acpmux message waits for them, so their previews go as links to the
  /// originals instead (promptBudget.ts `awaitsOriginals`).
  const [originalUploads, setOriginalUploads] = useState<ReadonlySet<string>>(() => new Set());
  const [originalUpload] = useState(
    () => (id: string, on: boolean) =>
      setOriginalUploads((now) => {
        if (now.has(id) === on) return now;
        const next = new Set(now);
        if (on) next.add(id);
        else next.delete(id);
        return next;
      }),
  );
  /// The host-made chips (attachLater) whose `make` has not answered yet, each with what stops it
  /// on the host, if anything does.
  const making = useRef(new Map<string, (() => void) | undefined>());
  /// The staged chips now, for an upload to see that its chip was removed (its x, or a send).
  const stagedNow = useRef<readonly ComposerAttachment[]>([]);
  stagedNow.current = attachments;
  /// The chips a render has staged: one not yet rendered is not gone, only not drawn yet.
  const everStaged = useRef(new Set<string>());
  for (const attachment of attachments) everStaged.current.add(attachment.id);
  /// Each intake chip's place in paste order (its gesture, then its file), so a chip ready first
  /// still lands where it was pasted, across batches too.
  const places = useRef(new Map<string, number>());
  const gestures = useRef(0);
  const scope = options.scope;
  useLayoutEffect(() => {
    for (const changed of cancellationListeners.current) changed();
  }, [attachments, scope]);
  const lastScope = useRef(scope);
  // Before paint: a carried placeholder never leaves the strip for a frame.
  useLayoutEffect(() => {
    const from = lastScope.current;
    lastScope.current = scope;
    if (
      from === scope ||
      live.current.options.suppressCarry?.(from, scope) ||
      (from !== undefined && !live.current.options.carries?.())
    )
      return;
    for (const batch of batches.current) if (batch.scope === from && !batch.bound) batch.scope = scope;
    setPending((chips) => chips.map((chip) => (chip.scope === from && !chip.bound ? { ...chip, scope } : chip)));
  }, [scope]);
  /// `uploads`: the person dropped, pasted or chose these, so the chat's host may save what the
  /// composer can't attach (a moved chat's machine, or this Mac for a local chat) and its chip sends
  /// the saved path (composer/intakeFiles.ts); never a capture. `kind`: the person's own drop or
  /// paste, whose files the host of a chat on this Mac knows the paths of (`localPaths`), or pick in
  /// the file input (`choose`), which the host asks only where its files came from. `again`: the
  /// failed chip whose file `given` is, read again under its id (Retry): it keeps its place in the
  /// strip and in the text, and its node there draws what the read makes.
  const [intake] = useState<Intake>(() => async (given, uploads = false, kind, again) => {
    if (given.length === 0) return;
    // When the page took the gesture: the host answers its source only from a record made before
    // it (composer/attachmentSources.ts).
    const gestureAt = Date.now();
    const files = again === undefined ? given : given.slice(0, 1);
    // A pick in the file input too: a chat on this Mac links the picked files where they are, as it
    // does a Finder drop, instead of streaming a copy of each (an older host answers nothing).
    const dropped: DroppedKind | undefined = kind;
    const { options: current } = live.current;
    const batch = { scope: current.scope };
    // In the paste's or drop's own task, so React draws them before the next frame.
    const shown: PendingAttachment[] = files.map((file) => ({
      id: again ?? crypto.randomUUID(),
      name: file.name,
      image: isImageFile(file),
      scope: batch.scope,
    }));
    // This read's own source for each chip: a chip cancelled and brought back (undo, `revive`) or
    // read again (Retry) under the same id has a new one, and only the read that owns the id's
    // source now settles it, so an older read still running never takes or drops the newer one's.
    const owned = shown.map((chip, index): FileSource => {
      const file = files[index]!;
      const source = { file: isMadeFile(file) ? file.file : file, uploads, name: file.name, type: file.type };
      sources.current.set(chip.id, source);
      return source;
    });
    const owns = (index: number) => sources.current.get(shown[index]!.id) === owned[index];
    const gesture = (gestures.current += 1);
    // Paste order: a chip read again keeps the place its paste gave it.
    shown.forEach((chip, index) => {
      if (!places.current.has(chip.id)) places.current.set(chip.id, gesture * 100_000 + index);
    });
    batches.current.add(batch);
    // A chip read again is the same chip loading again, in one render: never gone for a frame, so
    // the text's node of it stays (inlineAttachments.tsx).
    if (again !== undefined)
      setPending((chips) =>
        chips.some((chip) => chip.id === again)
          ? chips.map((chip) => (chip.id === again ? shown[0]! : chip))
          : [...chips, shown[0]!],
      );
    else {
      setPending((chips) => [...chips, ...shown]);
      current.place?.(shown);
    }
    const paths = current.localPaths;
    /// The chip each file became, by index, for its original's path arriving later.
    const made: (string | undefined)[] = [];
    // The app each file came from: one the page made knows it (a capture cmux took); the host says
    // the rest for the person's drop, paste or pick in the file input (composer/attachmentSources.ts,
    // which answers within its deadline). A chip never waits for that answer: it goes in the moment
    // it is ready, with the source known by then, and a later answer is added to it where it is
    // staged in this chat's strip. A source is a label only, so a ready file never holds a send for
    // it. One whose source nobody knows has none.
    const fileSource: (AttachmentSource | undefined)[] = files.map((file) =>
      isMadeFile(file) ? undefined : sourceOfFile(file),
    );
    const asked = kind
      ? files.flatMap((file, index) => (isMadeFile(file) || fileSource[index] ? [] : [{ file, index }]))
      : [];
    if (asked.length > 0)
      void attachSources(
        kind!,
        asked.map(({ file }) => file),
        undefined,
        gestureAt,
      ).then((sources) => {
        const late = new Map<string, AttachmentSource>();
        sources.forEach((source, at) => {
          if (!source) return;
          const { file, index } = asked[at]!;
          fileSource[index] = source;
          // A failed chip's Retry reads this same file again: it keeps the answer.
          withSource(file, source);
          // A chip already staged here before the answer gets it now.
          const id = made[index];
          if (id && staged.has(id)) late.set(id, source);
        });
        if (late.size > 0)
          setAttachments((chips) =>
            chips.map((chip) => {
              const source = late.get(chip.id);
              return source && !chip.source ? { ...chip, source } : chip;
            }),
          );
      });
    const sourced = (index: number, attachment: ComposerAttachment): ComposerAttachment => {
      const source = fileSource[index];
      return source && !attachment.source ? { ...attachment, source } : attachment;
    };
    /// The chips this batch put in this chat's strip (not handed to another chat).
    const staged = new Set<string>();
    const marked = new Set<number>();
    // Each file's placeholder goes in the same render as what it became, the moment it is ready.
    const settle = (index: number) => {
      const id = shown[index]!.id;
      if (!owns(index)) return false;
      sources.current.delete(id);
      setPending((chips) => chips.filter((chip) => chip.id !== id));
      return true;
    };
    const ready = (index: number, read: ComposerAttachment): void => {
      if (!settle(index)) return;
      const thumb = keptThumb(read.id);
      if (thumb) keepThumb(shown[index]!.id, thumb);
      const attachment = sourced(index, { ...read, id: shown[index]!.id });
      made[index] = attachment.id;
      // The composer moved to another chat meanwhile: the chip is the chat's it was pasted in.
      const now = live.current.options;
      if (batch.scope !== now.scope) {
        if (batch.scope !== undefined) now.elsewhere?.(batch.scope, [attachment]);
        return;
      }
      // In paste order, whichever file was ready first: before the first staged chip pasted after it.
      const place = places.current.get(attachment.id)!;
      staged.add(attachment.id);
      setAttachments((staged) => {
        const at = staged.findIndex((chip) => (places.current.get(chip.id) ?? -1) > place);
        if (at < 0 || staged.some((chip) => chip.id === attachment.id)) return appendAttachments(staged, [attachment]);
        return [...staged.slice(0, at), attachment, ...staged.slice(at)];
      });
    };
    const failed = (index: number, error: IntakeError) => {
      const id = shown[index]!.id;
      if (!owns(index)) return;
      marked.add(index);
      const failed = intakeErrorText(error, live.current.t);
      setPending((chips) =>
        chips.map((chip) => (chip.id === id ? { ...chip, failed, uploading: false, progress: undefined } : chip)),
      );
    };
    try {
      // A file still being made (a huge paste's text, made a slice per task) is awaited here, after
      // its tile drew.
      const settled = await Promise.all(files.map((file) => (isMadeFile(file) ? file.file : file)));
      // The bytes are made: Retry reads these, never the promise again.
      settled.forEach((file, index) => {
        owned[index]!.file = file;
      });
      await intakeFiles(
        settled,
        {
          allowImages: current.allowImages,
          ...(dropped && paths ? { localPaths: (batch: File[]) => paths(dropped, batch) } : {}),
          ...(uploads && current.upload ? { upload: current.upload } : {}),
          // A file not yet a chip: its tile's x. One already a chip (an image whose original still
          // uploads): the chip is gone from the strip (its x, or it was sent), so its original
          // would go nowhere.
          cancelled: Object.assign(
            (index: number) => {
              const chip = made[index];
              if (!chip) return !owns(index);
              return chipRemoved({
                chip,
                stagedHere: staged.has(chip),
                everDrawn: everStaged.current.has(chip),
                pastedIn: batch.scope,
                showing: live.current.options.scope,
                strip: stagedNow.current,
              });
            },
            {
              subscribe: (_index: number, changed: () => void) => {
                cancellationListeners.current.add(changed);
                return () => {
                  cancellationListeners.current.delete(changed);
                };
              },
            },
          ),
        },
        {
          ready,
          failed,
          uploading: (index) => {
            const image = made[index];
            if (image) originalUpload(image, true);
            if (!owns(index)) return;
            const id = shown[index]!.id;
            setPending((chips) => chips.map((chip) => (chip.id === id ? { ...chip, uploading: true } : chip)));
          },
          // Whole percents only: a multi-GB file sends thousands of chunks.
          progress: (index, done) => {
            if (!owns(index)) return;
            const id = shown[index]!.id;
            const progress = Math.floor(Math.min(1, Math.max(0, done)) * 100) / 100;
            setPending((chips) =>
              chips.some((chip) => chip.id === id && chip.progress !== progress)
                ? chips.map((chip) => (chip.id === id ? { ...chip, progress } : chip))
                : chips,
            );
          },
          original: (index, path, name) => {
            const id = made[index];
            if (id) originalUpload(id, false);
            setAttachments((staged) =>
              staged.map((chip) => (chip.id === id ? { ...chip, originalPath: path, originalName: name } : chip)),
            );
          },
          // The preview still sends; the chip says its original was not saved and offers Retry.
          originalFailed: (index, error) => {
            const id = made[index];
            if (id) originalUpload(id, false);
            // Only in the chat shown: a chip in another chat's kept draft comes back unmarked.
            if (!id || !staged.has(id) || batch.scope !== live.current.options.scope) return;
            originals.current.set(id, settled[index]!);
            const failed = intakeErrorText(error, live.current.t);
            setOriginalFailures((now) => ({ ...now, [id]: failed }));
          },
        },
      );
    } finally {
      batches.current.delete(batch);
      for (const id of made) if (id) originalUpload(id, false);
      // A file intake said nothing of (it threw) is not left loading.
      shown.forEach((chip, index) => {
        if (owns(index) && !marked.has(index)) failed(index, { name: chip.name, reason: "unsupported" });
      });
    }
  });
  const [attach] = useState(
    () =>
      (given: (File | MadeFile)[], uploads = false, kind?: SourceKind) =>
        intake(given, uploads, kind),
  );
  /// A chip the host makes from something of its own (a long dictation recording it sends to the
  /// chat's machine): its tile shows at once, drawn before this returns so a send made in the same
  /// task (dictation's auto-send) waits for it, as for a file still being read. `make` answers the
  /// chip, or undefined (or throws) and the tile fails with `failure` and Retry, which runs `make`
  /// again. A send keeps waiting through a failure (`bound`): it goes with the chip once Retry makes
  /// it, or without it once its × drops it. Its × runs `stop` (the host stops sending) and drops
  /// whatever `make` answers later, as does the composer going away while `make` still runs.
  const [attachLater] = useState(
    () => (name: string, make: () => Promise<ComposerAttachment | undefined>, failure: string, stop?: () => void) => {
      const batch = { scope: live.current.options.scope, bound: true };
      const chip: PendingAttachment = { id: crypto.randomUUID(), name, image: false, scope: batch.scope, bound: true };
      sources.current.set(chip.id, { make, name, failure, stop });
      making.current.set(chip.id, stop);
      batches.current.add(batch);
      flushSync(() => setPending((chips) => [...chips, chip]));
      void make()
        .catch(() => undefined)
        .then((attachment) => {
          making.current.delete(chip.id);
          batches.current.delete(batch);
          if (!sources.current.has(chip.id)) return;
          if (!attachment) {
            setPending((chips) => chips.map((shown) => (shown.id === chip.id ? { ...shown, failed: failure } : shown)));
            return;
          }
          sources.current.delete(chip.id);
          setPending((chips) => chips.filter((shown) => shown.id !== chip.id));
          // The composer moved to another chat meanwhile: the chip is the chat's it was made for.
          const now = live.current.options;
          if (batch.scope !== now.scope) {
            if (batch.scope !== undefined) now.elsewhere?.(batch.scope, [attachment]);
            return;
          }
          setAttachments((staged) => appendAttachments(staged, [attachment]));
        });
    },
  );
  // The composer goes away: a host-made chip still being made has nowhere to land, so it stops,
  // and whatever its `make` answers later is dropped (its source goes too).
  useEffect(
    () => () => {
      for (const [id, stop] of making.current) {
        sources.current.delete(id);
        stop?.();
      }
      making.current.clear();
    },
    [],
  );
  /// A pending chip's ×: it goes, and whatever its read makes later is dropped; a chip the host
  /// is making (attachLater) is stopped there too. A file's source is kept a while for an undo
  /// that brings its node back (`revive`).
  const [cancel] = useState(() => (id: string) => {
    const source = sources.current.get(id);
    if (source && "make" in source) source.stop?.();
    else if (source) {
      parked.current.delete(id);
      parked.current.set(id, source);
      // Only the latest few: an undo reaches back a short way.
      for (const old of parked.current.keys()) {
        if (parked.current.size <= PARKED_MAX) break;
        parked.current.delete(old);
      }
    }
    making.current.delete(id);
    sources.current.delete(id);
    for (const changed of cancellationListeners.current) changed();
    setPending((chips) => chips.filter((chip) => chip.id !== id));
  });
  /// A cancelled loading chip's node came back (undo): its file is read again under its id, so the
  /// node draws it loading and then what the read makes. A file whose bytes were still being made
  /// goes as the MadeFile it came as, read once they are. False when its file is not kept.
  const [revive] = useState(() => (id: string): boolean => {
    const source = parked.current.get(id);
    if (!source || "make" in source) return false;
    parked.current.delete(id);
    const { file, name, type } = source;
    void intake(["then" in file ? { name, type, file } : file], source.uploads, undefined, id);
    return true;
  });
  /// A staged image's Retry for its original: the original uploads again, its preview staying staged.
  const [retryOriginal] = useState(() => async (id: string) => {
    const file = originals.current.get(id);
    const upload = live.current.options.upload;
    if (!file || !upload) return;
    originals.current.delete(id);
    const failure = (failed?: string) =>
      setOriginalFailures((now) => {
        const { [id]: _, ...rest } = now;
        return failed === undefined ? rest : { ...rest, [id]: failed };
      });
    failure();
    // Out of the strip meanwhile (sent, removed, or the composer moved to another chat): the upload
    // stops, silently.
    const gone = () => !stagedNow.current.some((chip) => chip.id === id);
    originalUpload(id, true);
    const sent = await upload([file], gone)
      .catch((failure: unknown): UploadResult => ({
        error: failure instanceof Error ? failure.message : String(failure),
      }))
      .finally(() => originalUpload(id, false));
    const path = sent && "paths" in sent ? sent.paths[0] : undefined;
    if (gone()) return;
    if (path)
      return setAttachments((chips) =>
        chips.map((chip) => (chip.id === id ? { ...chip, originalPath: path, originalName: file.name } : chip)),
      );
    originals.current.set(id, file);
    const error: IntakeError =
      sent && "error" in sent ? { text: sent.error } : { name: file.name, reason: "unsupported" };
    failure(intakeErrorText(error, live.current.t));
  });
  /// An image no longer in the strip has no Retry to show: its original's file and failure go.
  useEffect(() => {
    const left = [...originals.current.keys()].filter((id) => !attachments.some((chip) => chip.id === id));
    for (const id of left) originals.current.delete(id);
    if (left.length)
      setOriginalFailures((now) => Object.fromEntries(Object.entries(now).filter(([id]) => !left.includes(id))));
  }, [attachments]);
  /// A failed chip's Retry: its file is read again (and uploaded again when it was) as the same chip,
  /// where it was: a retry read as a new paste went in at the caret, or nowhere (review of #26545). A
  /// staged image's: its original is uploaded again.
  const [retry] = useState(() => (id: string) => {
    if (originals.current.has(id)) return void retryOriginal(id);
    const source = sources.current.get(id);
    if (source && "make" in source) {
      sources.current.delete(id);
      setPending((chips) => chips.filter((chip) => chip.id !== id));
      attachLater(source.name, source.make, source.failure, source.stop);
      return;
    }
    const file = source?.file;
    // A file whose bytes were never made (making them failed) has nothing to retry.
    if (!source || !file || "then" in file) return;
    // Without the paste's kind: the host's record of where its files are was for that gesture only.
    void intake([file], source.uploads, undefined, id);
  });
  useEffect(() => {
    const paste = (event: ClipboardEvent) => {
      if (live.current.options.locked?.() || pastesPlaced.has(event)) return;
      const owned = live.current.options.pasteTarget(event.target as Node);
      if (!owned) return;
      const pasted = filesFrom(event.clipboardData);
      // An image copied as HTML only (from a page or the transcript) or as `![…](data:…)` text (a
      // prompt copied from a bubble) comes in as a chip too; its text still goes into the field (a
      // textarea's own paste, the prompt's handler), without the images.
      const other = pasted.length ? undefined : pastedImageFiles(event.clipboardData);
      const files = other ? other.files : pasted;
      if (!other) event.preventDefault();
      if (files.length) void attach(files, owned.uploads, "paste");
      if (other?.text !== undefined) pasteTextInto(event, other.text);
    };
    const removeFileDropLifecycle = installFileDropLifecycle(
      (files) => {
        if (live.current.options.locked?.()) return showDrop(HIDDEN_DROP);
        showDrop(landDropOverlay(dropRef.current, files));
        void attach(files, true, "drop");
      },
      (active, event) => {
        const { allowImages, dropZone, locked } = live.current.options;
        const refused = locked?.() === true;
        setDropping(active && !refused);
        if (refused) return showDrop(HIDDEN_DROP);
        showDrop(stepDropOverlay(dropRef.current, active, event, allowImages, dropZone?.()));
      },
    );
    document.addEventListener("paste", paste);
    return () => {
      removeFileDropLifecycle();
      document.removeEventListener("paste", paste);
    };
  }, [attach, showDrop]);
  const shown = pending.filter((chip) => chip.scope === scope);
  /// The chips still loading that a send waits for: a failed one waits for its Retry or x, and one
  /// streaming to the session's machine stays for the next prompt, neither holds the send. A chip
  /// the host makes (`bound`) holds it even once failed, until its Retry or x.
  const loading = shown.filter((chip) => chip.bound || (!chip.failed && !chip.uploading)).length;
  /// The chips not yet a chip or a failure, uploads included (useSendWhenAttached's `unsettled`); a
  /// failed host-made chip still counts.
  const unsettled = shown.filter((chip) => chip.bound || !chip.failed).length;
  /// The video chips whose poster and frames the host still reads, for a chat on this Mac: a send
  /// waits for them a few seconds at most (composer/videoAttachments.ts).
  const videoReading = useVideoInfo(
    attachments,
    setAttachments,
    Boolean(options.localPaths) || options.localChat === true,
  );
  /// The landing animation ended: the overlay hides.
  const [dropLanded] = useState(() => () => showDrop(HIDDEN_DROP));
  return {
    attachments,
    setAttachments,
    pending: shown,
    originalFailures,
    originalUploads,
    loading,
    unsettled,
    videoReading,
    cancel,
    retry,
    revive,
    attachError,
    setAttachError,
    dropping,
    drop,
    dropLanded,
    attach,
    attachLater,
  };
}

/// A prompt sent while its files are still being read (`pending`) is held and goes, once, when the
/// last of them is a chip, so it never leaves without them. `hold(send)` holds it when there are
/// pending files (true; a later hold replaces it) and does nothing otherwise (false). `send` runs
/// after the render that has the chips, so it must read the composer's state then (a ref). A new
/// `scope` (the composer moved to another chat) drops a held prompt: it never goes to another chat.
///
/// `unsettled` (default `pending`) also counts the files streaming to the session's machine: a send
/// made while files were still being read waits for those too, so the files it was sent with go
/// with it (or their x lets it go without them); a send made once only uploads are left goes at
/// once, and they stay for the next prompt. While one waits, a later send replaces it.
export function useSendWhenAttached(
  pending: number,
  scope?: string,
  unsettled: number = pending,
): ((send: () => void) => boolean) & { cancel(): void } {
  const held = useRef<(() => void) | undefined>(undefined);
  const count = useRef(pending);
  count.current = pending;
  useEffect(() => {
    held.current = undefined;
  }, [scope]);
  useEffect(() => {
    const send = held.current;
    if (unsettled > 0 || !send) return;
    held.current = undefined;
    send();
  }, [unsettled]);
  const [hold] = useState(() =>
    Object.assign(
      (send: () => void) => {
        if (count.current === 0 && !held.current) return false;
        held.current = send;
        return true;
      },
      {
        cancel: () => {
          held.current = undefined;
        },
      },
    ),
  );
  return hold;
}

/// A send too large for one acpmux message waits for the originals of its images still uploading
/// (`uploading` of them), then goes once, with them as links (promptBudget.ts `awaitsOriginals`).
/// `hold(awaits, send)`: when `awaits`, holds `send` (true; a later hold replaces it); otherwise the
/// send goes now (false) and any held one is dropped, so it never goes later on its own with
/// whatever draft the composer has then. A new `scope` drops it too.
export function useSendWhenOriginals(
  uploading: number,
  scope?: string,
): (awaits: boolean, send: () => void) => boolean {
  const wait = useSendWhenAttached(uploading, scope);
  const [hold] = useState(() => (awaits: boolean, send: () => void) => {
    if (awaits && wait(send)) return true;
    wait.cancel();
    return false;
  });
  return hold;
}

/// Puts `text` in place of a paste's own text in a plain text field (the New Tab prompt), so the
/// images lifted out of it never land there as base64; the prompt field takes its paste itself.
function pasteTextInto(event: ClipboardEvent, text: string) {
  const target = event.target as Node | null;
  const view = target?.ownerDocument?.defaultView;
  if (!view || !(target instanceof view.HTMLTextAreaElement || target instanceof view.HTMLInputElement)) return;
  event.preventDefault();
  if (!text || target.ownerDocument.execCommand?.("insertText", false, text)) return;
  const end = target.value.length;
  target.setRangeText(text, target.selectionStart ?? end, target.selectionEnd ?? end, "end");
  target.dispatchEvent(new view.Event("input", { bubbles: true }));
}

/// Backspace with the caret at the prompt's start (`atStart`: nothing for the key to delete or
/// lift there) takes back the last staged chip, as a chat composer's Backspace does, so a pasted
/// image goes without reaching for its ×. A held key's repeat does not: holding Backspace to
/// clear the prompt stops at its start.
export function backspacedAttachment(
  event: {
    key: string;
    repeat: boolean;
    shiftKey: boolean;
    altKey: boolean;
    metaKey: boolean;
    ctrlKey: boolean;
  },
  atStart: boolean,
  attachments: readonly ComposerAttachment[],
): ComposerAttachment | undefined {
  if (event.key !== "Backspace" || event.repeat || !atStart) return undefined;
  if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return undefined;
  return attachments[attachments.length - 1];
}

/// The staged attachments' chips over the prompt, with a refusal's note.
export function AttachmentStrip({
  attachments,
  pending = [],
  error,
  codex = false,
  onRemove,
  onExpand,
  onCancel,
  onRetry,
  onReorder,
  originalFailures,
  selected = false,
}: {
  attachments: readonly ComposerAttachment[];
  /// The prompt's whole draft is selected (Select All): the chips are in it, and show so.
  selected?: boolean;
  /// Why a staged image's original failed to upload, by chip id (useAttachmentIntake): its chip
  /// shows Retry (`onRetry`) while its preview still sends.
  originalFailures?: Readonly<Record<string, string>>;
  /// A staged chip dragged (or moved with Option-Left/Right) to `index`; unset, chips stay put.
  onReorder?(id: string, index: number): void;
  /// Files still being read: a placeholder chip each, after the staged ones (PendingAttachment).
  pending?: readonly PendingAttachment[];
  /// A pending chip's ×; unset, the chip has none.
  onCancel?(id: string): void;
  /// A failed chip's Retry; unset, the chip has none.
  onRetry?(id: string): void;
  error?: string;
  codex?: boolean;
  onRemove(id: string): void;
  /// A pasted text chip's click: its text goes back into the prompt (pastedText.ts). Unset, the chip
  /// only shows.
  onExpand?(id: string): void;
}) {
  const t = useT();
  // More chips than fit scroll sideways: the side with chips past it is marked, and the CSS fades it
  // by the prompt's band (composerAttachments.css).
  const edges = useScrollEdges("x");
  /// What a move says to assistive technology: the chip and where it is now.
  const [announced, setAnnounced] = useState("");
  // The chips and the pane's language as they are now: the move below is made once.
  const live = useRef({ attachments, t });
  live.current = { attachments, t };
  const [move] = useState(() => (id: string, index: number) => {
    const { attachments: chips, t: translate } = live.current;
    const chip = chips.find((attachment) => attachment.id === id);
    reorderTo.current?.(id, index);
    if (chip)
      setAnnounced(
        translate(ATTACHMENT_LABELS.moved, {
          name: chip.name,
          position: index + 1,
          count: chips.length,
        }),
      );
  });
  const reorderTo = useRef(onReorder);
  reorderTo.current = onReorder;
  const reorder = useStripReorder(
    attachments.map((attachment) => attachment.id),
    onReorder ? move : undefined,
  );
  const hint = useId();
  const reorderRef = reorder.ref;
  const stripRef = useCallback(
    (node: HTMLElement | null) => {
      edges(node);
      reorderRef(node);
    },
    [edges, reorderRef],
  );
  // The drop overlay says what a drag does (composer/DropOverlay.tsx); a note here would grow the
  // composer mid-drag.
  if (attachments.length === 0 && pending.length === 0 && !error) return null;
  return (
    <fieldset
      ref={stripRef}
      className="acpmux-attachments"
      data-selected={selected ? "" : undefined}
      data-reorder={onReorder && attachments.length > 1 ? "" : undefined}
      aria-describedby={onReorder && attachments.length > 1 ? hint : undefined}
      aria-label={t(ATTACHMENT_LABELS.attachments)}
      style={{ "--acpmux-md-fade-band": `${FADE_BAND_PX}px` } as React.CSSProperties}
    >
      {attachments.map((attachment, index) => (
        // A slot that draws nothing of its own (display: contents): it names the chip for a drag.
        <div
          key={attachment.id}
          className="acpmux-attachment-slot"
          data-attachment-index={index}
          data-dragging={reorder.dragging === attachment.id || undefined}
        >
          <AttachmentChip
            attachment={attachment}
            codex={codex}
            onRemove={onRemove}
            {...(onExpand ? { onExpand } : {})}
            {...(onRetry && originalFailures?.[attachment.id]
              ? { onRetry, originalFailed: originalFailures[attachment.id] }
              : {})}
          />
        </div>
      ))}
      {pending.map((chip) => (
        <PendingChip key={chip.id} chip={chip} {...(onCancel ? { onCancel } : {})} {...(onRetry ? { onRetry } : {})} />
      ))}
      {error && <output className="acpmux-attachment-note">{error}</output>}
      {onReorder && attachments.length > 1 && (
        <span id={hint} className="visually-hidden acpmux-attachment-voiceover-only">
          {t(ATTACHMENT_LABELS.reorderHint)}
        </span>
      )}
      <output className="visually-hidden acpmux-attachment-voiceover-only" aria-live="polite">
        {announced}
      </output>
    </fieldset>
  );
}

/// A file still being read: an image's tile in the shape of an image chip, or a file's chip with its
/// name, with a spinner and a × that cancels it. One that could not be attached says why, with
/// Retry.
function PendingChip({
  chip,
  onCancel,
  onRetry,
}: {
  chip: PendingAttachment;
  onCancel?(id: string): void;
  onRetry?(id: string): void;
}) {
  const t = useT();
  const name = chip.image ? imageLabel(t, { name: chip.name }) : chip.name;
  const remove = onCancel && (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={t(chip.failed ? ATTACHMENT_LABELS.removeAttachment : ATTACHMENT_LABELS.cancelAttachment, { name })}
      onClick={() => onCancel(chip.id)}
    >
      <svg viewBox="0 0 16 16" width="8" height="8" aria-hidden="true">
        <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      </svg>
    </button>
  );
  const kind = chip.image ? "acpmux-attachment-image" : "acpmux-attachment-file";
  // One that could not be attached keeps its shape: what it is (its kind's glyph, a file's name),
  // one small retry button, and its ×; why is in its tooltip (Leo, 2026-10-31: "video attachments
  // (big attachments?) still sucks", over a strip of empty tiles with only an underlined Retry).
  if (chip.failed)
    return (
      <div
        className={`acpmux-attachment ${kind} acpmux-attachment-failed`}
        aria-label={name}
        /* tooltip-allow: the tile shows no reason; the tooltip says why it failed */ title={chip.failed}
      >
        {chip.image ? (
          <ImageIcon size={16} className="acpmux-attachment-failed-icon" />
        ) : (
          <>
            <FileDoc size={14} className="acpmux-attachment-failed-icon" />
            <span className="acpmux-attachment-failed-name">{chip.name}</span>
          </>
        )}
        {onRetry && <RetryButton reason={chip.failed} onRetry={() => onRetry(chip.id)} />}
        {remove}
      </div>
    );
  return (
    <div className={`acpmux-attachment ${kind} acpmux-attachment-pending`} aria-busy="true" aria-label={name}>
      {chip.progress === undefined ? (
        <Spinner loading size={16} className="acpmux-attachment-spinner" />
      ) : (
        <UploadProgress value={chip.progress} name={name} />
      )}
      {!chip.image && <span>{chip.name}</span>}
      {remove}
    </div>
  );
}

/// A failed attachment's one retry control: a small round button with the retry glyph, the same in
/// the strip and in the text; its tooltip says why it failed.
export function RetryButton({
  label,
  reason,
  onRetry,
  className = "acpmux-attachment-retry",
}: {
  /// What it does, for assistive technology (its tile is named for the file); "Retry" by default.
  label?: string;
  reason?: string;
  onRetry(): void;
  className?: string;
}) {
  const t = useT();
  return (
    <button
      type="button"
      className={className}
      aria-label={label ?? t(ATTACHMENT_LABELS.retryAttachment)}
      /* tooltip-allow: the button is a glyph; the tooltip says what failed and why */
      title={reason ? `${t(ATTACHMENT_LABELS.retryAttachment)}: ${reason}` : t(ATTACHMENT_LABELS.retryAttachment)}
      onClick={(event) => {
        event.stopPropagation();
        onRetry();
      }}
    >
      <Retry size={12} />
    </button>
  );
}

/// How much of a file streaming to the chat's machine is there: a ring that fills, on its tile.
export function UploadProgress({ value, name, size = 16 }: { value: number; name: string; size?: number }) {
  const percent = Math.round(value * 100);
  const radius = 6;
  const circumference = 2 * Math.PI * radius;
  return (
    <>
      <progress className="visually-hidden" aria-label={name} max={100} value={percent} />
      <svg className="acpmux-attachment-progress" width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
        <circle className="acpmux-attachment-progress-track" cx="8" cy="8" r={radius} />
        <circle
          className="acpmux-attachment-progress-arc"
          cx="8"
          cy="8"
          r={radius}
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - value)}
          transform="rotate(-90 8 8)"
        />
      </svg>
    </>
  );
}

/// A chip's kept thumbnail; a copy pasted beside its original in the prompt (attachments.ts
/// inlineCopyId) draws the original's.
const keptThumbOf = (id: string) => keptThumb(id) ?? keptThumb(inlineCopyParent(id) ?? id);

/// A staged attachment's chip: the strip draws it, and so does the prompt for one placed in its text
/// (composer/inlineAttachments.tsx), with the same preview, open, play and remove.
export function AttachmentChip({
  attachment,
  codex = false,
  onRemove,
  onExpand,
  onRetry,
  originalFailed,
}: {
  attachment: ComposerAttachment;
  codex?: boolean;
  onRemove(id: string): void;
  onExpand?(id: string): void;
  /// An image whose original failed to upload (`originalFailed`, why): its Retry uploads it again.
  onRetry?(id: string): void;
  originalFailed?: string;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const openImage = useContext(ImageViewerContext);
  const [broken, setBroken] = useState(false);
  const [thumb, setThumb] = useState<{ url: string; width: number; height: number } | undefined>(() =>
    keptThumbOf(attachment.id),
  );
  /// The image's natural size, from its thumbnail or from the image itself once it loads.
  const [size, setSize] = useState<{ width: number; height: number }>();
  const videoReading = useVideoReading(attachment.id);
  const isImage = attachment.kind === "image" && Boolean(attachment.data);
  const image = isImage && !broken;
  const source = image ? `data:${attachment.mimeType};base64,${attachment.data}` : undefined;
  // A pasted image's name is WebKit's "image.png": show what it is instead (imageLabel.ts).
  const pasted = attachment.kind === "pasted";
  const name = isImage
    ? imageLabel(t, { name: attachment.name, ...(thumb ?? size) })
    : pasted
      ? t(ATTACHMENT_LABELS.pastedText)
      : attachment.name;
  useEffect(() => {
    if (!image || !attachment.data || keptThumbOf(attachment.id)) return;
    let live = true;
    void thumbnail({ mimeType: attachment.mimeType, data: attachment.data }).then((made) => {
      if (live) setThumb(made);
    });
    return () => {
      live = false;
    };
  }, [attachment.data, attachment.id, attachment.mimeType, image]);
  const remove = (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={t(ATTACHMENT_LABELS.removeAttachment, { name })}
      onClick={() => onRemove(attachment.id)}
    >
      <svg viewBox="0 0 16 16" width="8" height="8" aria-hidden="true">
        <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      </svg>
    </button>
  );
  // Its right-click menu: Open (or what a click does) where a click opens it, and Remove (cx-2lm4).
  const menu = (open: (() => void) | undefined, chip: React.ReactNode, openLabel = t("image.open")) => (
    <ContextMenu
      className="acpmux-attachment-menu"
      items={[
        ...(open ? [{ id: "open", label: openLabel, onSelect: open }] : []),
        {
          id: "remove",
          label: t(ATTACHMENT_LABELS.removeAttachment, { name }),
          separatorBefore: Boolean(open),
          onSelect: () => onRemove(attachment.id),
        },
      ]}
    >
      {chip}
    </ContextMenu>
  );
  if (image && source) {
    const img = (
      <img
        alt={name}
        // A drag moves the chip along the strip (stripReorder.ts), never the picture out as a file.
        draggable={false}
        src={thumb?.url ?? source}
        onError={() => setBroken(true)}
        onLoad={(event) => {
          const { naturalWidth: width, naturalHeight: height } = event.currentTarget;
          // An image that decodes to no pixels draws nothing: it failed too.
          if (!width || !height) setBroken(true);
          else if (!thumb) setSize({ width, height });
        }}
      />
    );
    return menu(
      openImage ? () => openImage(source, name) : undefined,
      <div
        className="acpmux-attachment acpmux-attachment-image"
        /* tooltip-allow: an image thumbnail shows no name */ title={name}
      >
        {openImage ? (
          <button
            type="button"
            className="acpmux-attachment-open"
            aria-label={t(ATTACHMENT_LABELS.openAttachment, { name })}
            onClick={() => openImage(source, name)}
          >
            {img}
          </button>
        ) : (
          img
        )}
        {originalFailed && onRetry && (
          <RetryButton
            className="acpmux-attachment-original-retry"
            label={t(ATTACHMENT_LABELS.retryOriginal, { name })}
            reason={t(ATTACHMENT_LABELS.originalFailed, { name, reason: originalFailed })}
            onRetry={() => onRetry(attachment.id)}
          />
        )}
        {remove}
      </div>,
    );
  }
  // An image the engine could not draw says so in its slot, instead of an empty tile or a bare
  // file name; its × still removes it.
  if (isImage) return menu(undefined, <BrokenImageChip remove={remove} onRetry={() => setBroken(false)} />);
  // A huge paste (pastedText.ts): its first words and line count; a click puts it back in the prompt.
  if (pasted) {
    const text = attachment.text ?? "";
    const lines = pasteLines(text);
    const count = new Intl.NumberFormat(language).format(lines);
    const expand = onExpand ? () => onExpand(attachment.id) : undefined;
    const label = `${name} · ${t(ATTACHMENT_LABELS.pastedLines, { n: lines, count })}`;
    const accessible = `${attachment.name || pasteName(text)}, ${label}`;
    const body = <TextAttachmentCard text={text} label={label} />;
    return menu(
      expand,
      <div className="acpmux-attachment acpmux-attachment-pasted acpmux-text-card">
        {expand ? (
          <button
            type="button"
            className="acpmux-attachment-pasted-open"
            aria-label={accessible}
            /* tooltip-allow: the chip shows the paste's first lines; the tooltip says a click puts it back in the prompt */
            title={t(ATTACHMENT_LABELS.editPasted)}
            onClick={expand}
          >
            {body}
          </button>
        ) : (
          <span className="acpmux-attachment-pasted-open">{body}</span>
        )}
        {remove}
      </div>,
      t(ATTACHMENT_LABELS.editPasted),
    );
  }
  // A text file (attachments.ts readAttachment) or a picked selection: the same page of its first
  // lines, under its name and line count.
  if (attachment.kind === "text" && attachment.text !== undefined) {
    const lines = pasteLines(attachment.text);
    const label = `${attachment.name} · ${t(ATTACHMENT_LABELS.pastedLines, { n: lines, count: new Intl.NumberFormat(language).format(lines) })}`;
    return menu(
      undefined,
      <div
        className="acpmux-attachment acpmux-attachment-pasted acpmux-text-card"
        data-text-kind="file"
        /* tooltip-allow: the card cuts a long name; the tooltip has it whole */
        title={attachment.path ?? attachment.name}
      >
        <span className="acpmux-attachment-pasted-open">
          <TextAttachmentCard text={attachment.text} label={label} />
        </span>
        {remove}
      </div>,
    );
  }
  if (attachment.kind === "document" && attachment.data) {
    return menu(
      undefined,
      <PdfAttachmentChip
        attachment={{ ...attachment, kind: "document", data: attachment.data }}
        remove={remove}
        codex={codex}
      />,
    );
  }
  // A video goes as its path too, with its poster and length once the host read them; a click plays it.
  if (isVideoAttachment(attachment) && (attachment.video || videoReading)) {
    const play = () => void callChipHost("video.quickLook", { src: attachment.path });
    return menu(
      attachment.video ? play : undefined,
      <VideoAttachmentTile name={attachment.name} video={attachment.video} remove={remove} onPlay={play} />,
      t("media.play"),
    );
  }
  return menu(
    undefined,
    <div
      className="acpmux-attachment acpmux-attachment-file acpmux-attachment-link"
      data-saved={attachment.saved || undefined}
      /* tooltip-allow: the full path is secondary detail for the file chip */
      title={attachment.path}
    >
      <FileAttachment
        file={{
          ...attachment,
          // Native path-only choices have no byte count; do not invent a zero-byte file.
          size: attachment.mimeType || attachment.size > 0 ? attachment.size : undefined,
        }}
        remove={remove}
      />
    </div>,
  );
}

/// An image the engine could not draw: it says so in its slot, instead of an empty tile or a bare file
/// name. Retry draws it again; its × still removes it. The strip's chip and the prompt's
/// (composer/inlineAttachments.tsx) both draw this one.
export function BrokenImageChip({ remove, onRetry }: { remove: React.ReactNode; onRetry(): void }) {
  const t = useT();
  return (
    <div className="acpmux-attachment acpmux-attachment-image acpmux-attachment-image-failed">
      <ImageIcon size={16} className="acpmux-attachment-failed-icon" />
      <span className="acpmux-attachment-failed-text">{t("image.failed")}</span>
      <RetryButton onRetry={onRetry} />
      {remove}
    </div>
  );
}

function PdfAttachmentChip({
  attachment,
  remove,
  codex,
}: {
  attachment: ComposerAttachment & { kind: "document"; data: string };
  remove: React.ReactNode;
  codex: boolean;
}) {
  const t = useT();
  const [pdfOpen, setPdfOpen] = useState(false);
  const close = useRef<HTMLButtonElement>(null);
  // `frame-src` intentionally excludes data/blob URLs. Keep the inline preview deterministic and
  // open the original bytes in a native browser tab from the modal instead of weakening CSP.
  const [pdfUrl, setPdfUrl] = useState<string>();
  useEffect(() => {
    if (!pdfOpen) {
      setPdfUrl(undefined);
      return;
    }
    try {
      const bytes = Uint8Array.from(atob(attachment.data), (char) => char.charCodeAt(0));
      const url = URL.createObjectURL(new Blob([bytes], { type: "application/pdf" }));
      setPdfUrl(url);
      return () => URL.revokeObjectURL(url);
    } catch {
      setPdfUrl(undefined);
      return;
    }
  }, [attachment.data, pdfOpen]);
  const pageLabel = attachment.pageCount === undefined ? "PDF" : `${attachment.pageCount}p`;
  const deliveryLabel = codex ? `${pageLabel} · ${t(ATTACHMENT_LABELS.sentAsFileForCodex)}` : pageLabel;
  return (
    <>
      <div className="acpmux-attachment acpmux-attachment-document" data-page-count={attachment.pageCount ?? undefined}>
        <button
          type="button"
          className="acpmux-attachment-document-open"
          aria-label={t(ATTACHMENT_LABELS.openAttachment, { name: attachment.name })}
          onClick={() => setPdfOpen(true)}
        >
          <PdfSheetPreview />
        </button>
        <span className="acpmux-attachment-document-meta">
          <FileDoc size={15} />
          <span className="acpmux-attachment-document-name">{attachment.name}</span>
          <span className="acpmux-attachment-document-pages">{deliveryLabel}</span>
        </span>
        {remove}
      </div>
      <Dialog
        open={pdfOpen}
        onOpenChange={setPdfOpen}
        label={t(ATTACHMENT_LABELS.openAttachment, { name: attachment.name })}
        className="ui-glass ui-glass-floats acpmux-pdf-viewer"
        initialFocus={close}
      >
        <div className="acpmux-pdf-viewer-bar">
          <span className="acpmux-image-viewer-title">{attachment.name}</span>
          <span className="acpmux-image-viewer-count">{deliveryLabel}</span>
          <button
            type="button"
            className="acpmux-image-viewer-action"
            ref={close}
            aria-label={t("image.close")}
            onClick={() => setPdfOpen(false)}
          >
            <Close />
          </button>
        </div>
        <div className="acpmux-pdf-viewer-preview">
          <PdfSheetPreview large />
        </div>
        {pdfUrl && (
          <a
            className="acpmux-pdf-viewer-open"
            href={pdfUrl}
            target="_blank"
            rel="noreferrer"
            aria-label={t(ATTACHMENT_LABELS.openAttachment, { name: attachment.name })}
          >
            <FileDoc size={15} />
            <span>{attachment.name}</span>
          </a>
        )}
      </Dialog>
    </>
  );
}

/** A CSP-safe PDF thumbnail; the original bytes remain available via the modal's open link. */
function PdfSheetPreview({ large = false }: { large?: boolean }) {
  return (
    <span className={`acpmux-pdf-sheet${large ? " is-large" : ""}`} aria-hidden="true">
      <span className="acpmux-pdf-sheet-fold" />
      <span className="acpmux-pdf-sheet-mark">PDF</span>
      <span className="acpmux-pdf-sheet-lines">
        <i />
        <i />
        <i />
        <i />
      </span>
    </span>
  );
}
