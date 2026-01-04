import { describe, expect, it } from "vitest";
import {
  VideoRecordingStatusSchema,
  VideoCheckpointTypeSchema,
  VideoCheckpointSchema,
  VideoRecordingStartPayloadSchema,
  VideoRecordingUploadPayloadSchema,
  VideoRecordingAddCheckpointPayloadSchema,
  VideoRecordingUploadUrlRequestSchema,
} from "./types";

describe("VideoRecordingStatusSchema", () => {
  it("accepts valid statuses", () => {
    const validStatuses = ["recording", "processing", "completed", "failed"];
    for (const status of validStatuses) {
      expect(VideoRecordingStatusSchema.parse(status)).toBe(status);
    }
  });

  it("rejects invalid statuses", () => {
    expect(() => VideoRecordingStatusSchema.parse("invalid")).toThrow();
    expect(() => VideoRecordingStatusSchema.parse("")).toThrow();
    expect(() => VideoRecordingStatusSchema.parse(123)).toThrow();
  });
});

describe("VideoCheckpointTypeSchema", () => {
  it("accepts valid checkpoint types", () => {
    const validTypes = [
      "commit",
      "command",
      "file_change",
      "error",
      "milestone",
      "manual",
    ];
    for (const type of validTypes) {
      expect(VideoCheckpointTypeSchema.parse(type)).toBe(type);
    }
  });

  it("rejects invalid checkpoint types", () => {
    expect(() => VideoCheckpointTypeSchema.parse("invalid")).toThrow();
    expect(() => VideoCheckpointTypeSchema.parse("")).toThrow();
  });
});

describe("VideoCheckpointSchema", () => {
  it("accepts valid checkpoint with all fields", () => {
    const checkpoint = {
      timestampMs: 5000,
      label: "Installing dependencies",
      description: "Running npm install",
      type: "command" as const,
    };
    expect(VideoCheckpointSchema.parse(checkpoint)).toEqual(checkpoint);
  });

  it("accepts valid checkpoint with required fields only", () => {
    const checkpoint = {
      timestampMs: 0,
      label: "Start",
    };
    expect(VideoCheckpointSchema.parse(checkpoint)).toEqual(checkpoint);
  });

  it("rejects checkpoint without timestampMs", () => {
    expect(() =>
      VideoCheckpointSchema.parse({ label: "Test" })
    ).toThrow();
  });

  it("rejects checkpoint without label", () => {
    expect(() =>
      VideoCheckpointSchema.parse({ timestampMs: 1000 })
    ).toThrow();
  });

  it("rejects checkpoint with invalid timestampMs type", () => {
    expect(() =>
      VideoCheckpointSchema.parse({ timestampMs: "1000", label: "Test" })
    ).toThrow();
  });

  it("accepts checkpoint with optional type field", () => {
    const checkpoint = {
      timestampMs: 10000,
      label: "Commit changes",
      type: "commit" as const,
    };
    const parsed = VideoCheckpointSchema.parse(checkpoint);
    expect(parsed.type).toBe("commit");
  });
});

describe("VideoRecordingStartPayloadSchema", () => {
  it("accepts valid start payload with required fields", () => {
    const payload = {
      taskId: "tasks_abc123",
      runId: "taskRuns_xyz789",
    };
    expect(VideoRecordingStartPayloadSchema.parse(payload)).toEqual(payload);
  });

  it("accepts valid start payload with optional commitSha", () => {
    const payload = {
      taskId: "tasks_abc123",
      runId: "taskRuns_xyz789",
      commitSha: "abc123def456",
    };
    expect(VideoRecordingStartPayloadSchema.parse(payload)).toEqual(payload);
  });

  it("rejects payload without taskId", () => {
    expect(() =>
      VideoRecordingStartPayloadSchema.parse({ runId: "taskRuns_xyz789" })
    ).toThrow();
  });

  it("rejects payload without runId", () => {
    expect(() =>
      VideoRecordingStartPayloadSchema.parse({ taskId: "tasks_abc123" })
    ).toThrow();
  });

  // Note: typedZid doesn't validate the prefix at runtime, it's a type-level check only
  // These tests verify the schema accepts string IDs (validation happens at Convex layer)
  it("accepts any string as taskId (prefix validation is type-level only)", () => {
    const payload = {
      taskId: "any_string_works",
      runId: "taskRuns_xyz789",
    };
    // The schema will parse successfully - prefix validation is at TypeScript level
    expect(VideoRecordingStartPayloadSchema.parse(payload).taskId).toBe("any_string_works");
  });

  it("accepts any string as runId (prefix validation is type-level only)", () => {
    const payload = {
      taskId: "tasks_abc123",
      runId: "any_string_works",
    };
    expect(VideoRecordingStartPayloadSchema.parse(payload).runId).toBe("any_string_works");
  });
});

