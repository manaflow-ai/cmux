// The doctor's one-line notice and the banner slot SettingsApp draws on every section: kept out of
// CustomizeDoctorCard so the page's startup script carries no card module (lazyCards.test.ts).
import { useQuery } from "@tanstack/react-query";
import { Notice, type NoticeAction } from "../../../ui/Notice";
import { useSettingsRouter, useStore } from "../context";
import {
  DOCTOR_FOCUS,
  DOCTOR_RECOVER_FOCUS,
  doctorTreatment,
  openProblems,
  type DoctorTreatment,
} from "../customizeDoctor";
import type { DoctorReport } from "../ops";
import { sectionHref } from "../router";
import { doctorQuery } from "../sectionQueries";
import { t } from "../strings";

/** The one-line notice: the CLI's `line`, with Review that opens the card and Recover… while the
 * report has a way back (it opens the card with Recover's question, so it is still asked first).
 * `banner`: a warning Notice across the top of the Settings column; `inline`: the count and the line
 * in the card's header (already at the card, whose own Recover… is beside it). Draws nothing while
 * `line` is null. */
export function DoctorNotice({
  treatment,
  report,
  onReview,
  onRecover,
}: {
  treatment: DoctorTreatment;
  report: DoctorReport | null | undefined;
  onReview?: () => void;
  onRecover?: () => void;
}) {
  const line = report?.line ?? null;
  const count = openProblems(report).length;
  if (!line || count === 0) return null;
  const recover = report?.recover ? onRecover : undefined;
  if (treatment === "banner") {
    const actions: NoticeAction[] = [
      { id: "review", label: t("settingsPage.customizeDoctor.review"), onSelect: onReview },
    ];
    if (recover) actions.push({ id: "recover", label: t("settingsPage.customizeDoctor.recover"), onSelect: recover });
    return (
      <div className="doctor-banner" data-doctor-notice="banner">
        <Notice kind="warning" placement="banner" message={line} actions={actions} />
      </div>
    );
  }
  return (
    <div className="doctor-inline" data-doctor-notice="inline">
      <span className="doctor-count" data-count={count}>
        {count}
      </span>
      <span className="row-help doctor-line">{line}</span>
    </div>
  );
}

/** The notice where the page draws it (SettingsApp): `place` is the treatment this slot holds, so
 * only the chosen one draws, and another treatment's slot reads nothing. */
export function DoctorNoticeSlot({ place }: { place: "banner" }) {
  return doctorTreatment() === place ? <DoctorNoticeRead place={place} /> : null;
}

function DoctorNoticeRead({ place }: { place: "banner" }) {
  const store = useStore();
  const router = useSettingsRouter();
  const query = useQuery(doctorQuery(store));
  return (
    <DoctorNotice
      treatment={place}
      report={query.data}
      onReview={() => router.history.push(sectionHref("personalization", DOCTOR_FOCUS))}
      onRecover={() => router.history.push(sectionHref("personalization", DOCTOR_RECOVER_FOCUS))}
    />
  );
}
