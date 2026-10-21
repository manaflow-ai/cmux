// Settings > Appearance > Density (plans/cmux-next/density-DESIGN.md, design A of
// plans/cmux-next/density-gallery): one tile per density (the built-ins, then the user's), each
// drawing a sidebar row, a tab and caption text at its sizes; Duplicate, Import and Export; and,
// for a custom density, an editor with a large live preview. Built-ins write appearance.density
// (the app then drops appearance.customDensity); a custom one writes appearance.customDensity;
// the list is appearance.customDensities.
import { useMemo, useState, type CSSProperties } from "react";
import { useSettingsState, useStore } from "../context";
import {
  CUSTOM_DENSITIES_KEY,
  CUSTOM_DENSITY_KEY,
  DENSITY_KEY,
  FONT_RANGE,
  LEVEL_RANGE,
  PAIRS,
  PRESETS,
  SPACING_RANGE,
  customDensities,
  duplicate,
  parseExport,
  resolve,
  toJSON,
  type Density,
} from "../density";
import { t } from "../strings";

const EXACT: ReadonlyArray<keyof typeof PAIRS> = ["sidebarRowHeight", "tabHeight", "itemCornerRadius", "iconSize"];

function displayName(density: Density): string {
  const preset = PRESETS.find((item) => item.id === density.id);
  return preset ? t(preset.nameKey) : density.name;
}

/** A sidebar group header, a selected row, a tab strip and a caption at `density`'s sizes. */
export function DensityPreview({ density, rows = 1 }: { density: Density; rows?: number }) {
  const r = resolve(density);
  const style = {
    "--density-row": `${r.sidebarRowHeight}px`,
    "--density-tab": `${r.tabHeight}px`,
    "--density-strip": `${r.tabStripHeight}px`,
    "--density-radius": `${r.itemCornerRadius}px`,
    "--density-icon": `${r.iconSize}px`,
    "--density-body": `${r.body}px`,
    "--density-caption": `${r.caption}px`,
    "--density-inset": `${r.inset}px`,
  } as CSSProperties;
  const names = ["cmux-next app", "density rethink", "source control", "Home"];
  return (
    <div
      className="density-preview"
      style={style}
      data-row-height={r.sidebarRowHeight}
      data-body={r.body}
      aria-hidden="true"
    >
      <div className="density-strip">
        <span className="density-tab" data-on="">
          <span className="density-icon" />
          zsh
        </span>
        <span className="density-tab">README.md</span>
      </div>
      <div className="density-list">
        <div className="density-item density-group">{names[0]}</div>
        {names.slice(1, 1 + rows).map((name, index) => (
          <div key={name} className="density-item" data-selected={index === 0 ? "" : undefined}>
            <span className="density-icon" />
            {name}
          </div>
        ))}
      </div>
      <div className="density-caption">{t("settingsWindow.density.previewCaption", r.sidebarRowHeight, r.body)}</div>
    </div>
  );
}

function Slider({
  label,
  value,
  range,
  step,
  onChange,
  name,
}: {
  label: string;
  value: number;
  range: { min: number; max: number };
  step: number;
  onChange: (value: number) => void;
  name: string;
}) {
  return (
    <label className="density-field">
      <span>{label}</span>
      <input
        type="range"
        aria-label={label}
        name={name}
        min={range.min}
        max={range.max}
        step={step}
        value={value}
        onChange={(event) => onChange(Number(event.target.value))}
      />
      <output>{value}</output>
    </label>
  );
}

