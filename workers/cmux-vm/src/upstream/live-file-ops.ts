/**
 * exists, mkdir, remove and resumable uploads on an owned VM (cx-b4h.2).
 *
 * Upload handles: the provider's upload id is never returned. The public
 * `upl_...` handle is the provider id sealed with AES-256-GCM under a key
 * derived (HKDF-SHA-256) from the provider key, with the provider and public
 * ids of the exact VM as associated data. A handle therefore opens only for
 * the VM (and so the tenant) it was issued for; any other VM, a forged or a
 * truncated handle reads as "no such upload" (status 404) before any provider
 * request. Rotating the provider key ends open uploads, which the provider
 * expires after an hour idle anyway.
 */
import { Effect, Redacted, Schema } from "effect";
import { upstreamIdOf, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { UpstreamError, type FileUploadRecord, type UpstreamParityService } from "./client.ts";
import { proofSegment, type UpstreamHttp } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";

/** Chunks stream; this bounds a stuck one. */
const CHUNK_TIMEOUT_MS = 15 * 60_000;
/** Commit verifies and renames a file up to 16 GiB. */
const COMMIT_TIMEOUT_MS = 10 * 60_000;
const FS_TIMEOUT_MS = 60_000;
const MAX_RESPONSE_BYTES = 64 * 1024;

const UploadStatus = Schema.Struct({
  uploadId: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256)),
  path: Schema.String.pipe(Schema.maxLength(4096)),
  size: Schema.Int.pipe(Schema.between(0, Number.MAX_SAFE_INTEGER)),
  receivedBytes: Schema.Int.pipe(Schema.between(0, Number.MAX_SAFE_INTEGER)),
});
const Exists = Schema.Struct({ exists: Schema.Boolean });

const PUBLIC_UPLOAD_ID = /^upl_[A-Za-z0-9_-]{38,512}$/u;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const toBase64Url = (bytes: Uint8Array): string => {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
};

const fromBase64Url = (text: string): Uint8Array<ArrayBuffer> | null => {
  try {
    const binary = atob(text.replaceAll("-", "+").replaceAll("_", "/"));
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
  } catch {
    return null;
  }
};

