// Personalization > Customization Problems (cmux-customize `library/doctor.rs`, design
// customize-doctor.md). Leo, 2026-11-19: "cmux for themes customizations and whatnot if there's
// errant files etc that affect customizations it should be able to automatically tell the user and
// inform them". The engine finds every finding and words it; this file only decides what the card
// and the notice draw from its report.
import type { DoctorFinding, DoctorFix, DoctorReport } from "./ops";

/** Where the one-line notice draws (gallery `pages.settings-customize-doctor`): `inline`, the line and
 * a count in the card's own header only (shipped); `banner`, a warning Notice across the top of the
 * Settings column. The sidebar draws none (Lawrence 2026-11-23: the "29 things change your
 * customization" chip under the categories, "remove this thing"). */
export type DoctorTreatment = "banner" | "inline";

let treatment: DoctorTreatment = "inline";

/** The treatment the page draws. Choosing another is this one line (or the gallery's variant). */
export function doctorTreatment(): DoctorTreatment {
  return treatment;
}

/** The gallery and tests draw the page with another treatment; the app never calls this. */
export function setDoctorTreatment(next: DoctorTreatment): void {
  treatment = next;
}

/** The route focus that opens Personalization on the card (the notice's Review, the native toast). */
export const DOCTOR_FOCUS = "card.customizeDoctor";

/** The findings the person has not dismissed. */
export function openFindings(report: DoctorReport | null | undefined): DoctorFinding[] {
  return (report?.findings ?? []).filter((finding) => !finding.dismissed);
}

/** Whether anything draws: a finding that is not dismissed. With none the card and the notice draw
 * nothing, so the end state is the start state. */
export function doctorShown(report: DoctorReport | null | undefined): boolean {
  return openFindings(report).length > 0;
}

/** The card's order: what is not dismissed first (warnings, then info), dismissed ones last, muted. */
export function orderedFindings(report: DoctorReport): DoctorFinding[] {
  const rank = (finding: DoctorFinding) => (finding.dismissed ? 2 : finding.level === "warning" ? 0 : 1);
  return [...report.findings].sort((a, b) => rank(a) - rank(b));
}

/** The fixes the page can run, in the CLI's order: `open` (the host opens the path), `off`, and
 * `follow-default` (runs at once: the CLI keeps a copy of the settings file), `remove` and `restore`
 * (both asked first). A kind this page does not know draws no button. */
export function runnableFixes(finding: DoctorFinding): DoctorFix[] {
  return finding.fixes.filter((fix) => RUNNABLE.has(fix.kind));
}

const RUNNABLE: ReadonlySet<string> = new Set(["open", "off", "follow-default", "remove", "restore"]);

/** Whether a fix asks first: every `remove` and `restore`, and any fix the CLI marks `confirm`. */
export function asksFirst(fix: DoctorFix): boolean {
  return fix.confirm || fix.kind === "remove" || fix.kind === "restore";
}

/** The route focus that opens the card with Recover's question open (the notice's Recover…). */
export const DOCTOR_RECOVER_FOCUS = "card.customizeDoctor.recover";

/** What the remove question names: the file or folder (the place without its line). */
export function removeName(finding: DoctorFinding): string {
  return finding.place.replace(/:\d+$/, "");
}
