import { describe, expect, it } from "vitest";
import {
  formatTime,
  formatDuration,
  formatFileSize,
  getCheckpointIcon,
  getCheckpointColor,
  sortCheckpointsByTime,
  findCurrentChapter,
  calculateProgress,
  calculateCheckpointPosition,
} from "./video-utils";
import type { VideoCheckpoint } from "./types";

describe("formatTime", () => {
  it("formats zero milliseconds", () => {
    expect(formatTime(0)).toBe("0:00");
  });

  it("formats seconds only", () => {
    expect(formatTime(5000)).toBe("0:05");
    expect(formatTime(30000)).toBe("0:30");
    expect(formatTime(59000)).toBe("0:59");
  });

  it("formats minutes and seconds", () => {
    expect(formatTime(60000)).toBe("1:00");
    expect(formatTime(65000)).toBe("1:05");
    expect(formatTime(125000)).toBe("2:05");
    expect(formatTime(599000)).toBe("9:59");
    expect(formatTime(3540000)).toBe("59:00");
    expect(formatTime(3599000)).toBe("59:59");
  });

  it("formats hours, minutes and seconds", () => {
    expect(formatTime(3600000)).toBe("1:00:00"); // 1 hour
    expect(formatTime(3665000)).toBe("1:01:05"); // 1h 1m 5s
    expect(formatTime(7200000)).toBe("2:00:00"); // 2 hours
    expect(formatTime(36000000)).toBe("10:00:00"); // 10 hours
  });

  it("pads minutes and seconds with leading zeros", () => {
    expect(formatTime(61000)).toBe("1:01");
    expect(formatTime(3661000)).toBe("1:01:01");
    expect(formatTime(3601000)).toBe("1:00:01");
  });

  it("handles fractional milliseconds by truncating", () => {
    expect(formatTime(1500)).toBe("0:01"); // 1.5 seconds -> 1 second
    expect(formatTime(59999)).toBe("0:59"); // just under 60 seconds
  });

  it("handles large durations", () => {
    expect(formatTime(86400000)).toBe("24:00:00"); // 24 hours
    expect(formatTime(360000000)).toBe("100:00:00"); // 100 hours
  });
});

describe("formatDuration", () => {
  it("is an alias for formatTime", () => {
    // Verify it produces the same output
    expect(formatDuration(0)).toBe(formatTime(0));
    expect(formatDuration(60000)).toBe(formatTime(60000));
    expect(formatDuration(3665000)).toBe(formatTime(3665000));
  });
});

describe("formatFileSize", () => {
  it("formats bytes", () => {
    expect(formatFileSize(0)).toBe("0 B");
    expect(formatFileSize(500)).toBe("500 B");
    expect(formatFileSize(1023)).toBe("1023 B");
  });

  it("formats kilobytes", () => {
    expect(formatFileSize(1024)).toBe("1.0 KB");
    expect(formatFileSize(1536)).toBe("1.5 KB");
    expect(formatFileSize(10240)).toBe("10.0 KB");
    expect(formatFileSize(1048575)).toBe("1024.0 KB"); // Just under 1MB
  });

  it("formats megabytes", () => {
    expect(formatFileSize(1048576)).toBe("1.0 MB"); // Exactly 1MB
    expect(formatFileSize(1572864)).toBe("1.5 MB"); // 1.5MB
    expect(formatFileSize(10485760)).toBe("10.0 MB"); // 10MB
    expect(formatFileSize(104857600)).toBe("100.0 MB"); // 100MB
    expect(formatFileSize(1073741824)).toBe("1024.0 MB"); // 1GB in MB
  });

  it("handles decimal precision", () => {
    expect(formatFileSize(1536)).toBe("1.5 KB");
    expect(formatFileSize(1843)).toBe("1.8 KB");
    expect(formatFileSize(2048000)).toBe("2.0 MB");
  });
});

describe("getCheckpointIcon", () => {
  it("returns correct icon for each type", () => {
    expect(getCheckpointIcon("commit")).toBe("📝");
    expect(getCheckpointIcon("command")).toBe("⚡");
    expect(getCheckpointIcon("file_change")).toBe("📄");
    expect(getCheckpointIcon("error")).toBe("❌");
    expect(getCheckpointIcon("milestone")).toBe("🎯");
    expect(getCheckpointIcon("manual")).toBe("📌");
  });

  it("returns default icon for undefined type", () => {
    expect(getCheckpointIcon(undefined)).toBe("📍");
  });

  it("returns default icon for null/unknown type", () => {
    expect(getCheckpointIcon(null as unknown as undefined)).toBe("📍");
    expect(getCheckpointIcon("unknown" as unknown as undefined)).toBe("📍");
  });
});

