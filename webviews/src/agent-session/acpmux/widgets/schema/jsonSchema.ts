// Placeholder: the JSON Schema validator for the thread widget contract is not implemented yet.
export type SchemaIssue = { path: string; keyword: string; message: string };

export function jsonEqual(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

export class SchemaSet {
  constructor(_documents: readonly unknown[]) {}

  validate(_ref: string, _value: unknown): SchemaIssue[] {
    return [];
  }
}
