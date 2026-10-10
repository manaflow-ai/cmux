// l10n-allow-file: sample tunables for the browser dev loop and the gallery, not shipped UI.
// An in-memory `cmux.debug.tunables` provider. It is not the backend: the app's TunableStore and
// DebugSettingsModel own values, search, clamping and the exports. The mock keeps the same op
// contract so the page runs without the app (`/debug-settings/?mock`, the gallery).
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockPageStreams } from "../shared/pageStreams";
import { formatNumber } from "./TunableControl";
import {
  DebugTunablesOps,
  type DebugSettingsState,
  type TunableControl,
  type TunableRow,
  type TunableValue,
} from "./types";

export interface MockTunable {
  key: string;
  section: string;
  label: string;
  help: string;
  control: TunableControl;
  default: TunableValue;
}

export interface MockSection {
  id: string;
  title: string;
  symbol: string;
}

export const SAMPLE_SECTIONS: MockSection[] = [
  { id: "dropOverlay", title: "Drop Overlay", symbol: "square.dashed.inset.filled" },
  { id: "springs", title: "Springs", symbol: "waveform.path" },
  { id: "glass", title: "Glass and Overlays", symbol: "drop" },
  { id: "browser", title: "Browser", symbol: "globe" },
  { id: "pages", title: "Pages", symbol: "doc.richtext" },
];

const SWATCHES = [
  { value: "textPrimary", title: "textPrimary", swatch: "#E6E6E6" },
  { value: "glassTint", title: "glassTint", swatch: "#8A8F98" },
  { value: "attention", title: "attention", swatch: "#E5A50A" },
  { value: "danger", title: "danger", swatch: "#E5484D" },
];

export const SAMPLE_TUNABLES: MockTunable[] = [
  {
    key: "drop.overlay.opacity",
    section: "dropOverlay",
    label: "Opacity",
    help: "How strongly the drop target shows while a tab is dragged.",
    control: { type: "number", min: 0, max: 1, step: 0.05, unit: "fraction" },
    default: 1,
  },
  {
    key: "drop.overlay.inset",
    section: "dropOverlay",
    label: "Inset",
    help: "Space between the pane edge and the drop target.",
    control: { type: "number", min: 0, max: 24, step: 0.5, unit: "points" },
    default: 6,
  },
  {
    key: "drop.overlay.color",
    section: "dropOverlay",
    label: "Fill color",
    help: "Theme role of the drop target fill.",
    control: { type: "color", options: SWATCHES },
    default: "glassTint",
  },
  {
    key: "motion.spring.move",
    section: "springs",
    label: "Move",
    help: "Spring of panes and tabs that move to a new place.",
    control: {
      type: "spring",
      response: { min: 0.02, max: 1, step: 0.005, unit: "seconds", label: "Response" },
      damping: { min: 0.1, max: 1.2, step: 0.01, unit: "multiplier", label: "Damping" },
    },
    default: { response: 0.32, dampingFraction: 0.86 },
  },
  {
    key: "browser.omnibar.glassDesign",
    section: "browser",
    label: "Omnibar glass design",
    help: "The address bar's look while it is focused.",
    control: {
      type: "choice",
      options: [
        { value: "flat", title: "Flat" },
        { value: "glass", title: "Liquid Glass" },
        { value: "tinted", title: "Tinted glass" },
      ],
    },
    default: "glass",
  },
  {
    key: "browser.omnibar.glass.tint",
    section: "browser",
    label: "Omnibar tint",
    help: "Tint strength of the focused address bar glass.",
    control: { type: "number", min: 0, max: 1, step: 0.01, unit: "fraction" },
    default: 0.18,
  },
  {
    key: "browser.omnibar.glass.radius",
    section: "browser",
    label: "Omnibar corner radius",
    help: "Corner radius of the focused address bar.",
    control: { type: "number", min: 0, max: 24, step: 0.5, unit: "points" },
    default: 10,
  },
  {
    key: "browser.omnibar.glass.shadow",
    section: "browser",
    label: "Omnibar shadow",
    help: "Draws a soft shadow under the focused address bar.",
    control: { type: "bool", on: "On", off: "Off" },
    default: true,
  },
  {
    key: "debugSettings.surface",
    section: "pages",
    label: "Debug Settings page",
    help: "Shows Debug Settings as the React page. Reopen Debug Settings to apply.",
    control: {
      type: "choice",
      options: [
        { value: "native", title: "Native (Swift page)" },
        { value: "web", title: "Web (React page)" },
      ],
    },
    default: "web",
  },
];

const UNIT_TEXT: Record<string, (value: number) => string> = {
  points: (value) => `${formatNumber(value)} pt`,
  seconds: (value) => `${formatNumber(value)} s`,
  fraction: (value) => `${formatNumber(Math.round(value * 1000) / 10)}%`,
  multiplier: (value) => `${formatNumber(value)}×`,
  pointsPerSecond: (value) => `${formatNumber(value)} pt/s`,
  count: (value) => formatNumber(value),
};

function display(value: TunableValue, control: TunableControl): string {
  if (typeof value === "number") return control.type === "number" ? UNIT_TEXT[control.unit]!(value) : formatNumber(value);
  if (typeof value === "boolean") return control.type === "bool" ? (value ? control.on : control.off) : String(value);
  if (typeof value === "string") {
    if (control.type === "choice" || control.type === "color")
      return control.options.find((option) => option.value === value)?.title ?? value;
    return value;
  }
  return `${formatNumber(value.response)} s / ${formatNumber(value.dampingFraction)}`;
}

