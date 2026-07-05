import { MAX_BUFFERED_BODY_BYTES } from "./families";

export function bodyWithinReplayLimit(byteLength: number | null): boolean {
  return byteLength === null || byteLength <= MAX_BUFFERED_BODY_BYTES;
}

export function bodyWithinJsonParseLimit(byteLength: number | null): boolean {
  return byteLength !== null && byteLength <= MAX_BUFFERED_BODY_BYTES;
}
