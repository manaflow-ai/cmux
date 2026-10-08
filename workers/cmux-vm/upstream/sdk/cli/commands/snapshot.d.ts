import type { CommandModule } from "yargs";
import type { GlobalArgv } from "../context.js";
type Args = GlobalArgv & Record<string, unknown>;
/**
 * Slugs the API accepts: 1-63 characters of `a-z`, `0-9` and hyphens, with no
 * leading, trailing, or repeated hyphen. Checked here so a typo costs a
 * re-prompt rather than a rejected request against a snapshot already taken.
 */
export declare function isValidSnapshotSlug(slug: string): boolean;
/** `freestyle snapshot …` — the top level, where `create` can build the VM too. */
export declare const snapshotCommand: CommandModule<Args, Args>;
/** `freestyle vm snapshot …` — the same commands, with `create` always naming a VM. */
export declare const vmSnapshotCommand: CommandModule<Args, Args>;
export {};
//# sourceMappingURL=snapshot.d.ts.map