import { useStore } from "../context";
import { locale } from "../strings";
import { Select } from "./Select";
import type { EditorProps } from "./types";

const PRESETS = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5];

export function ZoomEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const range = row.range!;
  const current = typeof value === "number" ? value : typeof row.default === "number" ? row.default : range.placeholder;
  const presets = PRESETS.filter((level) => level >= range.min && level <= range.max);
  const levels = [...new Set([...presets, current])].sort((a, b) => a - b);
  const format = new Intl.NumberFormat(locale(), { style: "percent", maximumFractionDigits: 3 });
  return (
    <Select
      value={String(current)}
      disabled={disabled}
      labelId={labelId}
      onChange={(next) => void store.set(row.key, Number(next))}
    >
      {levels.map((level) => (
        <option key={level} value={String(level)}>
          {format.format(level)}
        </option>
      ))}
    </Select>
  );
}
