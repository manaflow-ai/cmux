import { describe, expect, test } from "bun:test";
import {
  EditorSaveController,
  type EditorSaveBridgeReply,
  type EditorSaveDocument,
  type EditorSaveRequest,
} from "../src/editor/saveController";

/** Minimal in-memory stand-in for the live Monaco model. */
function makeDocument(
  initial: string,
): EditorSaveDocument & { content: string; edit: (content: string) => void } {
  const document = {
    content: initial,
    versionId: 1,
    getValue() {
      return document.content;
    },
    getVersionId() {
      return document.versionId;
    },
    replaceWith(content: string) {
      document.content = content;
      document.versionId += 1;
      return document.versionId;
    },
    edit(content: string) {
      document.content = content;
      document.versionId += 1;
    },
  };
  return document;
}

function makeBridge(replies: EditorSaveBridgeReply[]) {
  const requests: EditorSaveRequest[] = [];
  const bridge = (request: EditorSaveRequest): Promise<EditorSaveBridgeReply> => {
    requests.push(request);
    const reply = replies.shift();
    if (!reply) {
      throw new Error("unexpected save request");
    }
    return Promise.resolve(reply);
  };
  return { bridge, requests };
}

async function settle(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

describe("EditorSaveController.adoptDiskContent", () => {
  test("replaces the buffer, clears dirty state, and re-baselines the conflict sha", async () => {
    const document = makeDocument("buffer");
    const { bridge, requests } = makeBridge([{ status: "saved", sha256: "sha-after-save" }]);
    const controller = new EditorSaveController({ bridge, baselineSha256: "sha-original" });
    controller.attachDocument(document);

    document.edit("buffer edited");
    controller.noteContentChanged();
    expect(controller.getState().dirty).toBe(true);

    controller.adoptDiskContent("disk content", "sha-disk");
    expect(document.content).toBe("disk content");
    expect(controller.getState().dirty).toBe(false);
    expect(controller.getState().conflict).toBeNull();

    // The next save carries the adopted disk sha as its baseline.
    document.edit("disk content edited");
    controller.noteContentChanged();
    controller.requestSave();
    await settle();
    expect(requests).toHaveLength(1);
    expect(requests[0]?.expectedSha256).toBe("sha-disk");
  });

  test("clears a pending conflict and save-error state", async () => {
    const document = makeDocument("buffer");
    const { bridge } = makeBridge([
      { status: "conflict", diskSha256: "sha-disk", diskContent: "disk content" },
    ]);
    const controller = new EditorSaveController({ bridge, baselineSha256: "sha-original" });
    controller.attachDocument(document);

    document.edit("buffer edited");
    controller.noteContentChanged();
    controller.requestSave();
    await settle();
    expect(controller.getState().conflict).not.toBeNull();

    controller.adoptDiskContent("disk content", "sha-disk");
    expect(controller.getState().conflict).toBeNull();
    expect(controller.getState().status).toBe("idle");
    expect(controller.getState().dirty).toBe(false);
  });

  test("same-text adoption re-baselines the sha without replacing the buffer", async () => {
    const document = makeDocument("same text");
    const { bridge, requests } = makeBridge([{ status: "saved", sha256: "sha-final" }]);
    const controller = new EditorSaveController({ bridge, baselineSha256: "sha-old-bytes" });
    controller.attachDocument(document);
    const versionBefore = document.getVersionId();

    // External rewrite with identical text but different bytes/encoding.
    controller.adoptDiskContent("same text", "sha-new-bytes");
    expect(document.getVersionId()).toBe(versionBefore);
    expect(controller.getState().dirty).toBe(false);

    document.edit("same text edited");
    controller.noteContentChanged();
    controller.requestSave();
    await settle();
    expect(requests[0]?.expectedSha256).toBe("sha-new-bytes");
  });

  test("fully identical adoption is a no-op that preserves saved status", async () => {
    const document = makeDocument("text");
    const { bridge } = makeBridge([{ status: "saved", sha256: "sha-saved" }]);
    const controller = new EditorSaveController({ bridge, baselineSha256: "sha-orig" });
    controller.attachDocument(document);

    document.edit("text v2");
    controller.noteContentChanged();
    controller.requestSave();
    await settle();
    expect(controller.getState().status).toBe("saved");

    // The host's own save echo: same content, same sha.
    controller.adoptDiskContent("text v2", "sha-saved");
    expect(controller.getState().status).toBe("saved");
    expect(controller.getState().dirty).toBe(false);
  });

  test("a page seeded from an unsaved buffer boots dirty until saved", async () => {
    const document = makeDocument("unsaved buffer");
    const { bridge, requests } = makeBridge([{ status: "saved", sha256: "sha-final" }]);
    const controller = new EditorSaveController({
      bridge,
      baselineSha256: "sha-disk",
      initiallyDirty: true,
    });
    controller.attachDocument(document);
    expect(controller.getState().dirty).toBe(true);

    // The host's boot-time sync (same content, same sha) must not clear it.
    controller.adoptDiskContent("unsaved buffer", "sha-disk");
    expect(controller.getState().dirty).toBe(true);

    controller.requestSave();
    await settle();
    expect(requests).toHaveLength(1);
    expect(requests[0]?.expectedSha256).toBe("sha-disk");
    expect(controller.getState().dirty).toBe(false);
    expect(controller.getState().status).toBe("saved");
  });

  test("a real disk adoption clears the seeded-dirty state", () => {
    const document = makeDocument("unsaved buffer");
    const controller = new EditorSaveController({
      bridge: null,
      baselineSha256: "sha-disk",
      initiallyDirty: true,
    });
    controller.attachDocument(document);
    expect(controller.getState().dirty).toBe(true);

    controller.adoptDiskContent("disk content", "sha-new-disk");
    expect(document.content).toBe("disk content");
    expect(controller.getState().dirty).toBe(false);
  });

  test("is a no-op before a document is attached", () => {
    const controller = new EditorSaveController({ bridge: null, baselineSha256: null });

    controller.adoptDiskContent("disk content", "sha-disk");
    expect(controller.getState().dirty).toBe(false);
  });

  test("use-disk conflict resolution routes through the same adoption", async () => {
    const document = makeDocument("buffer");
    const { bridge, requests } = makeBridge([
      { status: "conflict", diskSha256: "sha-disk", diskContent: "disk content" },
      { status: "saved", sha256: "sha-final" },
    ]);
    const controller = new EditorSaveController({ bridge, baselineSha256: "sha-original" });
    controller.attachDocument(document);

    document.edit("buffer edited");
    controller.noteContentChanged();
    controller.requestSave();
    await settle();

    controller.resolveConflictUseDisk();
    expect(document.content).toBe("disk content");
    expect(controller.getState().conflict).toBeNull();
    expect(controller.getState().dirty).toBe(false);

    document.edit("disk content edited");
    controller.noteContentChanged();
    controller.requestSave();
    await settle();
    expect(requests).toHaveLength(2);
    expect(requests[1]?.expectedSha256).toBe("sha-disk");
  });
});
