/**
 * VNC Recording Session Hook
 *
 * Integrates useVncRecorder with Convex storage for persisted video recordings.
 * Handles the full flow: start recording → record → stop → upload → complete
 */

import { useCallback, useRef, useState } from "react";
import { useMutation } from "convex/react";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { useVncRecorder, type VideoCheckpoint } from "./use-vnc-recorder";

export interface VncRecordingSessionState {
  /** Whether a recording session is active */
  isRecording: boolean;
  /** Whether the recorder is paused */
  isPaused: boolean;
  /** Current recording duration in milliseconds */
  duration: number;
  /** Checkpoints added during recording */
  checkpoints: VideoCheckpoint[];
  /** Whether the session is currently uploading */
  isUploading: boolean;
  /** Error message if something went wrong */
  error: string | null;
  /** The current recording ID in Convex (if recording) */
  recordingId: Id<"taskRunVideoRecordings"> | null;
}

export interface VncRecordingSessionOptions {
  /** Team slug or ID for authorization */
  teamSlugOrId: string;
  /** Task ID this recording belongs to */
  taskId: Id<"tasks">;
  /** Task run ID this recording belongs to */
  runId: Id<"taskRuns">;
  /** Optional commit SHA to associate with recording */
  commitSha?: string;
  /** Callback when recording completes successfully */
  onComplete?: (recordingId: Id<"taskRunVideoRecordings">) => void;
  /** Callback when an error occurs */
  onError?: (error: Error) => void;
}

export interface VncRecordingSessionHandle {
  /** Start a new recording session */
  startSession: (canvas: HTMLCanvasElement) => Promise<void>;
  /** Stop the recording session and upload */
  stopSession: () => Promise<void>;
  /** Pause the recording */
  pauseSession: () => void;
  /** Resume the recording */
  resumeSession: () => void;
  /** Add a checkpoint at the current time */
  addCheckpoint: (
    label: string,
    options?: { description?: string; type?: VideoCheckpoint["type"] }
  ) => void;
  /** Current session state */
  state: VncRecordingSessionState;
}

export function useVncRecordingSession(
  options: VncRecordingSessionOptions
): VncRecordingSessionHandle {
  const { teamSlugOrId, taskId, runId, commitSha, onComplete, onError } =
    options;

  const [isUploading, setIsUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [recordingId, setRecordingId] =
    useState<Id<"taskRunVideoRecordings"> | null>(null);

  const recordingIdRef = useRef<Id<"taskRunVideoRecordings"> | null>(null);

  // Convex mutations
  const startRecordingMutation = useMutation(
    api.videoRecordings.clientStartRecording
  );
  const generateUploadUrl = useMutation(
    api.videoRecordings.generateVideoUploadUrl
  );
  const completeRecordingMutation = useMutation(
    api.videoRecordings.clientCompleteRecording
  );
  const failRecordingMutation = useMutation(
    api.videoRecordings.clientFailRecording
  );

  // Base recorder hook
  const recorder = useVncRecorder({
    fps: 30,
    videoBitsPerSecond: 2500000,
    onError: (err) => {
      console.error("[VncRecordingSession] Recorder error:", err);
      setError(err.message);

      // Mark the Convex recording as failed
      if (recordingIdRef.current) {
        failRecordingMutation({
          recordingId: recordingIdRef.current,
          error: err.message,
        }).catch((mutationErr) => {
          console.error(
            "[VncRecordingSession] Failed to mark recording as failed:",
            mutationErr
          );
        });
      }

      onError?.(err);
    },
  });

  const startSession = useCallback(
    async (canvas: HTMLCanvasElement) => {
      try {
        setError(null);

        // Create recording record in Convex
        const newRecordingId = await startRecordingMutation({
          teamSlugOrId,
          taskId,
          runId,
          commitSha,
        });

        recordingIdRef.current = newRecordingId;
        setRecordingId(newRecordingId);

        // Start the MediaRecorder
        recorder.startRecording(canvas);

        console.log(
          `[VncRecordingSession] Started recording session: ${newRecordingId}`
        );
      } catch (err) {
        const error = err instanceof Error ? err : new Error(String(err));
        console.error("[VncRecordingSession] Failed to start session:", error);
        setError(error.message);
        onError?.(error);
      }
    },
    [
      teamSlugOrId,
      taskId,
      runId,
      commitSha,
      startRecordingMutation,
      recorder,
      onError,
    ]
  );

  const stopSession = useCallback(async () => {
    const currentRecordingId = recordingIdRef.current;
    if (!currentRecordingId) {
      console.warn("[VncRecordingSession] No active recording to stop");
      return;
    }

    try {
      setIsUploading(true);

      // Stop the MediaRecorder and get the blob
      const result = await recorder.stopRecording();
      if (!result) {
        throw new Error("Failed to get recording blob");
      }

      const { blob, checkpoints } = result;

      console.log(
        `[VncRecordingSession] Recording stopped. Size: ${blob.size} bytes, Checkpoints: ${checkpoints.length}`
      );

      // Get upload URL from Convex
      const uploadUrl = await generateUploadUrl({});

      // Upload the blob
      const uploadResponse = await fetch(uploadUrl, {
        method: "POST",
        headers: {
          "Content-Type": blob.type,
        },
        body: blob,
      });

      if (!uploadResponse.ok) {
        throw new Error(`Upload failed: ${uploadResponse.statusText}`);
      }

      const { storageId } = (await uploadResponse.json()) as {
        storageId: Id<"_storage">;
      };

      // Complete the recording in Convex
      await completeRecordingMutation({
        recordingId: currentRecordingId,
        storageId,
        durationMs: recorder.state.duration,
        fileSizeBytes: blob.size,
        checkpoints,
      });

      console.log(
        `[VncRecordingSession] Recording completed: ${currentRecordingId}`
      );

      recordingIdRef.current = null;
      setRecordingId(null);
      setIsUploading(false);

      onComplete?.(currentRecordingId);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      console.error("[VncRecordingSession] Failed to stop session:", error);
      setError(error.message);
      setIsUploading(false);

      // Mark the recording as failed
      if (currentRecordingId) {
        failRecordingMutation({
          recordingId: currentRecordingId,
          error: error.message,
        }).catch((mutationErr) => {
          console.error(
            "[VncRecordingSession] Failed to mark recording as failed:",
            mutationErr
          );
        });
      }

      onError?.(error);
    }
  }, [
    recorder,
    generateUploadUrl,
    completeRecordingMutation,
    failRecordingMutation,
    onComplete,
    onError,
  ]);

  const pauseSession = useCallback(() => {
    recorder.pauseRecording();
  }, [recorder]);

  const resumeSession = useCallback(() => {
    recorder.resumeRecording();
  }, [recorder]);

  const addCheckpoint = useCallback(
    (
      label: string,
      opts?: { description?: string; type?: VideoCheckpoint["type"] }
    ) => {
      recorder.addCheckpoint(label, opts);
    },
    [recorder]
  );

  const state: VncRecordingSessionState = {
    isRecording: recorder.state.isRecording,
    isPaused: recorder.state.isPaused,
    duration: recorder.state.duration,
    checkpoints: recorder.state.checkpoints,
    isUploading,
    error: error ?? recorder.state.error,
    recordingId,
  };

  return {
    startSession,
    stopSession,
    pauseSession,
    resumeSession,
    addCheckpoint,
    state,
  };
}

export default useVncRecordingSession;