export const makeFileOps = (
  config: UpstreamConfig,
  http: UpstreamHttp,
): Pick<UpstreamParityService, "pathExists" | "makeDirectory" | "removePath" | "beginUpload" | "uploadStatus" | "uploadChunk" | "commitUpload" | "abortUpload"> => {
  const base = new URL(config.baseUrl);
  const sendRequest = config.fetch ?? ((request: Request) => fetch(request));
  let sealingKey: Promise<CryptoKey> | null = null;
  const key = () => {
    sealingKey ??= crypto.subtle
      .importKey("raw", encoder.encode(Redacted.value(config.apiKey)), "HKDF", false, ["deriveKey"])
      .then((material) =>
        crypto.subtle.deriveKey(
          { name: "HKDF", hash: "SHA-256", salt: encoder.encode("cmux-vm/upload-id/v1"), info: new Uint8Array(0) },
          material,
          { name: "AES-GCM", length: 256 },
          false,
          ["encrypt", "decrypt"],
        ),
      );
    return sealingKey;
  };
  const boundTo = <C, R>(owns: TenantOwnsResource<C, R>, vmId: string) => encoder.encode(`cmux-vm-upload-v1\n${upstreamIdOf(owns)}\n${vmId}`);

  const seal = <C, R>(owns: TenantOwnsResource<C, R>, vmId: string, providerId: string) =>
    Effect.tryPromise({
      try: async () => {
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: boundTo(owns, vmId) }, await key(), encoder.encode(providerId)));
        const out = new Uint8Array(iv.length + sealed.length);
        out.set(iv);
        out.set(sealed, iv.length);
        return `upl_${toBase64Url(out)}`;
      },
      catch: () => new UpstreamError({ operation: "sealUpload", status: null }),
    });

  /** The provider id behind a public handle issued for exactly this VM; 404 otherwise. */
  const open = <C, R>(owns: TenantOwnsResource<C, R>, vmId: string, publicId: string) =>
    Effect.tryPromise({
      try: async () => {
        if (!PUBLIC_UPLOAD_ID.test(publicId)) return null;
        const bytes = fromBase64Url(publicId.slice(4));
        if (bytes === null || bytes.length <= 28) return null;
        try {
          const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12), additionalData: boundTo(owns, vmId) }, await key(), bytes.slice(12));
          return decoder.decode(plain);
        } catch {
          return null;
        }
      },
      catch: () => new UpstreamError({ operation: "openUpload", status: null }),
    }).pipe(Effect.flatMap((id) => (id === null ? Effect.fail(new UpstreamError({ operation: "openUpload", status: 404 })) : Effect.succeed(id))));

  const record = (operation: string, publicId: string) => (body: unknown): Effect.Effect<FileUploadRecord, UpstreamError> =>
    Schema.decodeUnknown(UploadStatus)(body).pipe(
      Effect.map((status) => ({ uploadId: publicId, path: status.path, size: status.size, receivedBytes: status.receivedBytes })),
      Effect.mapError(() => new UpstreamError({ operation, status: null })),
    );

  const fsPath = <C, R>(owns: TenantOwnsResource<C, R>, suffix: string) => `/v5/vms/${proofSegment(owns)}/fs/${suffix}`;
  const uploadPath = <C, R>(owns: TenantOwnsResource<C, R>, providerId: string) => fsPath(owns, `uploads/${encodeURIComponent(providerId)}`);

  /** One chunk of raw bytes with an exact length; the JSON answer is parsed. */
  const putChunk = (path: string, offset: number, body: ReadableStream<Uint8Array>, length: number) =>
    Effect.tryPromise({
      try: async () => {
        const url = new URL(path, base);
        url.searchParams.set("offset", String(offset));
        const sized = new FixedLengthStream(length);
        void body.pipeTo(sized.writable).catch(() => undefined);
        const response = await sendRequest(new Request(url, {
          method: "PUT",
          headers: {
            authorization: `Bearer ${Redacted.value(config.apiKey)}`,
            accept: "application/json",
            "content-type": "application/octet-stream",
          },
          body: sized.readable,
          redirect: "manual",
          signal: AbortSignal.timeout(CHUNK_TIMEOUT_MS),
        }));
        if (!response.ok) {
          await response.body?.cancel();
          return { ok: false as const, status: response.status };
        }
        const text = await response.text();
        if (text.length > MAX_RESPONSE_BYTES) return { ok: false as const, status: null };
        const parsed: unknown = JSON.parse(text);
        return { ok: true as const, body: parsed };
      },
      catch: () => new UpstreamError({ operation: "uploadChunk", status: null }),
    }).pipe(Effect.flatMap((result) => (result.ok ? Effect.succeed(result.body) : Effect.fail(new UpstreamError({ operation: "uploadChunk", status: result.status })))));

  return {
    pathExists: (_vm, { owns }, path) =>
      http.json("pathExists", "GET", `${fsPath(owns, "exists")}?path=${encodeURIComponent(path)}`, undefined, { timeoutMs: FS_TIMEOUT_MS }).pipe(
        Effect.flatMap((body) => Schema.decodeUnknown(Exists)(body).pipe(Effect.mapError(() => new UpstreamError({ operation: "pathExists", status: null })))),
        Effect.map((answer) => answer.exists),
      ),
    makeDirectory: (_vm, { owns }, path) =>
      http.json("makeDirectory", "POST", fsPath(owns, "mkdir"), { path }, { timeoutMs: FS_TIMEOUT_MS }).pipe(Effect.asVoid),
    removePath: (_vm, { owns }, path) =>
      http.json("removePath", "DELETE", `${fsPath(owns, "remove")}?path=${encodeURIComponent(path)}`, undefined, { timeoutMs: FS_TIMEOUT_MS }).pipe(Effect.asVoid),
    beginUpload: (vm, { owns }, spec) =>
      http.json("beginUpload", "POST", fsPath(owns, "uploads"), {
        path: spec.path,
        size: spec.size,
        ...(spec.sha256 === undefined ? {} : { sha256: spec.sha256.toLowerCase() }),
        ...(spec.mode === undefined ? {} : { mode: spec.mode }),
      }, { timeoutMs: FS_TIMEOUT_MS }).pipe(
        Effect.flatMap((body) => Schema.decodeUnknown(UploadStatus)(body).pipe(Effect.mapError(() => new UpstreamError({ operation: "beginUpload", status: null })), Effect.tapError(() => {
          // An unreadable answer may still name a session: free it rather than leave it holding spool space.
          const id: unknown = typeof body === "object" && body !== null ? Reflect.get(body, "uploadId") : undefined;
          return typeof id === "string" && id.length > 0 && id.length <= 256 ? http.json("abortUpload", "DELETE", uploadPath(owns, id)).pipe(Effect.ignore) : Effect.void;
        }))),
        Effect.flatMap((status) =>
          seal(owns, vm.value, status.uploadId).pipe(
            Effect.map((uploadId) => ({ uploadId, path: status.path, size: status.size, receivedBytes: status.receivedBytes })),
            // The session cannot be handed out: do not leave it holding spool space.
            Effect.tapError(() => http.json("abortUpload", "DELETE", uploadPath(owns, status.uploadId)).pipe(Effect.ignore)),
          ),
        ),
      ),
    uploadStatus: (vm, { owns }, publicId) =>
      open(owns, vm.value, publicId).pipe(
        Effect.flatMap((id) => http.json("uploadStatus", "GET", uploadPath(owns, id), undefined, { timeoutMs: FS_TIMEOUT_MS })),
        Effect.flatMap(record("uploadStatus", publicId)),
      ),
    uploadChunk: (vm, { owns }, publicId, chunk) =>
      open(owns, vm.value, publicId).pipe(
        Effect.flatMap((id) => putChunk(uploadPath(owns, id), chunk.offset, chunk.body, chunk.length)),
        Effect.flatMap(record("uploadChunk", publicId)),
      ),
    commitUpload: (vm, { owns }, publicId) =>
      open(owns, vm.value, publicId).pipe(
        Effect.flatMap((id) => http.json("commitUpload", "POST", `${uploadPath(owns, id)}/commit`, undefined, { timeoutMs: COMMIT_TIMEOUT_MS })),
        Effect.asVoid,
      ),
    abortUpload: (vm, { owns }, publicId) =>
      open(owns, vm.value, publicId).pipe(
        Effect.flatMap((id) => http.json("abortUpload", "DELETE", uploadPath(owns, id), undefined, { timeoutMs: FS_TIMEOUT_MS })),
        Effect.asVoid,
      ),
  };
};
