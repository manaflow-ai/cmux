// The capture bar's work in the pane (CaptureBar.tsx, captureModel.ts): it asks the host for the
// pixels (`composer.capture`, `capture.record.*`, AgentPaneCapture.swift) and sends what comes back
// where the person chose: the chat's composer as a chip, the clipboard, or a file
// (`capture.copy`, `capture.save`). The host's Capture action (⌃⇧⌘5, View > Capture…) reaches it
// as `cmuxAcpmuxBridge.captureBar({toggle: true})`.
import { useCallback, useEffect, useMemo, useReducer, useRef } from "react";
import { attachmentSource, linkAttachment, readAttachment, withSource, type ComposerAttachment } from "../attachments";
import { translate, type StringKey, type StringValues } from "../i18n";
import {
  captureReducer,
  INITIAL_CAPTURE,
  MAX_RECORDING_SECONDS,
  parseRecording,
  reopen,
  toggleMeaning,
  type CaptureState,
  type CaptureTarget,
} from "./captureModel";
import type { CaptureBarActions } from "./CaptureBar";

type Native = <T>(method: string, params?: Record<string, unknown>) => Promise<T>;

export type CaptureBarHost = {
  callNative: Native;
  /// Adds a chip to the shown chat's composer (ComposerHandle.attach).
  attach(attachment: ComposerAttachment): void;
  /// A short notice over the composer.
  notice(text: string): void;
  /// Whether the shown chat's agent runs on this Mac, so it can open a recording's file.
  chatIsLocal(): boolean;
  /// The shown chat's identity (its session, and for a chat with none yet, its New Tab visit): a
  /// capture lands only in the chat it was made for.
  chat(): string;
};

type Shot = {
  name?: string;
  mimeType?: string;
  data?: string;
  tooLarge?: boolean;
  cancelled?: boolean;
  source?: unknown;
};

const say = (key: StringKey, values?: StringValues) => translate(key, values);