describe("getCheckpointColor", () => {
  it("returns correct color class for each type", () => {
    expect(getCheckpointColor("commit")).toBe("bg-emerald-500");
    expect(getCheckpointColor("command")).toBe("bg-blue-500");
    expect(getCheckpointColor("file_change")).toBe("bg-amber-500");
    expect(getCheckpointColor("error")).toBe("bg-red-500");
    expect(getCheckpointColor("milestone")).toBe("bg-purple-500");
    expect(getCheckpointColor("manual")).toBe("bg-neutral-500");
  });

  it("returns default color for undefined type", () => {
    expect(getCheckpointColor(undefined)).toBe("bg-neutral-400");
  });

  it("returns default color for null/unknown type", () => {
    expect(getCheckpointColor(null as unknown as undefined)).toBe("bg-neutral-400");
    expect(getCheckpointColor("unknown" as unknown as undefined)).toBe("bg-neutral-400");
  });
});

describe("sortCheckpointsByTime", () => {
  it("returns empty array for empty input", () => {
    expect(sortCheckpointsByTime([])).toEqual([]);
  });

  it("returns single item array unchanged", () => {
    const checkpoints: VideoCheckpoint[] = [
      { timestampMs: 1000, label: "Start" },
    ];
    expect(sortCheckpointsByTime(checkpoints)).toEqual(checkpoints);
  });

  it("sorts checkpoints in ascending order by timestamp", () => {
    const checkpoints: VideoCheckpoint[] = [
      { timestampMs: 3000, label: "Third" },
      { timestampMs: 1000, label: "First" },
      { timestampMs: 2000, label: "Second" },
    ];
    const sorted = sortCheckpointsByTime(checkpoints);
    expect(sorted[0].label).toBe("First");
    expect(sorted[1].label).toBe("Second");
    expect(sorted[2].label).toBe("Third");
  });

  it("does not mutate original array", () => {
    const checkpoints: VideoCheckpoint[] = [
      { timestampMs: 3000, label: "Third" },
      { timestampMs: 1000, label: "First" },
    ];
    const sorted = sortCheckpointsByTime(checkpoints);
    expect(checkpoints[0].label).toBe("Third"); // Original unchanged
    expect(sorted[0].label).toBe("First");
  });

  it("handles checkpoints with same timestamp", () => {
    const checkpoints: VideoCheckpoint[] = [
      { timestampMs: 1000, label: "A" },
      { timestampMs: 1000, label: "B" },
    ];
    const sorted = sortCheckpointsByTime(checkpoints);
    expect(sorted).toHaveLength(2);
    // Order of equal elements depends on sort stability
  });

  it("handles zero timestamps", () => {
    const checkpoints: VideoCheckpoint[] = [
      { timestampMs: 1000, label: "After" },
      { timestampMs: 0, label: "Start" },
    ];
    const sorted = sortCheckpointsByTime(checkpoints);
    expect(sorted[0].label).toBe("Start");
    expect(sorted[0].timestampMs).toBe(0);
  });
});

describe("findCurrentChapter", () => {
  const checkpoints: VideoCheckpoint[] = [
    { timestampMs: 0, label: "Start" },
    { timestampMs: 10000, label: "Introduction" },
    { timestampMs: 30000, label: "Main content" },
    { timestampMs: 60000, label: "Conclusion" },
  ];

  it("returns null for empty checkpoints", () => {
    expect(findCurrentChapter([], 5000)).toBeNull();
  });

  it("returns first checkpoint when at start", () => {
    expect(findCurrentChapter(checkpoints, 0)?.label).toBe("Start");
  });

  it("returns the checkpoint at exactly that timestamp", () => {
    expect(findCurrentChapter(checkpoints, 10000)?.label).toBe("Introduction");
    expect(findCurrentChapter(checkpoints, 30000)?.label).toBe("Main content");
  });

  it("returns the most recent checkpoint before current time", () => {
    expect(findCurrentChapter(checkpoints, 5000)?.label).toBe("Start");
    expect(findCurrentChapter(checkpoints, 15000)?.label).toBe("Introduction");
    expect(findCurrentChapter(checkpoints, 45000)?.label).toBe("Main content");
    expect(findCurrentChapter(checkpoints, 90000)?.label).toBe("Conclusion");
  });

  it("returns null when before all checkpoints", () => {
    const laterCheckpoints: VideoCheckpoint[] = [
      { timestampMs: 10000, label: "First" },
    ];
    expect(findCurrentChapter(laterCheckpoints, 5000)).toBeNull();
  });

  it("handles unsorted checkpoints", () => {
    const unsorted: VideoCheckpoint[] = [
      { timestampMs: 30000, label: "C" },
      { timestampMs: 10000, label: "A" },
      { timestampMs: 20000, label: "B" },
    ];
    expect(findCurrentChapter(unsorted, 15000)?.label).toBe("A");
    expect(findCurrentChapter(unsorted, 25000)?.label).toBe("B");
  });
});

