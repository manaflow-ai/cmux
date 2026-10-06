import type { SchemaRow } from "../schema";

export type EditorProps = {
  row: SchemaRow;
  value: unknown;
  disabled: boolean;
  labelId: string;
};