export function useCaptureBar(host: CaptureBarHost) {
  const [state, dispatch] = useReducer(
    (current: CaptureState, next: CaptureState | Parameters<typeof captureReducer>[1]) =>
      "phase" in next ? next : captureReducer(current, next),
    INITIAL_CAPTURE,
  );
  // The bridge and the host's answers read the newest state, not the one their closure saw.
  const latest = useRef(state);
  latest.current = state;
  const hostRef = useRef(host);
  const recordedFor = useRef<string | undefined>(undefined);
  hostRef.current = host;

  const finish = useCallback(() => dispatch({ type: "done" }), []);
  const failed = useCallback((key: StringKey, values?: StringValues) => {
    hostRef.current.notice(say(key, values));
    dispatch(reopen(latest.current));
  }, []);

  const shoot = useCallback(
    (target: CaptureTarget) => {
      const { callNative, attach, notice, chat } = hostRef.current;
      const destination = latest.current.destination;
      const takenFor = chat();
      dispatch({ type: "begin", what: target });
      void callNative<Shot | null>("composer.capture", { mode: target })
        .then(async (shot) => {
          if (shot?.tooLarge) return failed("composer.tooLarge", { name: shot.name ?? "Screenshot.png" });
          if (!shot?.data) return finish();
          const mimeType = shot.mimeType ?? "image/png";
          const name = shot.name ?? "Screenshot.png";
          // The chat shown now is the one the shot was taken for: only then does it take the chip.
          // Otherwise it is copied, never dropped and never put in another chat's draft.
          const here = hostRef.current.chat() === takenFor;
          if (destination === "copy" || (destination === "chat" && !here)) {
            await callNative("capture.copy", { data: shot.data, mimeType });
            notice(say("capture.copied"));
          } else if (destination === "save") {
            await callNative("capture.save", { data: shot.data, mimeType, name });
          } else {
            const bytes = Uint8Array.from(atob(shot.data), (char) => char.charCodeAt(0));
            // cmux took it: its chip wears cmux's icon (composer/attachmentSources.ts).
            const file = withSource(new File([bytes], name, { type: mimeType }), attachmentSource(shot.source));
            const read = await readAttachment(file, true);
            // Reading it takes a moment: a chat switched meanwhile gets no chip, the clipboard does.
            if (hostRef.current.chat() !== takenFor) {
              await callNative("capture.copy", { data: shot.data, mimeType });
              notice(say("capture.copied"));
            } else {
              if ("id" in read) attach(read);
              // The chat took it: its Copy and Save on the host are spent.
              void callNative("capture.done").catch(() => {});
            }
          }
          finish();
        })
        .catch(() => failed("capture.failed"));
    },
    [failed, finish],
  );

  const record = useCallback(() => {
    const { callNative } = hostRef.current;
    const { cursor, clicks } = latest.current;
    recordedFor.current = hostRef.current.chat();
    dispatch({ type: "begin", what: "record" });
    void callNative("capture.record.start", { cursor, clicks }).then(
      () => dispatch({ type: "recording", at: Date.now() }),
      () => failed("capture.recordFailed"),
    );
  }, [failed]);

  const stop = useCallback(() => {
    const { callNative, attach, notice, chatIsLocal, chat } = hostRef.current;
    const destination = latest.current.destination;
    if (latest.current.phase.kind !== "recording") return;
    dispatch({ type: "stop" });
    void callNative<unknown>("capture.record.stop")
      .then(async (value) => {
        const recording = parseRecording(value);
        if (!recording) return finish();
        // The chat shown now is the one it was started from, on this Mac: only then can it take
        // the file. Otherwise the recording is copied, never dropped and never sent to another chat.
        const here = chatIsLocal() && chat() === recordedFor.current;
        const saved =
          destination === "save"
            ? await callNative<{ saved?: string } | null>("capture.save", {
                path: recording.path,
                name: recording.name,
              }).catch(() => null)
            : undefined;
        if (saved?.saved) {
          // Saved where the person chose.
        } else if (destination !== "chat" || !here) {
          await callNative("capture.copy", { path: recording.path });
          notice(say(destination === "copy" || saved !== undefined ? "capture.copied" : "capture.recordingElsewhere"));
        } else {
          // The composer reads its poster, length and frames (composer/videoAttachments.ts).
          attach({ ...linkAttachment(recording.path, false), name: recording.name });
        }
        finish();
      })
      .catch(() => {
        hostRef.current.notice(say("capture.recordFailed"));
        finish();
      });
  }, [finish]);

  /// The host's Capture action (`{toggle: true}`): open, close, or stop the recording; and the
  /// host's word that a recording ended by itself (`{ended: true}`: its window closed, the time ran
  /// out, or it failed), which collects the movie as Stop does.
  const toggle = useCallback(
    (value?: unknown) => {
      const ended = typeof value === "object" && value !== null && (value as { ended?: unknown }).ended === true;
      if (ended || toggleMeaning(latest.current.phase) === "stop") stop();
      else dispatch({ type: "toggle" });
    },
    [stop],
  );
  // The page's own stop at the longest recording, in case the host's word does not come; the
  // timer lives only while a recording runs.
  const startedAt = state.phase.kind === "recording" ? state.phase.startedAt : undefined;
  useEffect(() => {
    if (startedAt === undefined) return;
    const timer = setTimeout(stop, Math.max(0, startedAt + MAX_RECORDING_SECONDS * 1000 - Date.now()));
    return () => clearTimeout(timer);
  }, [startedAt, stop]);

  const actions = useMemo<CaptureBarActions>(
    () => ({
      shoot,
      record,
      stop,
      close: () => dispatch({ type: "close" }),
      destination: (destination) => dispatch({ type: "destination", destination }),
      option: (option, on) => dispatch({ type: "option", option, on }),
    }),
    [shoot, record, stop],
  );
  return { state, actions, toggle };
}
