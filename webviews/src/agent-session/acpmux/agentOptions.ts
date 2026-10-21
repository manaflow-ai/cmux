import type { AcpmuxSnapshot } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
/// One ACP session config option (`configOptions[]`), as the session summary carries it.
export type ConfigOption = NonNullable<Summary["configOptions"]>[number];

/// The config options the composer has no control of its own for (none yet).
export function extraConfigOptions(_summary: AcpmuxSnapshot["summary"]): ConfigOption[] {
  return [];
}
