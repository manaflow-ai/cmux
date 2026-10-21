/** A bounded, one-based position or line range. Shared by reply paths and the editor. */
export interface FileLocation {
  line: number;
  column?: number;
  endLine?: number;
}

export function fileLocation(value: unknown): FileLocation | undefined {
  if (!value || typeof value !== "object") return undefined;
  const { line, column, endLine } = value as FileLocation;
  const positive = (n: unknown): n is number =>
    typeof n === "number" && Number.isInteger(n) && n > 0 && n <= 10_000_000;
  if (
    !positive(line) ||
    (column !== undefined && !positive(column)) ||
    (endLine !== undefined && (!positive(endLine) || endLine < line))
  )
    return undefined;
  return { line, ...(column === undefined ? {} : { column }), ...(endLine === undefined ? {} : { endLine }) };
}

/** The host accepts only this numeric spelling, never arbitrary fragments or editor commands. */
export function locationArgument(location: FileLocation): string {
  return `${location.line}${location.column === undefined ? "" : `:${location.column}`}${location.endLine === undefined ? "" : `-${location.endLine}`}`;
}
