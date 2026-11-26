// l10n-allow-file: sample findings (titles, details and fix labels are the CLI's words), not shipped UI.
// `cmux --json customize doctor` as it answers (cmux-customize `library/doctor.rs`; contract in the
// customize doctor design), for the mock host, the gallery and tests. `runDoctor` runs a verb the
// way the CLI does: a fix or a dismiss answers the report after it, an unknown id or a fix the
// finding does not offer is the CLI's error envelope.
import type { DoctorFinding, DoctorFixed, DoctorRecover, DoctorRecovered, DoctorReport, DoctorRun } from "./ops";

type Seed = Omit<DoctorFinding, "fingerprint" | "dismissed" | "path" | "line" | "level"> &
  Partial<Pick<DoctorFinding, "path" | "line" | "level" | "dismissed">>;

const finding = (seed: Seed): DoctorFinding => ({
  level: "warning",
  path: null,
  line: null,
  dismissed: false,
  fingerprint: `fp-${seed.id}`,
  ...seed,
});

const OFF = { kind: "off", label: "Turn off", confirm: false } as const;
const OPEN = { kind: "open", label: "Open", confirm: false } as const;
const REMOVE = { kind: "remove", label: "Remove", confirm: true } as const;
const RESTORE = { kind: "restore", label: "Restore last good", confirm: true } as const;

/** Every kind the doctor reports, one finding each, warnings first. */
export const DOCTOR_FINDINGS: Record<string, DoctorFinding> = {
  layer: finding({
    id: "layer-on:pr-45206",
    kind: "layer-on",
    title: "pr-45206 is still on",
    detail: "It serves PR #45206's web pages (@dbb1e3e) in place of your build's, on 3 hours.",
    place: "Customization Library",
    fixes: [OFF],
  }),
  broken: finding({
    id: "broken:themes/night.json",
    kind: "broken",
    title: "themes/night.json does not load",
    detail: "malformed JSON at line 3, column 11. cmux keeps showing the last version that loaded.",
    place: "themes/night.json:3",
    path: "/Users/me/.config/cmux/themes/night.json",
    line: 3,
    fixes: [RESTORE, OPEN],
  }),
  overlay: finding({
    id: "web-dev-overlay:web-dev.json",
    kind: "web-dev-overlay",
    title: "A web-dev overlay is on",
    detail: "web-dev.json points the app's pages at http://localhost:5173, which is not running.",
    place: "web-dev.json",
    path: "/Users/me/.config/cmux/web-dev.json",
    fixes: [OFF, OPEN],
  }),
  shadowed: finding({
    id: "shadowed:appearance.theme",
    kind: "shadowed",
    title: "Your theme is set twice",
    detail: "cmux-next.json sets appearance.theme, and the library entry night sets it again and wins.",
    place: "cmux-next.json:12",
    path: "/Users/me/.config/cmux/cmux-next.json",
    line: 12,
    fixes: [OPEN],
  }),
  oldBuild: finding({
    id: "old-build:sha-4b1e9c0",
    kind: "old-build",
    title: "sha-4b1e9c0 pins code this app already has",
    detail: "Your build already includes @4b1e9c0, so the layer changes nothing.",
    place: "Customization Library",
    fixes: [OFF],
  }),
  ignored: finding({
    id: "ignored:themes/.night.json.swp",
    kind: "ignored",
    level: "info",
    title: "themes/.night.json.swp is skipped",
    detail: "An editor's swap file: cmux does not read it.",
    place: "themes/.night.json.swp",
    path: "/Users/me/.config/cmux/themes/.night.json.swp",
    fixes: [REMOVE, OPEN],
  }),
  leftover: finding({
    id: "leftover:layers/branch-sidebar-tint",
    kind: "leftover",
    level: "info",
    title: "Files left from branch:sidebar-tint",
    detail: "The layer was removed; its folder (2.1 MB) is still there.",
    place: "layers/branch-sidebar-tint",
    path: "/Users/me/.config/cmux/layers/branch-sidebar-tint",
    fixes: [REMOVE, OPEN],
  }),
  unknownKey: finding({
    id: "unknown-key:sidebar.compactRows",
    kind: "unknown-key",
    level: "info",
    title: "sidebar.compactRows is not a setting",
    detail: "No setting has this key; it may be from an older cmux.",
    place: "cmux-next.json:20",
    path: "/Users/me/.config/cmux/cmux-next.json",
    line: 20,
    fixes: [OPEN],
  }),
  wrongFolder: finding({
    id: "wrong-folder:theme/dusk.json",
    kind: "wrong-folder",
    level: "info",
    title: "theme/dusk.json is where cmux does not look",
    detail: "Themes load from themes/, not theme/.",
    place: "theme/dusk.json",
    path: "/Users/me/.config/cmux/theme/dusk.json",
    fixes: [OPEN, REMOVE],
  }),
  override: finding({
    id: "override:cmux-tui.json",
    kind: "override",
    level: "info",
    title: "cmux-tui.json changes the terminal",
    detail: "It sets terminal.scrollback outside your settings, so Settings shows a value that is not in use.",
    place: "cmux-tui.json",
    path: "/Users/me/.config/cmux/cmux-tui.json",
    fixes: [OPEN],
  }),
};

/** The way back the CLI plans for `findings`: every layer and overlay that is on goes off, and a
 * broken file with a version that loaded puts back generation 12. Null when there is nothing. */
