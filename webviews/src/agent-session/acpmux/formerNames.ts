/** The newest of `formerNames` that is not `name`, if any. */
export function newestFormerName(name: string, formerNames: readonly string[] | undefined): string | undefined {
  if (!formerNames) return undefined;
  for (let at = formerNames.length - 1; at >= 0; at--) {
    const former = formerNames[at]!.trim();
    if (former && former !== name) return former;
  }
  return undefined;
}
