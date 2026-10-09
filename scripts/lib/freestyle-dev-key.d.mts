/** Types for scripts/lib/freestyle-dev-key.mjs (the one Freestyle dev key, from ~/.secrets/cmux.env). */
export function devKeyEnvFile(env?: Record<string, string | undefined>): string;
export function parseFreestyleApiKey(text: string): string;
export function freestyleDevKey(options?: { readonly file?: string }): string;
