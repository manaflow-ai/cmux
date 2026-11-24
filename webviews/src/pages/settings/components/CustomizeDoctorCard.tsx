// Personalization > Customization Problems (design/customize-doctor.md), above the Customization
// Library. Leo, 2026-11-19: "cmux for themes customizations and whatnot if there's errant files etc
// that affect customizations it should be able to automatically tell the user and inform them", and
// "make sure you can recover and stuff. for all customizations". `cmux customize doctor`
// (cmux-customize `library/doctor.rs`) finds and words every finding and plans the way back; this
// card lists the findings with their fixes and runs the doctor verbs through the host's bundled CLI
// on the person's click only. Remove, Restore and Recover ask first, inline, and say what is kept.
// With nothing left that is not dismissed the card draws nothing, and so does the one-line notice
// (DoctorNotice): the end state is the start state. Opened at this card by
// `#/settings/personalization?focus=card.customizeDoctor` (`.recover`: with Recover's question open).
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useLayoutEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { DismissButton } from "../../../ui/DismissButton";
import { Notice, type NoticeAction } from "../../../ui/Notice";
import { focusRoute } from "../../../ui/focusRoute";
import { useSettingsRouter, useStore } from "../context";
import {
  DOCTOR_FOCUS,
  DOCTOR_RECOVER_FOCUS,
  asksFirst,
  doctorShown,
  doctorTreatment,
  openFindings,
  orderedFindings,
  removeName,
  runnableFixes,
  type DoctorTreatment,
} from "../customizeDoctor";
import type { DoctorFinding, DoctorFix, DoctorReport, DoctorRun } from "../ops";
import { sectionHref } from "../router";
import { DOCTOR_KEY, doctorQuery } from "../sectionQueries";
import { t } from "../strings";

/** The question that is open: a finding's Remove or Restore, or the report's Recover. */
export type DoctorAsking = { finding: string; fix: "remove" | "restore" } | { recover: true } | null;

/** The card's gestures. */
export type DoctorActions = {
  /** A fix button: `open`, `off` and `follow-default` run at once; `remove` and `restore` ask first. */
  onFix: (finding: DoctorFinding, fix: DoctorFix) => void;
  onDismiss: (id: string) => void;
  /** Recover…: asks first. */
  onRecover: () => void;
  /** The open question's confirm button. */
  onConfirm: () => void;
  onCancel: () => void;
};

export function CustomizeDoctorCard({ focus = null }: { focus?: string | null }) {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery(doctorQuery(store));
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const [said, setSaid] = useState<string | null>(null);
  // The notice's Recover… opens the page here with its question open.
  const [asking, setAsking] = useState<DoctorAsking>(() => (focus === DOCTOR_RECOVER_FOCUS ? { recover: true } : null));
  // ...also when the page is already open (the route changes, the card stays mounted).
  const [routed, setRouted] = useState(focus);
  if (focus !== routed) {
    setRouted(focus);
    if (focus === DOCTOR_RECOVER_FOCUS) setAsking({ recover: true });
  }
  // As the library card: a read still on its way saw the report before this change, so it is
  // dropped before the change runs and again before the change's answer draws.
  const run = (change: DoctorRun) => {
    setBusy(true);
    setRefusal(null);
    setSaid(null);
    return queryClient
      .cancelQueries({ queryKey: DOCTOR_KEY })
      .then(() => store.customizeDoctor(change))
      .then(async (answer) => {
        await queryClient.cancelQueries({ queryKey: DOCTOR_KEY });
        if (answer.doctor) queryClient.setQueryData<DoctorReport | null>(DOCTOR_KEY, answer.doctor);
        setRefusal(answer.refusal);
        setSaid(answer.said);
      })
      .finally(() => {
        setBusy(false);
        setAsking(null);
      });
  };
  const report = query.data ?? null;
  if (!report || !doctorShown(report)) return null;
  const actions: DoctorActions = {
    onFix: (finding, fix) => {
      const asked = fix.kind === "remove" ? "remove" : fix.kind === "restore" ? "restore" : null;
      if (asked && asksFirst(fix)) setAsking({ finding: finding.id, fix: asked });
      else if (fix.kind === "open") void run({ verb: "doctor-open", id: finding.id });
      else if (fix.kind === "off") void run({ verb: "doctor-fix", id: finding.id, fix: "off" });
      else if (fix.kind === "follow-default") void run({ verb: "doctor-fix", id: finding.id, fix: "follow-default" });
    },
    onDismiss: (id) => void run({ verb: "doctor-dismiss", id }),
    onRecover: () => setAsking({ recover: true }),
    onConfirm: () => {
      if (!asking) return;
      if ("recover" in asking) void run({ verb: "doctor-recover" });
      else void run({ verb: "doctor-fix", id: asking.finding, fix: asking.fix });
    },
    onCancel: () => setAsking(null),
  };
  return (
    <CustomizeDoctorView
      report={report}
      busy={busy}
      asking={asking}
      refusal={refusal}
      said={said}
      reveal={focus === DOCTOR_FOCUS || focus === DOCTOR_RECOVER_FOCUS}
      treatment={doctorTreatment()}
      actions={actions}
    />
  );
}

