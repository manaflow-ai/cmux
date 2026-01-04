import { useCallback, useRef, useState } from "react";

export interface VideoCheckpoint {
  timestampMs: number;
  label: string;
  description?: string;
  type?: "commit" | "command" | "file_change" | "error" | "milestone" | "manual";
}

export interface VncRecorderState {
  isRecording: boolean;
  isPaused: boolean;
  duration: number;
  checkpoints: VideoCheckpoint[];
  error: string | null;
}

export interface VncRecorderOptions {
  /** Target frames per second (default: 30) */
  fps?: number;
  /** Video bitrate in bits per second (default: 2500000 = 2.5Mbps) */
  videoBitsPerSecond?: number;
  /** Preferred MIME type (default: video/webm;codecs=vp9) */
  mimeType?: string;
  /** Callback when recording completes */
  onComplete?: (blob: Blob, checkpoints: VideoCheckpoint[]) => void;
  /** Callback when error occurs */
  onError?: (error: Error) => void;
  /** Callback when checkpoint is added */
  onCheckpoint?: (checkpoint: VideoCheckpoint) => void;
}

export interface VncRecorderHandle {
  /** Start recording from a canvas element */
  startRecording: (canvas: HTMLCanvasElement) => void;
  /** Stop recording and get the video blob */
  stopRecording: () => Promise<{ blob: Blob; checkpoints: VideoCheckpoint[] } | null>;
  /** Pause recording */
  pauseRecording: () => void;
  /** Resume recording */
  resumeRecording: () => void;
  /** Add a checkpoint at the current time */
  addCheckpoint: (label: string, options?: {
    description?: string;
    type?: VideoCheckpoint["type"];
  }) => void;
  /** Get current state */
  state: VncRecorderState;
}

/**
 * Hook for recording VNC canvas to video with checkpoint support.
 * Uses MediaRecorder API to capture canvas as WebM video.
 */
