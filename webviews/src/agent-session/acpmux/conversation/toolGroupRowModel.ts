/// Test probes: how many times the group built its step list and each step drew. Unset in the app.
export const stepProbe: {
  build?: () => void;
  render?: (key: string) => void;
} = {};

/// Two lists hold the same entries in the same order (items are immutable snapshots, compared by
/// identity): a group whose list is the same draws nothing new. One pass over the group, as building
/// its groups (toolGroups.ts) already makes.
export const sameList = <T>(a: readonly T[] | undefined, b: readonly T[] | undefined): boolean =>
  a === b || (a !== undefined && b !== undefined && a.length === b.length && a.every((entry, at) => entry === b[at]));
