import { expect, test } from "bun:test";
import { finishedPromptUpload, receivePromptUploadState, type PromptUploadState } from "./promptUploadState";

const finished = (token: string): PromptUploadState => ({ token, uploadId: "daemon-id", state: "finished", size: 3 });
const deferred = () => {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => (resolve = done));
  return { promise, resolve };
};

test("terminal state can arrive before begin answers", async () => {
  const begin = deferred();
  const result = finishedPromptUpload(
    "early",
    3,
    () => begin.promise,
    async () => finished("early"),
  );
  receivePromptUploadState(finished("early"));
  expect(await result).toEqual({ uploadId: "daemon-id", size: 3, offset: 3 });
  begin.resolve();
});

test("100 percent progress and pending status do not finish an upload", async () => {
  let done = false;
  const result = finishedPromptUpload(
    "pending",
    3,
    async () => ({ uploadId: "daemon-id" }),
    async () => ({ token: "pending", state: "uploading", size: 3 }),
  ).then((value) => {
    done = true;
    return value;
  });
  receivePromptUploadState({ token: "pending", uploadId: "daemon-id", offset: 3, size: 3 });
  await Promise.resolve();
  await Promise.resolve();
  expect(done).toBe(false);
  receivePromptUploadState(finished("pending"));
  expect((await result).uploadId).toBe("daemon-id");
});

test("status recovers a lost terminal push", async () => {
  const result = await finishedPromptUpload(
    "lost",
    3,
    async () => ({}),
    async () => finished("lost"),
  );
  expect(result.uploadId).toBe("daemon-id");
});

test("terminal failures retain native details and never fabricate an upload id", async () => {
  for (const state of ["failed", "cancelled", "finished"] as const) {
    const error = { code: "disk_full", message: "Disk full", host: "host", path: "/volume" };
    const result = finishedPromptUpload(
      state,
      3,
      async () => ({}),
      async () => ({ token: state, state, size: 3, ...(state === "failed" ? { error } : {}) }),
    );
    await expect(result).rejects.toMatchObject(
      state === "finished" ? { code: "upload.noId" } : state === "failed" ? error : { message: "Upload cancelled" },
    );
  }
});

test("the shared page host delegates terminal upload events", async () => {
  const { JSDOM } = await import("jsdom");
  const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  const scope = globalThis as Record<string, unknown>;
  const previous = { window: scope.window, document: scope.document };
  Object.assign(scope, { window: dom.window, document: dom.window.document });
  try {
    const { applyHostEvent } = await import("./pageHost");
    const begin = deferred();
    const result = finishedPromptUpload(
      "host-event",
      3,
      () => begin.promise,
      async () => finished("host-event"),
    );
    applyHostEvent({ kind: "uploads.state", value: finished("host-event") });
    expect((await result).uploadId).toBe("daemon-id");
    begin.resolve();
  } finally {
    Object.assign(scope, previous);
    dom.window.close();
  }
});
