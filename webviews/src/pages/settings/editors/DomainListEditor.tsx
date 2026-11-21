import { useSettingsSelector, useStore } from "../context";
import { FontPicker } from "../components/FontPicker";
import { text } from "../strings";
import { TextEditor } from "./TextEditor";
import type { EditorProps } from "./types";

/**
 * font_family: the installed families the app published in ready().domains, fonts picked lately
 * first, each drawn in its own face; the highlighted one previews live (FontPicker). With no
 * published names, a text field.
 */
export function DomainListEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const names = useSettingsSelector((state) => state.domains.font_families);
  const recent = useSettingsSelector((state) => state.domains.recent_fonts);
  if (names.length === 0) return <TextEditor row={row} value={value} disabled={disabled} labelId={labelId} />;
  const current = typeof value === "string" && value !== row.default ? value : null;
  return (
    <FontPicker
      value={current}
      names={names}
      recent={recent}
      labelId={labelId}
      disabled={disabled}
      title={text(row.title)}
      defaultLabel={text(row.default_label) || text(row.title)}
      onPick={(name) => (name === null ? store.reset(row.key) : store.set(row.key, name))}
      onPreview={(name, owner) => (name ? store.preview(row.key, name, owner) : store.previewEnd(row.key, owner))}
    />
  );
}