export function recoverPlan(findings: readonly DoctorFinding[]): DoctorRecover | null {
  const open = findings.filter((one) => !one.dismissed);
  const layers = open.filter((one) => one.kind === "layer-on").map((one) => one.id.slice(one.id.indexOf(":") + 1));
  const overlay = open.some((one) => one.kind === "web-dev-overlay");
  const restore = open.some((one) => one.kind === "broken" && one.fixes.some((fix) => fix.kind === "restore"));
  if (layers.length === 0 && !overlay && !restore) return null;
  const parts = [
    ...(layers.length > 0 ? [`turns ${layers.join(", ")} off`] : []),
    ...(overlay ? ["turns the web-dev overlay off"] : []),
    ...(restore ? ["puts back generation 12 (compact sidebar)"] : []),
  ];
  return {
    layers,
    overlay,
    generation: restore ? 12 : null,
    generation_label: restore ? "compact sidebar" : null,
    said: `Recover ${parts.join(", ")}; what is live now is kept.`,
  };
}

/** The line the CLI writes for the warnings that are not dismissed (null for none): info findings
 * never count. */
export function doctorLine(findings: readonly DoctorFinding[]): string | null {
  const open = findings.filter((one) => !one.dismissed && one.level === "warning");
  if (open.length === 0) return null;
  if (open.length === 1) return `Customization: ${open[0]!.title}`;
  const names = open.slice(0, 2).map((one) => one.title);
  const more = open.length > 2 ? ` and ${open.length - 2} more` : "";
  return `${open.length} customization problems: ${names.join("; ")}${more}`;
}

/** A report of `findings`, its line computed as the CLI does. */
export function report(findings: readonly DoctorFinding[]): DoctorReport {
  return {
    findings: findings.map((one) => ({ ...one })),
    line: doctorLine(findings),
    announce: null,
    recover: recoverPlan(findings),
  };
}

/** A theme set twice (the one problem, with no way back to plan) and a file that changes cmux from
 * outside its settings (info, listed under it). */
export const mockOverrideDoctor = (): DoctorReport => report([DOCTOR_FINDINGS.shadowed!, DOCTOR_FINDINGS.override!]);

/** No findings: the start and the end state. */
export const mockEmptyDoctor = (): DoctorReport => report([]);

/** A stale PR layer that is still on, a theme file that does not load, and a key cmux does not know
 * (info: listed, never counted). */
export const mockDoctor = (): DoctorReport =>
  report([DOCTOR_FINDINGS.layer!, DOCTOR_FINDINGS.broken!, DOCTOR_FINDINGS.unknownKey!]);

/** One finding of every kind. */
export const mockAllDoctor = (): DoctorReport => report(Object.values(DOCTOR_FINDINGS));

/** The stale layer and the broken theme, with the broken theme dismissed. */
export const mockDismissedDoctor = (): DoctorReport =>
  report([DOCTOR_FINDINGS.layer!, { ...DOCTOR_FINDINGS.broken!, dismissed: true }, DOCTOR_FINDINGS.leftover!]);

/** A refusal in the CLI's envelope. */
export type DoctorRefusal = { code: string; message: string };

/** Runs one doctor verb on `doctor` the way the CLI does. */
export function runDoctor(
  doctor: DoctorReport,
  run: DoctorRun,
): { doctor: DoctorReport; fixed?: DoctorFixed; recovered?: DoctorRecovered } | DoctorRefusal | Record<string, never> {
  if (run.verb === "doctor") return { doctor };
  if (run.verb === "doctor-recover") {
    const plan = doctor.recover;
    if (!plan) return { code: "customize.doctor.recover", message: "there is nothing to recover" };
    const gone = (one: DoctorFinding) =>
      !one.dismissed &&
      ((one.kind === "layer-on" && plan.layers.some((layer) => one.id.endsWith(`:${layer}`))) ||
        (one.kind === "web-dev-overlay" && plan.overlay) ||
        (one.kind === "broken" && plan.generation !== null && one.fixes.some((fix) => fix.kind === "restore")));
    const said = [
      ...plan.layers.map((layer) => `Turned off ${layer}.`),
      ...(plan.overlay ? ["Turned off the web-dev overlay."] : []),
      ...(plan.generation !== null ? [`Put back generation ${plan.generation}; what was live is kept as 13.`] : []),
    ];
    return {
      doctor: report(doctor.findings.filter((one) => !gone(one))),
      recovered: {
        turned_off: plan.layers,
        overlay_off: plan.overlay,
        restored: plan.generation,
        kept_as: plan.generation !== null ? 13 : null,
        said,
      },
    };
  }
  const found = doctor.findings.find((one) => one.id === run.id);
  if (!found) return { code: "customize.doctor.unknown", message: `there is no finding "${run.id}"` };
  if (run.verb === "doctor-open") return {};
  if (run.verb === "doctor-dismiss")
    return { doctor: report(doctor.findings.map((one) => (one.id === run.id ? { ...one, dismissed: true } : one))) };
  if (run.verb !== "doctor-fix") return {};
  const kind = run.fix;
  if (!found.fixes.some((fix) => fix.kind === kind))
    return { code: "customize.doctor.fix", message: `"${found.title}" has no ${kind} fix` };
  const name = found.id.slice(found.id.indexOf(":") + 1);
  const kept = run.fix !== "off" && found.path ? `/Users/me/.local/state/cmux/doctor/removed/1/${name}` : null;
  const said =
    run.fix === "remove"
      ? `Moved ${name} aside; a copy is kept.`
      : run.fix === "restore"
        ? `Put back the last ${name} that loaded; the broken text is kept.`
        : `Turned off ${name}.`;
  return {
    doctor: report(doctor.findings.filter((one) => one.id !== run.id)),
    fixed: { id: run.id, kind: run.fix, kept, said },
  };
}
