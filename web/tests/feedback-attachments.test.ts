import { describe, expect, test } from "bun:test";

import { prepareFeedbackAttachments } from "../services/feedbackAttachments";

describe("feedback attachments", () => {
  test("accepts one diagnostics text attachment alongside image attachments", async () => {
    const result = await prepareFeedbackAttachments(
      [
        new File(["image"], "photo.jpg", { type: "image/jpeg" }),
      ],
      [
        new File(["cmux diagnostics"], "cmux-diagnostics.txt", { type: "text/plain" }),
      ],
    );

    expect("attachments" in result).toBe(true);
    if (!("attachments" in result)) {
      throw new Error("expected prepared attachments");
    }

    expect(result.attachments.map((attachment) => ({
      contentType: attachment.contentType,
      filename: attachment.filename,
      kind: attachment.kind,
      size: attachment.size,
    }))).toEqual([
      {
        contentType: "text/plain",
        filename: "cmux-diagnostics.txt",
        kind: "diagnostics",
        size: 16,
      },
      {
        contentType: "image/jpeg",
        filename: "photo.jpg",
        kind: "image",
        size: 5,
      },
    ]);
  });

  test("rejects more than one diagnostics attachment", async () => {
    const result = await prepareFeedbackAttachments(
      [],
      [
        new File(["one"], "one.txt", { type: "text/plain" }),
        new File(["two"], "two.txt", { type: "text/plain" }),
      ],
    );

    expect("error" in result).toBe(true);
    if (!("error" in result)) {
      throw new Error("expected an error");
    }
    expect(result.error.status).toBe(400);
    expect(result.error.code).toBe("ERROR_TOO_MANY_DIAGNOSTICS");
  });

  test("rejects non-text diagnostics attachments", async () => {
    const result = await prepareFeedbackAttachments(
      [],
      [
        new File(["{}"], "diagnostics.json", { type: "application/json" }),
      ],
    );

    expect("error" in result).toBe(true);
    if (!("error" in result)) {
      throw new Error("expected an error");
    }
    expect(result.error.status).toBe(415);
    expect(result.error.code).toBe("ERROR_UNSUPPORTED_DIAGNOSTICS_TYPE");
  });

  test("rejects malformed attachment parts", async () => {
    const result = await prepareFeedbackAttachments(
      ["not-a-file"],
      [
        new File(["cmux diagnostics"], "cmux-diagnostics.txt", { type: "text/plain" }),
      ],
    );

    expect("error" in result).toBe(true);
    if (!("error" in result)) {
      throw new Error("expected an error");
    }
    expect(result.error.status).toBe(400);
    expect(result.error.code).toBe("ERROR_INVALID_IMAGE_ATTACHMENT");
  });
});
