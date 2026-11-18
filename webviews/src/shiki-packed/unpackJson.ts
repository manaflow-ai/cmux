// The runtime half of scripts/packed-shiki-data.mjs: a Shiki grammar or theme chunk holds its JSON
// document raw-deflated and base64-encoded, and calls this when it is imported. Synchronous, so
// the chunk exports its frozen object exactly when it did before. One small lazy chunk
// (`shiki-unpack`), loaded with the first grammar or theme.
import { inflateSync, strFromU8 } from "fflate";

export function unpackJson(base64: string): unknown {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return JSON.parse(strFromU8(inflateSync(bytes)));
}