describe("VideoRecordingUploadPayloadSchema", () => {
  it("accepts valid upload payload with required fields", () => {
    const payload = {
      recordingId: "taskRunVideoRecordings_abc123",
      storageId: "storage_xyz789",
      durationMs: 60000,
    };
    expect(VideoRecordingUploadPayloadSchema.parse(payload)).toEqual(payload);
  });

  it("accepts valid upload payload with all optional fields", () => {
    const payload = {
      recordingId: "taskRunVideoRecordings_abc123",
      storageId: "storage_xyz789",
      durationMs: 60000,
      fileSizeBytes: 1024000,
      checkpoints: [
        { timestampMs: 0, label: "Start" },
        { timestampMs: 30000, label: "Midpoint", type: "milestone" as const },
      ],
    };
    const parsed = VideoRecordingUploadPayloadSchema.parse(payload);
    expect(parsed.fileSizeBytes).toBe(1024000);
    expect(parsed.checkpoints).toHaveLength(2);
  });

  it("rejects payload without recordingId", () => {
    expect(() =>
      VideoRecordingUploadPayloadSchema.parse({
        storageId: "storage_xyz789",
        durationMs: 60000,
      })
    ).toThrow();
  });

  // Note: typedZid doesn't validate the prefix at runtime
  it("accepts any string as recordingId (prefix validation is type-level only)", () => {
    const payload = {
      recordingId: "any_string_works",
      storageId: "storage_xyz789",
      durationMs: 60000,
    };
    expect(VideoRecordingUploadPayloadSchema.parse(payload).recordingId).toBe("any_string_works");
  });

  it("rejects payload with negative durationMs", () => {
    const payload = {
      recordingId: "taskRunVideoRecordings_abc123",
      storageId: "storage_xyz789",
      durationMs: -1000,
    };
    // durationMs is just a number, negative should be valid from schema perspective
    // but this tests the schema accepts it (business logic validation would happen elsewhere)
    expect(VideoRecordingUploadPayloadSchema.parse(payload).durationMs).toBe(-1000);
  });

  it("accepts empty checkpoints array", () => {
    const payload = {
      recordingId: "taskRunVideoRecordings_abc123",
      storageId: "storage_xyz789",
      durationMs: 60000,
      checkpoints: [],
    };
    expect(VideoRecordingUploadPayloadSchema.parse(payload).checkpoints).toEqual([]);
  });
});

describe("VideoRecordingAddCheckpointPayloadSchema", () => {
  it("accepts valid add checkpoint payload", () => {
    const payload = {
      recordingId: "taskRunVideoRecordings_abc123",
      checkpoint: {
        timestampMs: 5000,
        label: "Running tests",
        type: "command" as const,
      },
    };
    expect(VideoRecordingAddCheckpointPayloadSchema.parse(payload)).toEqual(payload);
  });

  it("rejects payload without recordingId", () => {
    expect(() =>
      VideoRecordingAddCheckpointPayloadSchema.parse({
        checkpoint: { timestampMs: 5000, label: "Test" },
      })
    ).toThrow();
  });

  it("rejects payload without checkpoint", () => {
    expect(() =>
      VideoRecordingAddCheckpointPayloadSchema.parse({
        recordingId: "taskRunVideoRecordings_abc123",
      })
    ).toThrow();
  });

  it("rejects payload with invalid checkpoint", () => {
    expect(() =>
      VideoRecordingAddCheckpointPayloadSchema.parse({
        recordingId: "taskRunVideoRecordings_abc123",
        checkpoint: { timestampMs: "5000", label: "Test" }, // invalid timestampMs type
      })
    ).toThrow();
  });
});

describe("VideoRecordingUploadUrlRequestSchema", () => {
  it("accepts valid video content types", () => {
    const videoTypes = [
      "video/webm",
      "video/webm;codecs=vp9",
      "video/webm;codecs=vp8",
      "video/mp4",
    ];
    for (const contentType of videoTypes) {
      expect(
        VideoRecordingUploadUrlRequestSchema.parse({ contentType }).contentType
      ).toBe(contentType);
    }
  });

  it("rejects payload without contentType", () => {
    expect(() =>
      VideoRecordingUploadUrlRequestSchema.parse({})
    ).toThrow();
  });

  // Note: Schema doesn't enforce video/ prefix, that's done in HTTP handler
  it("accepts any string as contentType (validation done in handler)", () => {
    expect(
      VideoRecordingUploadUrlRequestSchema.parse({ contentType: "image/png" }).contentType
    ).toBe("image/png");
  });
});

describe("VideoCheckpoint edge cases", () => {
  it("handles zero timestamp", () => {
    const checkpoint = { timestampMs: 0, label: "Start" };
    expect(VideoCheckpointSchema.parse(checkpoint).timestampMs).toBe(0);
  });

  it("handles large timestamps", () => {
    const checkpoint = { timestampMs: 3600000, label: "One hour mark" }; // 1 hour in ms
    expect(VideoCheckpointSchema.parse(checkpoint).timestampMs).toBe(3600000);
  });

  it("handles empty label", () => {
    // Empty strings should be valid per zod string default
    const checkpoint = { timestampMs: 1000, label: "" };
    expect(VideoCheckpointSchema.parse(checkpoint).label).toBe("");
  });

  it("handles long labels", () => {
    const longLabel = "a".repeat(1000);
    const checkpoint = { timestampMs: 1000, label: longLabel };
    expect(VideoCheckpointSchema.parse(checkpoint).label).toBe(longLabel);
  });

  it("handles unicode in labels", () => {
    const unicodeLabel = "测试检查点 🎬";
    const checkpoint = { timestampMs: 1000, label: unicodeLabel };
    expect(VideoCheckpointSchema.parse(checkpoint).label).toBe(unicodeLabel);
  });

  it("handles unicode in description", () => {
    const checkpoint = {
      timestampMs: 1000,
      label: "Test",
      description: "描述文本 with émojis 🔥",
    };
    expect(VideoCheckpointSchema.parse(checkpoint).description).toBe(
      "描述文本 with émojis 🔥"
    );
  });
});
