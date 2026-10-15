import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { FrameKind } from "../src/protocol.ts";
import { FilesProvider, sanitizeFileName } from "../src/providers/files.ts";
import { connectedCore, tempDir, waitFor } from "./helpers.ts";

function chunk(seq: number, bytes: Uint8Array): Uint8Array {
  const out = new Uint8Array(4 + bytes.byteLength);
  new DataView(out.buffer).setUint32(0, seq, false);
  out.set(bytes, 4);
  return out;
}

async function upload(client: any, name: string, data: Buffer, chunkSize = 7): Promise<string> {
  const { uploadId } = await client.request("fs.upload.begin", { name, mimeType: "image/png", size: data.byteLength });
  for (let i = 0, seq = 0; i < data.byteLength; i += chunkSize, seq++) {
    client.peer.sendFrame(FrameKind.fileChunk, uploadId, chunk(seq, data.subarray(i, i + chunkSize)));
  }
  return (await client.request("fs.upload.end", { uploadId })).path;
}

describe("sanitizeFileName", () => {
  it("keeps one safe path component", () => {
    expect(sanitizeFileName("../../etc/passwd")).toBe("passwd");
    expect(sanitizeFileName("a\\b\\c.png")).toBe("c.png");
    expect(sanitizeFileName(".hidden")).toBe("hidden");
    expect(sanitizeFileName("..")).toBe("upload");
    expect(sanitizeFileName("x\u0000y\nz.txt")).toBe("xyz.txt");
    expect(sanitizeFileName('a:b*c?"<>|.jpg')).toBe("a_b_c_____.jpg");
    const long = sanitizeFileName("n".repeat(300) + ".jpeg");
    expect(long.length).toBe(120);
    expect(long.endsWith(".jpeg")).toBe(true);
  });
});

describe("fs.upload (chunked on the bulk lane)", () => {
  it("streams chunks into uploads/<uuid>/<name> and returns the absolute path", async () => {
    const root = join(tempDir(), "uploads");
    const { client, core } = await connectedCore({ files: { root, sweep: false } });
    const data = Buffer.from("hello photo, in several chunks");
    const path = await upload(client, "../IMG 0001.png", data);
    expect(path.startsWith(root + "/")).toBe(true);
    expect(path.endsWith("/IMG 0001.png")).toBe(true);
    expect(path.split("/").length).toBe(root.split("/").length + 2);
    expect(readFileSync(path).toString()).toBe(data.toString());
    expect(statSync(path).mode & 0o777).toBe(0o600);
    expect(readdirSync(join(path, "..")).sort()).toEqual(["IMG 0001.png"]);
    expect(core.info().capabilities).toContain("fs.v1");
    // Two uploads with one name never collide; an empty file works.
    const second = await upload(client, "IMG 0001.png", Buffer.alloc(0));
    expect(second).not.toBe(path);
    expect(readFileSync(second).byteLength).toBe(0);
    core.shutdown();
  });

  it("end waits for chunks still in flight on the bulk lane", async () => {
    const root = join(tempDir(), "uploads");
    const { client, core } = await connectedCore({ files: { root, sweep: false } });
    const data = Buffer.from("0123456789");
    const { uploadId } = await client.request("fs.upload.begin", { name: "late.txt", size: data.byteLength });
    client.peer.sendFrame(FrameKind.fileChunk, uploadId, chunk(0, data.subarray(0, 5)));
    const ending = client.request("fs.upload.end", { uploadId });
    await new Promise((r) => setTimeout(r, 50));
    client.peer.sendFrame(FrameKind.fileChunk, uploadId, chunk(1, data.subarray(5)));
    const { path } = await ending;
    expect(readFileSync(path).toString()).toBe("0123456789");
    core.shutdown();
  });

  it("rejects oversized, out-of-order, overlong and stalled uploads and cleans up", async () => {
    const root = join(tempDir(), "uploads");
    const { client, core } = await connectedCore({ files: { root, maxBytes: 16, idleMs: 200, sweep: false } });
    await expect(client.request("fs.upload.begin", { name: "big.bin", size: 17 })).rejects.toMatchObject({ code: "bad_request" });
    await expect(client.request("fs.upload.begin", { name: "", size: 1 })).rejects.toMatchObject({ code: "bad_request" });

    let { uploadId } = await client.request("fs.upload.begin", { name: "a", size: 4 });
    client.peer.sendFrame(FrameKind.fileChunk, uploadId, chunk(1, Buffer.from("ab")));
    await expect(client.request("fs.upload.end", { uploadId })).rejects.toMatchObject({ code: "bad_request" });

    ({ uploadId } = await client.request("fs.upload.begin", { name: "b", size: 2 }));
    client.peer.sendFrame(FrameKind.fileChunk, uploadId, chunk(0, Buffer.from("abc")));
    await expect(client.request("fs.upload.end", { uploadId })).rejects.toMatchObject({ code: "bad_request" });

    ({ uploadId } = await client.request("fs.upload.begin", { name: "c", size: 8 }));
    client.peer.sendFrame(FrameKind.fileChunk, uploadId, chunk(0, Buffer.from("abcd")));
    await expect(client.request("fs.upload.end", { uploadId })).rejects.toMatchObject({ code: "bad_request" });

    // Every failed upload's folder is removed.
    await waitFor(() => readdirSync(root).length === 0);
    // A term input frame aimed at an upload stream is ignored, not written.
    ({ uploadId } = await client.request("fs.upload.begin", { name: "d", size: 1 }));
    client.peer.sendFrame(FrameKind.termInput, uploadId, chunk(0, Buffer.from("x")));
    await client.request("fs.upload.cancel", { uploadId });
    await waitFor(() => readdirSync(root).length === 0);
    expect(existsSync(root)).toBe(true);
    core.shutdown();
  });

  it("sweeps upload folders older than the retention period", async () => {
    const root = join(tempDir(), "uploads");
    const old = join(root, "old"), fresh = join(root, "fresh");
    mkdirSync(old, { recursive: true });
    mkdirSync(fresh, { recursive: true });
    writeFileSync(join(old, "x.png"), "x");
    const eightDaysAgo = (Date.now() - 8 * 24 * 3600 * 1000) / 1000;
    utimesSync(old, eightDaysAgo, eightDaysAgo);
    const files = new FilesProvider({ root, sweep: false });
    expect(await files.sweep()).toBe(1);
    expect(readdirSync(root)).toEqual(["fresh"]);
    files.close();
  });
});
