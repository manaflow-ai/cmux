export type OutputFormat = "pretty" | "json";
export interface OutputArgv {
    output?: OutputFormat;
}
/** Print a value as pretty JSON to stdout. */
export declare function printJson(value: unknown): void;
/**
 * Print a command's result: human-readable by default, raw JSON under
 * `--output=json`. `render` receives the value and returns the pretty text.
 */
export declare function printResult<T>(argv: OutputArgv, value: T, render: (value: T) => string): void;
/** Print a short human confirmation line, for commands with no interesting return value. */
export declare function printLine(message: string): void;
/**
 * A failed WebSocket upgrade (`vm ssh`) carries no error body — the status
 * line is everything the client is given, so turn it into the same guidance
 * a REST failure would have printed.
 */
export declare function describeUpgradeFailure(error: unknown, argv: unknown): string;
/**
 * Wrap a command handler so a {@link FreestyleApiError} (or any error) prints
 * cleanly and exits non-zero, instead of a raw stack trace.
 */
export declare function handle<Argv>(fn: (argv: Argv) => Promise<void>): (argv: Argv) => Promise<void>;
/** Parse `key=value` pairs (e.g. repeated `--metadata env=prod --metadata team=x`) into an object. */
export declare function parseKeyValuePairs(pairs: string[] | undefined): Record<string, string>;
export declare const bold: (text: string) => string;
export declare const dim: (text: string) => string;
export declare const red: (text: string) => string;
export declare const green: (text: string) => string;
export declare const yellow: (text: string) => string;
export declare const cyan: (text: string) => string;
/** A column-aligned table with a dim header row. */
export declare function table(headers: string[], rows: string[][]): string;
/**
 * Things the reader is going to copy — a command, a DNS record value, a key —
 * each alone on its line under a dim label.
 *
 * Nothing shares the line and nothing is indented, so a triple-click takes the
 * whole payload and only the payload. The color of the label, not the layout,
 * is what keeps the two apart; an id nobody can retype is the whole reason
 * these lines exist, so the line must not carry anything else.
 */
export declare function copyable(pairs: Array<[string, string]>): string;
/** An aligned key/value block. Pairs with a nullish or empty value are skipped. */
export declare function details(pairs: Array<[string, string | number | null | undefined]>): string;
/** `2026-07-30T18:04:05Z` → `2026-07-30 11:04` (local time), with a relative hint. */
export declare function formatDate(iso: string | null | undefined): string | undefined;
/** Compact relative time for tables, e.g. `4h ago`. */
export declare function relative(from: Date | string): string | undefined;
/** Memory in MiB → `512 MiB` / `4 GiB`. */
export declare function formatMiB(mib: number): string;
/** Disk in MB → `750 MB` / `16 GB`. */
export declare function formatMB(mb: number): string;
/** Bytes → `1.4 KiB`, `3.2 MiB`, … */
export declare function formatBytes(bytes: number): string;
/** `{env: "prod"}` → `env=prod`, comma-separated. */
export declare function formatMetadata(metadata: Record<string, string> | undefined): string | undefined;
//# sourceMappingURL=output.d.ts.map