export function DensityCard() {
  const store = useStore();
  const { rows, readable } = useSettingsState();
  const customs = useMemo(() => customDensities(rows.get(CUSTOM_DENSITIES_KEY)?.value), [rows]);
  const customID = rows.get(CUSTOM_DENSITY_KEY)?.value;
  const builtIn = (rows.get(DENSITY_KEY)?.value ?? "compact") as string;
  const current = (
    typeof customID === "string" && customs.some((item) => item.id === customID) ? customID : builtIn
  ) as string;
  const all: Density[] = [...PRESETS, ...customs];
  const [draft, setDraft] = useState<Density | null>(null);
  const [importing, setImporting] = useState(false);
  const [importText, setImportText] = useState("");
  const [notice, setNotice] = useState<string | null>(null);
  const editing = draft ?? customs.find((item) => item.id === current) ?? null;

  const choose = (density: Density) => {
    setDraft(null);
    if (PRESETS.some((preset) => preset.id === density.id)) void store.set(DENSITY_KEY, density.id);
    else void store.set(CUSTOM_DENSITY_KEY, density.id);
  };
  const saveList = async (list: Density[], select: string | null) => {
    await store.set(CUSTOM_DENSITIES_KEY, list.map(toJSON));
    if (select) await store.set(CUSTOM_DENSITY_KEY, select);
  };
  const base = all.find((item) => item.id === current) ?? PRESETS[1]!;
  const onDuplicate = () => {
    const made = duplicate(base, t("settingsWindow.density.copyName", displayName(base)), customs);
    setDraft(made);
    void saveList([...customs, made], made.id);
  };
  const onSave = () => {
    if (!draft) return;
    const list = customs.some((item) => item.id === draft.id)
      ? customs.map((item) => (item.id === draft.id ? draft : item))
      : [...customs, draft];
    void saveList(list, draft.id);
    setDraft(null);
  };
  const onDelete = (density: Density) => {
    setDraft(null);
    const list = customs.filter((item) => item.id !== density.id);
    void (async () => {
      if (current === density.id)
        await store.set(
          DENSITY_KEY,
          density.basedOn && PRESETS.some((p) => p.id === density.basedOn) ? density.basedOn : "compact",
        );
      await store.set(CUSTOM_DENSITIES_KEY, list.map(toJSON));
    })();
  };
  const onExport = () => {
    void navigator.clipboard?.writeText(JSON.stringify(toJSON(base), null, 2));
    setNotice(t("settingsWindow.density.copied", displayName(base)));
  };
  const onImport = () => {
    const parsed = parseExport(importText, customs);
    if (!parsed) {
      setNotice(t("settingsWindow.density.importFailed"));
      return;
    }
    setImporting(false);
    setImportText("");
    setNotice(null);
    void saveList([...customs, parsed], parsed.id);
  };
  const edit = (change: Partial<Density>) => editing && setDraft({ ...editing, ...change });

  return (
    <section className="group" data-card="density">
      <h3 className="group-title">{t("settings.appearance.density")}</h3>
      <p className="density-help">{t("settings.appearance.density.help")}</p>
      <div
        className="density-tiles"
        // ui-allow: the density tiles are buttons in the ARIA radio pattern (see the tile below).
        role="radiogroup"
        aria-label={t("settings.appearance.density")}
      >
        {all.map((density) => {
          const on = density.id === current;
          const custom = !PRESETS.some((preset) => preset.id === density.id);
          return (
            <button
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- ui-allow: the ARIA radio pattern on a tile button; an <input type="radio"> would change the tile's keys and look.
              role="radio"
              key={density.id}
              type="button"
              aria-checked={on}
              className="density-tile"
              data-density={density.id}
              data-on={on ? "" : undefined}
              disabled={!readable}
              onClick={() => choose(density)}
            >
              <DensityPreview density={draft && draft.id === density.id ? draft : density} />
              <span className="density-name">
                {displayName(density)}
                <small>
                  {on ? t("settingsWindow.density.inUse") : custom ? t("settingsWindow.density.custom") : ""}
                </small>
              </span>
            </button>
          );
        })}
      </div>
      <div className="density-actions">
        <button
          type="button"
          className="button"
          data-density-action="duplicate"
          disabled={!readable}
          onClick={onDuplicate}
        >
          {t("settingsWindow.density.duplicate")}
        </button>
        <button
          type="button"
          className="button"
          data-density-action="import"
          disabled={!readable}
          onClick={() => setImporting(!importing)}
        >
          {t("settingsWindow.density.import")}
        </button>
        <button type="button" className="button" data-density-action="export" onClick={onExport}>
          {t("settingsWindow.density.export")}
        </button>
        {notice && <span className="density-notice">{notice}</span>}
      </div>
      {importing && (
        <div className="density-import">
          <textarea
            aria-label={t("settingsWindow.density.importHelp")}
            placeholder={t("settingsWindow.density.importHelp")}
            value={importText}
            onChange={(event) => setImportText(event.target.value)}
          />
          <button type="button" className="button" data-density-action="import-confirm" onClick={onImport}>
            {t("settingsWindow.density.import")}
          </button>
        </div>
      )}
      {editing && (
        <div className="density-editor" data-editing={editing.id}>
          <div className="density-fields">
            <label className="density-field">
              <span>{t("settingsWindow.density.name")}</span>
              <input
                type="text"
                aria-label={t("settingsWindow.density.name")}
                name="density-name"
                value={editing.name}
                onChange={(event) => edit({ name: event.target.value })}
              />
            </label>
            <Slider
              name="level"
              label={t("settingsWindow.density.level")}
              value={editing.level}
              range={LEVEL_RANGE}
              step={0.05}
              onChange={(level) => edit({ level })}
            />
            <Slider
              name="spacing"
              label={t("settingsWindow.density.spacing")}
              value={editing.spacing ?? 1}
              range={SPACING_RANGE}
              step={0.05}
              onChange={(spacing) => edit({ spacing })}
            />
            <Slider
              name="fontSize"
              label={t("settingsWindow.density.textSize")}
              value={editing.fontSize ?? resolve({ ...editing, fontSize: undefined }).body}
              range={FONT_RANGE}
              step={0.5}
              onChange={(fontSize) => edit({ fontSize })}
            />
            <details>
              <summary>{t("settingsWindow.density.exactSizes")}</summary>
              {EXACT.map((name) => (
                <Slider
                  key={name}
                  name={name}
                  label={t(`settingsWindow.density.token.${name}`)}
                  value={resolve(editing)[name]}
                  range={{ min: 0, max: Math.max(48, PAIRS[name][1] * 2) }}
                  step={1}
                  onChange={(value) => edit({ tokens: { ...editing.tokens, [name]: value } })}
                />
              ))}
            </details>
            <div className="density-actions">
              <button
                type="button"
                className="button button-primary"
                data-density-action="save"
                disabled={!draft || editing.name.trim() === ""}
                onClick={onSave}
              >
                {t("settingsWindow.density.save")}
              </button>
              <button type="button" className="button" data-density-action="delete" onClick={() => onDelete(editing)}>
                {t("settingsWindow.density.delete")}
              </button>
            </div>
          </div>
          <DensityPreview density={editing} rows={3} />
        </div>
      )}
    </section>
  );
}
