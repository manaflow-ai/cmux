import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { CDPSession } from "playwright";

/** Raw Chromium timeline; separate from the CDP CPU-counter summary. */
export async function startRawTrace(cdp: CDPSession, directory: string, id: string) {
  fs.mkdirSync(directory, { recursive: true });
  await cdp.send("Tracing.start", {
    categories: "devtools.timeline,blink.user_timing,v8,disabled-by-default-devtools.timeline",
    transferMode: "ReturnAsStream",
  });
  return async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    let onComplete: ((event: { stream?: string }) => void) | undefined;
    const completed = new Promise<string>((resolve, reject) => {
      onComplete = (event) => {
        if (event.stream) resolve(event.stream);
        else reject(new Error("Chromium did not return a raw trace stream"));
      };
      cdp.once("Tracing.tracingComplete", onComplete);
      timer = setTimeout(() => reject(new Error("raw Chromium trace did not finish within 30 seconds")), 30_000);
    });
    // Own the rejection even if Tracing.end itself fails or never replies.
    void completed.catch(() => undefined);
    let handle: string;
    try {
      await cdp.send("Tracing.end");
      handle = await completed;
    } finally {
      if (timer) clearTimeout(timer);
      if (onComplete) cdp.removeListener("Tracing.tracingComplete", onComplete);
    }
    const name = `${id.replace(/[^a-zA-Z0-9._-]/g, "_")}.trace.json`;
    const file = path.join(directory, name);
    const hash = createHash("sha256");
    const fd = fs.openSync(file, "w");
    let bytes = 0;
    try {
      while (true) {
        const chunk = await cdp.send("IO.read", { handle, size: 1024 * 1024 });
        const data = Buffer.from(chunk.data, chunk.base64Encoded ? "base64" : "utf8");
        fs.writeSync(fd, data);
        hash.update(data);
        bytes += data.length;
        if (chunk.eof) break;
      }
    } finally {
      fs.closeSync(fd);
      await cdp.send("IO.close", { handle });
    }
    if (!bytes) throw new Error("Chromium returned an empty raw trace");
    return {
      path: name,
      bytes,
      sha256: hash.digest("hex"),
      source: "CDP Tracing timeline; action preparation, input, rendering and control work",
    };
  };
}
