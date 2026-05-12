/**
 * Tiny helper for JSON-or-text output across status-y commands.
 */

import type { ParsedArgs } from "./args.ts";

/** Returns true iff --output-format json was passed. */
export function shouldOutputJson(parsed: ParsedArgs): boolean {
  return parsed.outputFormat === "json";
}

/**
 * Write output to stdout.
 * - JSON mode: JSON.stringify(data, null, 2)
 * - Text mode: textRender(data)
 */
export function emit(
  parsed: ParsedArgs,
  data: unknown,
  textRender: (data: unknown) => string,
): void {
  if (shouldOutputJson(parsed)) {
    process.stdout.write(JSON.stringify(data, null, 2) + "\n");
  } else {
    process.stdout.write(textRender(data));
  }
}
