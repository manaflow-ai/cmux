/**
 * Video recording utility functions
 * Shared utilities for video player and gallery components
 */

import type { VideoCheckpoint } from "./types";

/**
 * Format milliseconds to MM:SS or HH:MM:SS
 * @param ms - Time in milliseconds
 * @returns Formatted time string
 */
export function formatTime(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  if (hours > 0) {
    return `${hours}:${minutes.toString().padStart(2, "0")}:${seconds.toString().padStart(2, "0")}`;
  }
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

/**
 * Format duration in milliseconds to MM:SS or HH:MM:SS
 * Alias for formatTime for semantic clarity in duration contexts
 * @param ms - Duration in milliseconds
 * @returns Formatted duration string
 */
export function formatDuration(ms: number): string {
  return formatTime(ms);
}

/**
 * Format file size in bytes to human-readable string
 * @param bytes - File size in bytes
 * @returns Formatted file size string (e.g., "1.5 MB")
 */
export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/**
 * Get emoji icon for checkpoint type
 * @param type - Checkpoint type
 * @returns Emoji icon string
 */
export function getCheckpointIcon(type?: VideoCheckpoint["type"]): string {
  switch (type) {
    case "commit":
      return "📝";
    case "command":
      return "⚡";
    case "file_change":
      return "📄";
    case "error":
      return "❌";
    case "milestone":
      return "🎯";
    case "manual":
      return "📌";
    default:
      return "📍";
  }
}

/**
 * Get CSS class color for checkpoint type (Tailwind classes)
 * @param type - Checkpoint type
 * @returns Tailwind background color class
 */
export function getCheckpointColor(type?: VideoCheckpoint["type"]): string {
  switch (type) {
    case "commit":
      return "bg-emerald-500";
    case "command":
      return "bg-blue-500";
    case "file_change":
      return "bg-amber-500";
    case "error":
      return "bg-red-500";
    case "milestone":
      return "bg-purple-500";
    case "manual":
      return "bg-neutral-500";
    default:
      return "bg-neutral-400";
  }
}

/**
 * Sort checkpoints by timestamp (ascending)
 * @param checkpoints - Array of checkpoints
 * @returns New sorted array
 */
export function sortCheckpointsByTime(
  checkpoints: VideoCheckpoint[]
): VideoCheckpoint[] {
  return [...checkpoints].sort((a, b) => a.timestampMs - b.timestampMs);
}

/**
 * Find the current chapter (checkpoint) based on playback position
 * Returns the last checkpoint at or before the current time
 * @param checkpoints - Array of checkpoints
 * @param currentTimeMs - Current playback position in milliseconds
 * @returns Current checkpoint or null if none found
 */
export function findCurrentChapter(
  checkpoints: VideoCheckpoint[],
  currentTimeMs: number
): VideoCheckpoint | null {
  if (!checkpoints.length) return null;

  // Sort descending to find the most recent checkpoint at or before current time
  const sorted = [...checkpoints].sort((a, b) => b.timestampMs - a.timestampMs);
  return sorted.find((cp) => cp.timestampMs <= currentTimeMs) ?? null;
}

/**
 * Calculate progress percentage for timeline
 * @param currentTimeMs - Current playback position in milliseconds
 * @param durationMs - Total duration in milliseconds
 * @returns Progress percentage (0-100)
 */
export function calculateProgress(
  currentTimeMs: number,
  durationMs: number
): number {
  if (durationMs <= 0) return 0;
  return Math.min(100, Math.max(0, (currentTimeMs / durationMs) * 100));
}

/**
 * Calculate checkpoint position on timeline as percentage
 * @param timestampMs - Checkpoint timestamp in milliseconds
 * @param durationMs - Total duration in milliseconds
 * @returns Position percentage (0-100)
 */
export function calculateCheckpointPosition(
  timestampMs: number,
  durationMs: number
): number {
  if (durationMs <= 0) return 0;
  return Math.min(100, Math.max(0, (timestampMs / durationMs) * 100));
}