/** The card as it draws, from the report: the gallery draws it with fixtures. */
export function CustomizeDoctorView({
  report,
  busy = false,
  asking = null,
  refusal = null,
  said = null,
  reveal = false,
  treatment = "inline",
  actions,
}: {
  report: DoctorReport;
  busy?: boolean;
  asking?: DoctorAsking;
  refusal?: string | null;
  /** What the last fix or Recover did, in the CLI's words. */
  said?: string | null;
  /** The route opens the page on this card: it scrolls to the card once drawn. */
  reveal?: boolean;
  treatment?: DoctorTreatment;
  actions: DoctorActions;
}) {
  const card = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    if (reveal) card.current?.scrollIntoView?.({ block: "start" });
  }, [reveal]);
  if (!doctorShown(report)) return null;
  const recover = report.recover ?? null;
  return (
    <section className="group doctor-card" data-card="customizeDoctor" id="customize-doctor" ref={card}>
      <div className="doctor-head">
        <h3 className="group-title">{t("settingsPage.customizeDoctor.title")}</h3>
        {treatment === "inline" && <DoctorNotice treatment="inline" report={report} />}
      </div>
      <div className="rows">
        <div className="row" data-doctor-help="">
          <div className="row-main">
            <span className="row-label row-help">{t("settingsPage.customizeDoctor.help")}</span>
            {recover && (
              <span className="row-control">
                <Button
                  variant="subtle"
                  size="sm"
                  className="button"
                  data-doctor-action="recover"
                  disabled={busy}
                  onClick={actions.onRecover}
                >
                  {t("settingsPage.customizeDoctor.recover")}
                </Button>
              </span>
            )}
          </div>
          {recover && asking && "recover" in asking && (
            <DoctorConfirm
              title={t("settingsPage.customizeDoctor.recoverTitle")}
              body={recover.said}
              confirm={t("settingsPage.customizeDoctor.recoverConfirm")}
              danger={false}
              busy={busy}
              actions={actions}
            />
          )}
        </div>
        {orderedFindings(report).map((finding) => (
          <DoctorFindingRow
            key={finding.id}
            finding={finding}
            busy={busy}
            asking={asking && "finding" in asking && asking.finding === finding.id ? asking.fix : null}
            actions={actions}
          />
        ))}
      </div>
      {said && (
        <output className="row-error" data-doctor-said="">
          {said}
        </output>
      )}
      {refusal && (
        <div className="row-error" role="alert" data-doctor-refusal="">
          {t("settingsPage.customizeDoctor.refused", refusal)}
        </div>
      )}
    </section>
  );
}

/** One finding: its level's dot, title, detail and place, its fixes, and Dismiss; a Remove's or
 * Restore's question opens under it. A dismissed one draws muted, with no Dismiss. */
