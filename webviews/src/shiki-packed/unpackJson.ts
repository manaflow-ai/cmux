// The runtime half of scripts/packed-shiki-data.mjs: a Shiki grammar or theme chunk, or a Monaco
// UI-strings chunk, holds its JSON document raw-deflated and base64-encoded, and calls this when it
// is imported. Synchronous, so the chunk exports (or sets) its value exactly when it did before.
// One small lazy chunk (`shiki-unpack`), loaded with the first of them or the Oniguruma engine's
// WebAssembly (unpackBytes).
import { inflateSync, strFromU8 } from "fflate";

/** The bytes `base64` holds, raw-deflated, inflated. */
export function unpackBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return inflateSync(bytes);
}

export function unpackJson(base64: string): unknown {
  return JSON.parse(strFromU8(unpackBytes(base64)));
}
