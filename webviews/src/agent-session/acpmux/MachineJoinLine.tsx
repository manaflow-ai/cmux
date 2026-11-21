import { useEffect, useState } from "react";
import { useT, type StringKey } from "./i18n";
import { confirmJoin, endJoin, joinSeconds, retryJoin, type JoinStep, type MachineJoin } from "./machineJoin";
import "./machineJoinLine.css";

/// How the line draws (MachineJoinLine.gallery.tsx compares them): `line`, quiet text under the
/// composer with its one button (shipped); `tray`, the same words on a tonal block; `steps`, the
/// four steps as dots with the running one named.
export type MachineJoinLineLook = "line" | "tray" | "steps";

const STEP_WORDS: Record<JoinStep, StringKey> = {
  reach: "composer.joinStepReach",
  token: "composer.joinStepToken",
  install: "composer.joinStepInstall",
  connect: "composer.joinStepConnect",
};

/// Each failure's one line, by acpmux's kind (cli/ssh_join.rs `Kind`); any other kind is the last.
const FAILURE_WORDS: Record<string, StringKey> = {
  needs_key: "composer.joinFailNeedsKey",
  host_key_changed: "composer.joinFailHostKey",
  unreachable: "composer.joinFailUnreachable",
  unsupported_platform: "composer.joinFailPlatform",
  hub_unreachable: "composer.joinFailHub",
  not_signed_in: "composer.joinFailSignedOut",
  no_peer: "composer.joinFailNoPeer",
};

/// The failure's button: Sign In for a refused sign-in, Add Machine… (the other ways in) for a
/// machine ssh cannot set up, else Try Again.
export function failureAction(kind: string): "signIn" | "addMachine" | "retry" {
  if (kind === "not_signed_in") return "signIn";
  if (kind === "unsupported_platform") return "addMachine";
  return "retry";
}

/// The one line under a new chat's composer while a machine picked from "Not added yet" is set up
/// (Leo, 2026-11-16: "it should not take much at all to simply spin [stuff] up"): "Setting up gcp-3
/// · installing 6 s", then the turn starts when acpmux lists the machine. A host that is not the
/// person's own tailnet node asks once here, naming the host and the login; a failure says its
/// next step in one line, with one button. It folds open and shut by its own height, so the
/// composer moves with it in one transition.
export function MachineJoinLine({
  join,
  look = "line",
  now: fixedNow,
  onSignIn,
  onAddMachine,
}: {
  join: MachineJoin | undefined;
  look?: MachineJoinLineLook;
  /// Gallery seam: a fixed clock.
  now?: number;
  onSignIn?(): void;
  onAddMachine?(): void;
}) {
  const t = useT();
  const running = join !== undefined && (join.phase === "joining" || join.phase === "joined");
  // The seconds count on between acpmux's notes: one one-shot timer per second, only while it runs.
  const [tick, setTick] = useState(() => Date.now());
  useEffect(() => {
    if (!running || fixedNow !== undefined) return;
    const timer = setTimeout(() => setTick(Date.now()), 1000);
    return () => clearTimeout(timer);
  }, [running, tick, fixedNow]);
  if (!join) return null;
  const now = fixedNow ?? Math.max(tick, join.heardAt);
  const host = join.candidate.name;
  const body = (() => {
    if (join.phase === "confirm") {
      return {
        text: join.login
          ? t("composer.joinConfirm", { host, login: join.login })
          : t("composer.joinConfirmNoLogin", { host }),
        actions: (
          <>
            <button type="button" className="acpmux-join-action" data-primary="" onClick={confirmJoin}>
              {t("composer.add")}
            </button>
            <button type="button" className="acpmux-join-action" onClick={endJoin}>
              {t("picker.setup.cancel")}
            </button>
          </>
        ),
      };
    }
    if (join.phase === "failed") {
      const kind = join.failure?.kind ?? "failed";
      const action = failureAction(kind);
      const run = action === "signIn" ? onSignIn : action === "addMachine" ? onAddMachine : retryJoin;
      return {
        text: t(FAILURE_WORDS[kind] ?? "composer.joinFailOther", { host }),
        // acpmux's own words, in English, for the person who wants the detail.
        title: [join.failure?.message, join.failure?.next].filter(Boolean).join(" · ") || undefined,
        actions: (
          <>
            {run && (
              <button type="button" className="acpmux-join-action" data-primary="" onClick={run}>
                {t(
                  action === "signIn"
                    ? "harnesses.signIn"
                    : action === "addMachine"
                      ? "composer.addMachine"
                      : "harness.tryAgain",
                )}
              </button>
            )}
            <button type="button" className="acpmux-join-action" onClick={endJoin}>
              {t("picker.setup.dismiss")}
            </button>
          </>
        ),
      };
    }
    const progress = t("composer.joinProgress", {
      host,
      step: t(STEP_WORDS[join.step]),
      seconds: joinSeconds(join, now),
    });
    return { text: join.queued ? `${progress} · ${t("composer.joinQueued")}` : progress, actions: null };
  })();
  const stepIndex = ["reach", "token", "install", "connect"].indexOf(join.step);
  return (
    <div className="acpmux-join-fold">
      <div className="acpmux-join-clip">
        <div
          className="acpmux-join-line"
          data-look={look}
          data-phase={join.phase}
          role={join.phase === "failed" ? "alert" : "status"}
          data-testid="machine-join-line"
        >
          {look === "steps" && running && (
            <span className="acpmux-join-steps" aria-hidden="true">
              {[0, 1, 2, 3].map((index) => (
                <span
                  key={index}
                  className="acpmux-join-step"
                  data-done={index < stepIndex || join.phase === "joined" ? "" : undefined}
                  data-current={index === stepIndex && join.phase === "joining" ? "" : undefined}
                />
              ))}
            </span>
          )}
          <span className="acpmux-join-text" title={"title" in body ? body.title : undefined}>
            {body.text}
          </span>
          {body.actions}
        </div>
      </div>
    </div>
  );
}