function clamp(value: unknown, control: TunableControl): TunableValue | null {
  switch (control.type) {
    case "number":
      return typeof value === "number" && Number.isFinite(value) ? Math.min(Math.max(value, control.min), control.max) : null;
    case "bool":
      return typeof value === "boolean" ? value : null;
    case "choice":
    case "color":
      return typeof value === "string" && control.options.some((option) => option.value === value) ? value : null;
    case "spring": {
      const spring = value as { response?: unknown; dampingFraction?: unknown } | null;
      if (typeof spring?.response !== "number" || typeof spring.dampingFraction !== "number") return null;
      return {
        response: Math.min(Math.max(spring.response, 0.02), 2),
        dampingFraction: Math.min(Math.max(spring.dampingFraction, 0.1), 1.5),
      };
    }
  }
}

const same = (a: TunableValue, b: TunableValue) => JSON.stringify(a) === JSON.stringify(b);

export class MockDebugTunablesProvider implements PageClient {
  readonly calls: Array<{ op: string; params: unknown }> = [];
  readonly overrides = new Map<string, TunableValue>();
  readonly page = new MockPageStreams();
  query = "";
  selection = "all";
  notice?: string;
  /** Set to make every call reject as if the host went away. */
  offline = false;
  private readonly changed = new Set<(data: unknown, seq: number) => void>();
  private readonly handlers = new Map<string, PageHandler>();
  private seq = 0;

  constructor(
    readonly tunables: MockTunable[] = SAMPLE_TUNABLES,
    readonly sections: MockSection[] = SAMPLE_SECTIONS,
    overrides: Record<string, TunableValue> = {},
  ) {
    for (const [key, value] of Object.entries(overrides)) this.overrides.set(key, value);
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (this.offline) throw pageError("cmux.protocol.closed", "The app is not connected.", true);
    const fields = (params ?? {}) as Record<string, unknown>;
    switch (op) {
      case DebugTunablesOps.state:
        break;
      case DebugTunablesOps.viewSet:
        if (typeof fields.selection === "string") {
          this.query = "";
          this.selection = fields.selection;
        }
        if (typeof fields.query === "string") this.query = fields.query;
        break;
      case DebugTunablesOps.set: {
        const tunable = this.tunables.find((entry) => entry.key === fields.key);
        if (!tunable) throw pageError("cmux.protocol.invalid_params", "unknown key");
        if (fields.value === null || fields.value === undefined) this.overrides.delete(tunable.key);
        else {
          const value = clamp(fields.value, tunable.control);
          if (value === null) throw pageError("cmux.protocol.invalid_params", "value does not fit");
          if (same(value, tunable.default)) this.overrides.delete(tunable.key);
          else this.overrides.set(tunable.key, value);
        }
        this.notice = undefined;
        break;
      }
      case DebugTunablesOps.reset:
        if (fields.all === true) {
          this.overrides.clear();
          this.notice = "Every tunable is back to its default.";
        } else if (typeof fields.section === "string") {
          for (const tunable of this.tunables) if (tunable.section === fields.section) this.overrides.delete(tunable.key);
          this.notice = `Reset ${this.sections.find((section) => section.id === fields.section)?.title ?? fields.section}.`;
        } else if (typeof fields.key === "string") this.overrides.delete(fields.key);
        break;
      case DebugTunablesOps.export: {
        const changes = [...this.overrides.entries()];
        this.notice = changes.length === 0 ? "Nothing differs from the defaults." : `Copied changed values as JSON (${changes.length}).`;
        this.emit();
        return { text: JSON.stringify(Object.fromEntries(changes), null, 2) } as R;
      }
      case "cmux.app.clipboard.write":
        return {} as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
    if (op !== DebugTunablesOps.state) this.emit();
    return this.state() as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const page = this.page.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (page) return page;
    if (stream !== DebugTunablesOps.changed) throw pageError("cmux.protocol.unknown_op", stream);
    const listener = onEvent as (data: unknown, seq: number) => void;
    this.changed.add(listener);
    return () => void this.changed.delete(listener);
  }

  handle(op: string, handler: PageHandler): () => void {
    this.handlers.set(op, handler);
    return () => void this.handlers.delete(op);
  }

  private emit(): void {
    const state = this.state();
    for (const listener of this.changed) listener({ state }, ++this.seq);
  }

  private row(tunable: MockTunable): TunableRow {
    const value = this.overrides.get(tunable.key) ?? tunable.default;
    return {
      key: tunable.key,
      section: tunable.section,
      label: tunable.label,
      help: tunable.help,
      control: tunable.control,
      value,
      default: tunable.default,
      changed: !same(value, tunable.default),
      value_text: display(value, tunable.control),
      default_text: `Default: ${display(tunable.default, tunable.control)}`,
    };
  }

  state(): DebugSettingsState {
    const rows = this.tunables.map((tunable) => this.row(tunable));
    const needle = this.query.trim().toLowerCase();
    const visible = rows.filter((row) => {
      if (needle) {
        const hit = [row.key, row.label, row.help].some((text) => text.toLowerCase().includes(needle));
        return hit && (this.selection !== "changed" || row.changed);
      }
      if (this.selection === "all") return true;
      if (this.selection === "changed") return row.changed;
      return row.section === this.selection;
    });
    return {
      query: this.query,
      selection: this.selection,
      total: rows.length,
      changed: rows.filter((row) => row.changed).length,
      visible: visible.length,
      notice: this.notice,
      sections: this.sections.map((section) => ({
        ...section,
        count: rows.filter((row) => row.section === section.id).length,
        changed: rows.filter((row) => row.section === section.id && row.changed).length,
      })),
      groups: this.sections
        .map((section) => ({
          id: section.id,
          title: section.title,
          rows: visible.filter((row) => row.section === section.id),
        }))
        .filter((group) => group.rows.length > 0),
    };
  }
}