describe("calculateProgress", () => {
  it("returns 0 for zero duration", () => {
    expect(calculateProgress(5000, 0)).toBe(0);
  });

  it("returns 0 for negative duration", () => {
    expect(calculateProgress(5000, -1000)).toBe(0);
  });

  it("returns 0 for zero current time", () => {
    expect(calculateProgress(0, 60000)).toBe(0);
  });

  it("calculates correct percentage", () => {
    expect(calculateProgress(30000, 60000)).toBe(50);
    expect(calculateProgress(15000, 60000)).toBe(25);
    expect(calculateProgress(45000, 60000)).toBe(75);
  });

  it("returns 100 at end", () => {
    expect(calculateProgress(60000, 60000)).toBe(100);
  });

  it("caps at 100 when current time exceeds duration", () => {
    expect(calculateProgress(70000, 60000)).toBe(100);
  });

  it("returns 0 for negative current time", () => {
    expect(calculateProgress(-1000, 60000)).toBe(0);
  });

  it("handles floating point precision", () => {
    const progress = calculateProgress(20000, 60000);
    expect(progress).toBeCloseTo(33.333, 2);
  });
});

describe("calculateCheckpointPosition", () => {
  it("returns 0 for zero duration", () => {
    expect(calculateCheckpointPosition(5000, 0)).toBe(0);
  });

  it("returns 0 for negative duration", () => {
    expect(calculateCheckpointPosition(5000, -1000)).toBe(0);
  });

  it("calculates correct position", () => {
    expect(calculateCheckpointPosition(0, 60000)).toBe(0);
    expect(calculateCheckpointPosition(30000, 60000)).toBe(50);
    expect(calculateCheckpointPosition(60000, 60000)).toBe(100);
  });

  it("caps at 100 when timestamp exceeds duration", () => {
    expect(calculateCheckpointPosition(70000, 60000)).toBe(100);
  });

  it("returns 0 for negative timestamp", () => {
    expect(calculateCheckpointPosition(-1000, 60000)).toBe(0);
  });
});

describe("integration: video timeline", () => {
  it("correctly calculates chapter positions on timeline", () => {
    const duration = 120000; // 2 minutes
    const checkpoints: VideoCheckpoint[] = [
      { timestampMs: 0, label: "Intro" },
      { timestampMs: 30000, label: "Setup" },
      { timestampMs: 60000, label: "Demo" },
      { timestampMs: 90000, label: "Summary" },
    ];

    // Verify positions
    expect(calculateCheckpointPosition(checkpoints[0].timestampMs, duration)).toBe(0);
    expect(calculateCheckpointPosition(checkpoints[1].timestampMs, duration)).toBe(25);
    expect(calculateCheckpointPosition(checkpoints[2].timestampMs, duration)).toBe(50);
    expect(calculateCheckpointPosition(checkpoints[3].timestampMs, duration)).toBe(75);
  });

  it("correctly identifies current chapter during playback", () => {
    const checkpoints: VideoCheckpoint[] = [
      { timestampMs: 0, label: "Intro", type: "milestone" },
      { timestampMs: 30000, label: "Installing deps", type: "command" },
      { timestampMs: 45000, label: "Config change", type: "file_change" },
      { timestampMs: 60000, label: "First commit", type: "commit" },
    ];

    // Simulate playback at different times
    expect(findCurrentChapter(checkpoints, 0)?.type).toBe("milestone");
    expect(findCurrentChapter(checkpoints, 20000)?.type).toBe("milestone");
    expect(findCurrentChapter(checkpoints, 35000)?.type).toBe("command");
    expect(findCurrentChapter(checkpoints, 50000)?.type).toBe("file_change");
    expect(findCurrentChapter(checkpoints, 70000)?.type).toBe("commit");
  });

  it("formats video metadata consistently", () => {
    const recording = {
      durationMs: 185000, // 3:05
      fileSizeBytes: 15728640, // 15MB
    };

    expect(formatDuration(recording.durationMs)).toBe("3:05");
    expect(formatFileSize(recording.fileSizeBytes)).toBe("15.0 MB");
  });
});
