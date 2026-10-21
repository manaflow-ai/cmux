import { fileLocation, type FileLocation } from "../../../fileLocation";

export interface ReplyPath {
  path: string;
  location?: FileLocation;
  suffix?: string;
  /// A bare file name (`test.py`) in a code span: a chip only once the host finds the file.
  bare?: boolean;
}

/** Splits the supported line spellings from a local path; folders have no position. */
export function pathLocation(value: string): ReplyPath {
  const match = /(?::(\d+)(?::(\d+)|-(\d+))?|#L(\d+)(?:C(\d+)|-L(\d+))?)$/.exec(value);
  if (!match) return { path: value };
  const path = value.slice(0, match.index);
  const column = match[2] ?? match[5];
  const endLine = match[3] ?? match[6];
  const location = path.endsWith("/")
    ? undefined
    : fileLocation({
        line: Number(match[1] ?? match[4]),
        ...(column === undefined ? {} : { column: Number(column) }),
        ...(endLine === undefined ? {} : { endLine: Number(endLine) }),
      });
  return { path, ...(location ? { location, suffix: match[0] } : {}) };
}
