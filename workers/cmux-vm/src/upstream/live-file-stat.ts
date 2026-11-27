import { Effect, Schema } from "effect";
import { UpstreamError, type FileStatRecord, type UpstreamClientService } from "./client.ts";
import { proofSegment, type UpstreamHttp } from "./live-http.ts";

const RawStat = Schema.Struct({
  size: Schema.Int.pipe(Schema.between(0, Number.MAX_SAFE_INTEGER)),
  isFile: Schema.Boolean, isDirectory: Schema.Boolean, isSymlink: Schema.Boolean,
  permissions: Schema.String.pipe(Schema.pattern(/^[0-7]{1,6}$/)),
  modified: Schema.String.pipe(Schema.maxLength(64)),
  owner: Schema.String.pipe(Schema.maxLength(256)), group: Schema.String.pipe(Schema.maxLength(256)),
});

/** Accept the provider's epoch string or ISO timestamp; an empty saved-disk value is unknown. */
const modifiedSeconds = (text: string): number | null => {
  if (text === "") return null;
  if (/^-?\d{1,12}$/.test(text)) return Number(text);
  const iso = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.exec(text);
  if (iso === null) return NaN;
  const year = Number(iso[1]), month = Number(iso[2]), day = Number(iso[3]);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] ?? 0;
  if (day < 1 || day > days || Number(iso[4]) > 23 || Number(iso[5]) > 59 || Number(iso[6]) > 59) return NaN;
  return Math.floor(Date.parse(text) / 1000);
};

export const makeStatFile = (http: UpstreamHttp): Pick<UpstreamClientService, "statFile"> => ({
  statFile: (_vm, { owns }, path) => Effect.gen(function* () {
    const badMetadata = () => new UpstreamError({ operation: "statFile", status: null });
    const body = yield* http.json("statFile", "GET", `/v5/vms/${proofSegment(owns)}/fs/stat?path=${encodeURIComponent(path)}`);
    const raw = yield* Schema.decodeUnknown(RawStat)(body).pipe(Effect.mapError(() => badMetadata()));
    const mtime = modifiedSeconds(raw.modified);
    if ((!raw.isSymlink && raw.isFile && raw.isDirectory) || (mtime !== null && (!Number.isSafeInteger(mtime) || mtime < -62167219200 || mtime > 253402300799))) return yield* Effect.fail(badMetadata());
    return {
      kind: raw.isSymlink ? "symlink" : raw.isDirectory ? "directory" : raw.isFile ? "file" : "other",
      size: raw.size, mode: parseInt(raw.permissions, 8) & 0o7777, mtime, owner: raw.owner, group: raw.group,
    } satisfies FileStatRecord;
  }),
});
