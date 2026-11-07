// The capture bar's work in the pane (CaptureBar.tsx, captureModel.ts): it asks the host for the
// pixels (`composer.capture`, `capture.record.*`, AgentPaneCapture.swift) and sends what comes back
// where the person chose: the chat's composer as a chip, the clipboard, or a file
// (`capture.copy`, `capture.save`). The host's Capture action (⌃⇧⌘5, View > Capture…) reaches it
// as `cmuxAcpmuxBridge.captureBar({toggle: true})`.
import { useCallback, useMemo, useReducer, useRef } from "react";
import { attachmentSource, linkAttachment, readAttachment, withSource, type ComposerAttachment } from "../attachments";
import { translate, type StringKey, type StringValues } from "../i18n";
import {
  captureReducer,
  INITIAL_CAPTURE,
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
  hostRef.current = host;

  const finish = useCallback(() => dispatch({ type: "done" }), []);
  const failed = useCallback((key: StringKey, values?: StringValues) => {
    hostRef.current.notice(say(key, values));
    dispatch(reopen(latest.current));
  }, []);

  const shoot = useCallback(
    (target: CaptureTarget) => {
      const { callNative, attach, notice } = hostRef.current;
      const destination = latest.current.destination;
      dispatch({ type: "begin", what: target });
      void callNative<Shot | null>("composer.capture", { mode: target })
        .then(async (shot) => {
          if (shot?.tooLarge) return failed("composer.tooLarge", { name: shot.name ?? "Screenshot.png" });
          if (!shot?.data) return finish();
          const mimeType = shot.mimeType ?? "image/png";
          const name = shot.name ?? "Screenshot.png";
          if (destination === "copy") {
            await callNative("capture.copy", { data: shot.data, mimeType });
            notice(say("capture.copied"));
          } else if (destination === "save") {
            await callNative("capture.save", { data: shot.data, mimeType, name });
          } else {
            const bytes = Uint8Array.from(atob(shot.data), (char) => char.charCodeAt(0));
            // cmux took it: its chip wears cmux's icon (composer/attachmentSources.ts).
            const file = withSource(new File([bytes], name, { type: mimeType }), attachmentSource(shot.source));
            const read = await readAttachment(file, true);
            if ("id" in read) attach(read);
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
    dispatch({ type: "begin", what: "record" });
    void callNative("capture.record.start", { cursor, clicks }).then(
      () => dispatch({ type: "recording", at: Date.now() }),
      () => failed("capture.recordFailed"),
    );
  }, [failed]);

  const stop = useCallback(() => {
    const { callNative, attach, notice, chatIsLocal } = hostRef.current;
    const destination = latest.current.destination;
    if (latest.current.phase.kind !== "recording") return;
    dispatch({ type: "stop" });
    void callNative<unknown>("capture.record.stop")
      .then(async (value) => {
        const recording = parseRecording(value);
        if (!recording) return finish();
        if (destination === "save") {
          await callNative("capture.save", { path: recording.path, name: recording.name });
        } else if (destination === "copy" || !chatIsLocal()) {
          // A chat on another computer cannot open a file on this Mac: the recording is copied.
          await callNative("capture.copy", { path: recording.path });
          notice(say(destination === "copy" ? "capture.copied" : "capture.recordingElsewhere"));
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

  /// The host's Capture action: open, close, or stop the recording.
  const toggle = useCallback(() => {
    if (toggleMeaning(latest.current.phase) === "stop") stop();
    else dispatch({ type: "toggle" });
  }, [stop]);

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