export function DoctorFindingRow({
  finding,
  busy,
  asking,
  actions,
}: {
  finding: DoctorFinding;
  busy: boolean;
  /** The fix whose question is open on this finding, else null. */
  asking: "remove" | "restore" | null;
  actions: DoctorActions;
}) {
  const fixes = runnableFixes(finding);
  const name = removeName(finding);
  return (
    <div
      className="row doctor-finding"
      data-doctor-finding={finding.id}
      data-doctor-kind={finding.kind}
      data-level={finding.level}
      data-dismissed={finding.dismissed ? "" : undefined}
      data-dismiss-host=""
    >
      <div className="row-main">
        <span className="doctor-dot" data-level={finding.level} aria-hidden="true" />
        <div className="row-label">
          <div className="row-title selectable">
            {finding.title}
            {finding.dismissed && (
              <span className="row-help" data-doctor-dismissed="">
                {" · "}
                {t("settingsPage.customizeDoctor.dismissed")}
              </span>
            )}
          </div>
          <div className="row-help selectable doctor-detail">{finding.detail}</div>
          <div className="row-help selectable doctor-place">{finding.place}</div>
        </div>
        <span className="row-control doctor-controls">
          {fixes.map((fix) => (
            <Button
              key={fix.kind}
              variant="ghost"
              size="sm"
              className="button"
              data-doctor-fix={fix.kind}
              disabled={busy}
              onClick={() => actions.onFix(finding, fix)}
            >
              {fix.label}
            </Button>
          ))}
          {!finding.dismissed && (
            <DismissButton
              label={t("settingsPage.customizeDoctor.dismiss")}
              onDismiss={() => !busy && actions.onDismiss(finding.id)}
            />
          )}
        </span>
      </div>
      {asking === "remove" && (
        <DoctorConfirm
          title={t("settingsPage.customizeDoctor.removeTitle", name)}
          body={t("settingsPage.customizeDoctor.removeBody")}
          confirm={t("settingsPage.remove")}
          danger
          busy={busy}
          actions={actions}
        />
      )}
      {asking === "restore" && (
        <DoctorConfirm
          title={t("settingsPage.customizeDoctor.restoreTitle", name)}
          body={t("settingsPage.customizeDoctor.restoreBody")}
          confirm={
            fixes.find((fix) => fix.kind === "restore")?.label ?? t("settingsPage.customizeDoctor.recoverConfirm")
          }
          danger={false}
          busy={busy}
          actions={actions}
        />
      )}
    </div>
  );
}

/** A question, inline under what it is about, as the library's Remove is: Cancel takes focus first,
 * and the body says what is kept. Only its confirm runs the verb. */
function DoctorConfirm({
  title,
  body,
  confirm,
  danger,
  busy,
  actions,
}: {
  title: string;
  body: string;
  confirm: string;
  danger: boolean;
  busy: boolean;
  actions: DoctorActions;
}) {
  const box = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    box.current?.scrollIntoView?.({ block: "nearest" });
    focusRoute(
      box.current?.querySelector<HTMLButtonElement>('[data-doctor-action="cancel"]'),
      "person",
      "the person's Remove, Restore or Recover opened its question: Cancel",
    );
  }, []);
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div className="accounts-form" data-doctor-confirm="" role="group" aria-label={title} ref={box}>
      <div className="row-title">{title}</div>
      <div className="row-help selectable">{body}</div>
      <div className="accounts-buttons">
        <Button
          danger={danger}
          variant="ghost"
          className="button"
          data-doctor-action="confirm"
          disabled={busy}
          onClick={actions.onConfirm}
        >
          {confirm}
        </Button>
        <Button className="button" data-doctor-action="cancel" onClick={actions.onCancel}>
          {t("settingsPage.cancel")}
        </Button>
      </div>
    </div>
  );
}

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
  const count = openFindings(report).length;
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
