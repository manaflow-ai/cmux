// Token counts for printed output: o200k_base through js-tiktoken when it is
// installed, else bytes / 4.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let encoder = null;
try {
  const { Tiktoken } = require("js-tiktoken/lite");
  const o200k = require("js-tiktoken/ranks/o200k_base");
  encoder = new Tiktoken(o200k.default ?? o200k);
} catch {
  encoder = null;
}
export const TOKENIZER = encoder ? "o200k_base (js-tiktoken)" : "bytes/4 (js-tiktoken not installed)";
export function tokens(text) {
  if (!text) return 0;
  if (!encoder) return Math.ceil(Buffer.byteLength(text) / 4);
  return encoder.encode(text, "all").length;
}
