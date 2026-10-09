// File uploads from the phone (PROTOCOL.md §4 files): a photo, camera shot or
// file the user attached in the terminal composer is written under
// ~/.cmux-next-host/uploads/<uuid>/<name> and its absolute path goes back to
// the phone, which types it into the terminal.

import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { RpcError, type RpcServer, optStr, str } from "../rpc/index.ts";

/** Largest decoded upload. */
export const UPLOAD_MAX_BYTES = 50 * 1024 * 1024;

export interface FilesOptions {
  /** Upload root (default ~/.cmux-next-host/uploads). */
  root?: string;
  maxBytes?: number;
}

/**
 * A safe single path component: no directories, no control characters, no
 * leading dots, at most 120 characters (extension kept).
 */
export function sanitizeFileName(raw: string): string {
  const base = raw.split(/[\\/]/).pop() ?? "";
  let name = base
    .normalize("NFC")
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/[:*?"<>|]/g, "_")
    .trim()
    .replace(/^\.+/, "");
  if (name.length > 120) {
    const dot = name.lastIndexOf(".");
    const ext = dot > 0 && name.length - dot <= 16 ? name.slice(dot) : "";
    name = name.slice(0, 120 - ext.length) + ext;
  }
  return name.length > 0 ? name : "upload";
}

export class FilesProvider {
  readonly root: string;
  private readonly maxBytes: number;

  constructor(opts: FilesOptions = {}) {
    this.root = opts.root ?? join(homedir(), ".cmux-next-host", "uploads");
    this.maxBytes = opts.maxBytes ?? UPLOAD_MAX_BYTES;
  }

  async upload(name: string, data: Buffer): Promise<string> {
    if (data.byteLength > this.maxBytes) {
      throw new RpcError("bad_request", `file is larger than ${Math.floor(this.maxBytes / (1024 * 1024))} MB`);
    }
    const dir = join(this.root, randomUUID());
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const path = join(dir, sanitizeFileName(name));
    await writeFile(path, data, { mode: 0o600, flag: "wx" });
    return path;
  }

  register(server: RpcServer): void {
    server.register("fs.upload", async (p) => {
      const name = str(p, "name");
      optStr(p, "mimeType");
      const encoded = str(p, "dataBase64");
      // Reject before decoding: base64 is 4/3 of the payload.
      if (encoded.length > Math.ceil(this.maxBytes / 3) * 4 + 4) {
        throw new RpcError("bad_request", `file is larger than ${Math.floor(this.maxBytes / (1024 * 1024))} MB`);
      }
      if (!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) throw new RpcError("bad_request", "dataBase64 is not base64");
      return { path: await this.upload(name, Buffer.from(encoded, "base64")) };
    });
  }
}