export function useVncRecorder(options: VncRecorderOptions = {}): VncRecorderHandle {
  const {
    fps = 30,
    videoBitsPerSecond = 2500000,
    mimeType = getSupportedMimeType(),
    onComplete,
    onError,
    onCheckpoint,
  } = options;

  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const startTimeRef = useRef<number>(0);
  const pausedDurationRef = useRef<number>(0);
  const pauseStartRef = useRef<number>(0);
  const checkpointsRef = useRef<VideoCheckpoint[]>([]);

  const [state, setState] = useState<VncRecorderState>({
    isRecording: false,
    isPaused: false,
    duration: 0,
    checkpoints: [],
    error: null,
  });

  // Get elapsed recording time (excluding paused time)
  const getElapsedTime = useCallback(() => {
    if (!startTimeRef.current) return 0;
    const now = Date.now();
    const totalElapsed = now - startTimeRef.current;
    const pausedTime = state.isPaused
      ? pausedDurationRef.current + (now - pauseStartRef.current)
      : pausedDurationRef.current;
    return totalElapsed - pausedTime;
  }, [state.isPaused]);

  // Start recording
  const startRecording = useCallback((canvas: HTMLCanvasElement) => {
    try {
      // Check if MediaRecorder is supported
      if (!window.MediaRecorder) {
        throw new Error("MediaRecorder is not supported in this browser");
      }

      // Get canvas stream
      const stream = canvas.captureStream(fps);
      if (!stream) {
        throw new Error("Failed to capture canvas stream");
      }

      // Create MediaRecorder
      const mediaRecorder = new MediaRecorder(stream, {
        mimeType,
        videoBitsPerSecond,
      });

      // Reset state
      chunksRef.current = [];
      checkpointsRef.current = [];
      startTimeRef.current = Date.now();
      pausedDurationRef.current = 0;
      pauseStartRef.current = 0;

      // Handle data available
      mediaRecorder.ondataavailable = (event) => {
        if (event.data && event.data.size > 0) {
          chunksRef.current.push(event.data);
        }
      };

      // Handle errors
      mediaRecorder.onerror = (event) => {
        const error = new Error(`Recording error: ${event}`);
        console.error("[VncRecorder] Recording error:", event);
        setState((prev) => ({ ...prev, error: error.message, isRecording: false }));
        onError?.(error);
      };

      // Start recording
      mediaRecorder.start(1000); // Collect data every second
      mediaRecorderRef.current = mediaRecorder;

      setState({
        isRecording: true,
        isPaused: false,
        duration: 0,
        checkpoints: [],
        error: null,
      });

      // Update duration periodically
      const durationInterval = setInterval(() => {
        if (mediaRecorderRef.current?.state === "recording") {
          setState((prev) => ({
            ...prev,
            duration: getElapsedTime(),
          }));
        } else {
          clearInterval(durationInterval);
        }
      }, 100);

      console.log("[VncRecorder] Started recording");
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      console.error("[VncRecorder] Failed to start recording:", err);
      setState((prev) => ({ ...prev, error: err.message }));
      onError?.(err);
    }
  }, [fps, mimeType, videoBitsPerSecond, getElapsedTime, onError]);

  // Stop recording
  const stopRecording = useCallback(async (): Promise<{ blob: Blob; checkpoints: VideoCheckpoint[] } | null> => {
    return new Promise((resolve) => {
      const mediaRecorder = mediaRecorderRef.current;
      if (!mediaRecorder || mediaRecorder.state === "inactive") {
        console.warn("[VncRecorder] No active recording to stop");
        resolve(null);
        return;
      }

      mediaRecorder.onstop = () => {
        const blob = new Blob(chunksRef.current, { type: mimeType });
        const checkpoints = [...checkpointsRef.current];
        const finalDuration = getElapsedTime();

        console.log(`[VncRecorder] Recording stopped. Duration: ${finalDuration}ms, Size: ${blob.size} bytes, Checkpoints: ${checkpoints.length}`);

        setState({
          isRecording: false,
          isPaused: false,
          duration: finalDuration,
          checkpoints,
          error: null,
        });

        onComplete?.(blob, checkpoints);
        resolve({ blob, checkpoints });
      };

      mediaRecorder.stop();
      mediaRecorderRef.current = null;
    });
  }, [mimeType, getElapsedTime, onComplete]);

  // Pause recording
  const pauseRecording = useCallback(() => {
    const mediaRecorder = mediaRecorderRef.current;
    if (!mediaRecorder || mediaRecorder.state !== "recording") {
      console.warn("[VncRecorder] No active recording to pause");
      return;
    }

    mediaRecorder.pause();
    pauseStartRef.current = Date.now();
    setState((prev) => ({ ...prev, isPaused: true }));
    console.log("[VncRecorder] Recording paused");
  }, []);

  // Resume recording
  const resumeRecording = useCallback(() => {
    const mediaRecorder = mediaRecorderRef.current;
    if (!mediaRecorder || mediaRecorder.state !== "paused") {
      console.warn("[VncRecorder] No paused recording to resume");
      return;
    }

    // Add paused time to total paused duration
    pausedDurationRef.current += Date.now() - pauseStartRef.current;
    pauseStartRef.current = 0;

    mediaRecorder.resume();
    setState((prev) => ({ ...prev, isPaused: false }));
    console.log("[VncRecorder] Recording resumed");
  }, []);

  // Add checkpoint
  const addCheckpoint = useCallback((
    label: string,
    options?: { description?: string; type?: VideoCheckpoint["type"] }
  ) => {
    if (!state.isRecording) {
      console.warn("[VncRecorder] Cannot add checkpoint when not recording");
      return;
    }

    const checkpoint: VideoCheckpoint = {
      timestampMs: getElapsedTime(),
      label,
      description: options?.description,
      type: options?.type,
    };

    checkpointsRef.current.push(checkpoint);
    setState((prev) => ({
      ...prev,
      checkpoints: [...prev.checkpoints, checkpoint],
    }));

    console.log(`[VncRecorder] Added checkpoint: ${label} at ${checkpoint.timestampMs}ms`);
    onCheckpoint?.(checkpoint);
  }, [state.isRecording, getElapsedTime, onCheckpoint]);

  return {
    startRecording,
    stopRecording,
    pauseRecording,
    resumeRecording,
    addCheckpoint,
    state,
  };
}

/**
 * Get the best supported MIME type for video recording
 */
function getSupportedMimeType(): string {
  const types = [
    "video/webm;codecs=vp9",
    "video/webm;codecs=vp8",
    "video/webm",
    "video/mp4",
  ];

  for (const type of types) {
    if (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(type)) {
      return type;
    }
  }

  return "video/webm"; // Fallback
}

export default useVncRecorder;
