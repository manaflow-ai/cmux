import { useEffect, useMemo, useRef, useState } from "react";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import { AgentMark } from "../../shared/AgentMark";
import { type HarnessHealth, needsLogin } from "../HarnessHealthNotice";
import { type StringKey, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";
import { cleanShellOutput } from "../shell/shellRuns";
import { harnessRows, type HarnessRow, type HarnessStatus } from "./harnessRows";
import "./harnesses.css";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

const STATUS: Record<HarnessStatus, StringKey> = {
  ready: "harnesses.ready",
  signIn: "harnesses.signedOut",
  unavailable: "harnesses.unavailable",
  notInstalled: "harnesses.notInstalled",
  checking: "harnesses.checking",
};

/// What a row is doing in place: a command running (an install or an update, `line` its last
/// output line), a command that failed (`reason` its last line), a command that finished (the row
/// says so if acpmux still cannot run the harness), or a sign-in in a terminal tab the page waits for.
type Progress =
  | { kind: "installing"; line?: string }
  /// `retrySignIn`: a rejected sign-in terminal, retried with its saved `login`; `retryLaunch`: a
  /// rejected Start Chat, retried with the row's action.
  | { kind: "failed"; reason: string; retrySignIn?: boolean; login?: string; retryLaunch?: boolean }
  | { kind: "done" }
  | { kind: "waiting" }
  | { kind: "launching" };

type HostRead = { output?: string; next?: number; exit?: { code?: number; signal?: number } };

/// How long the page waits for a sign-in started from it.
const SIGN_IN_WAIT_MS = 3 * 60 * 1000;
/// Output kept to find the last line.
const TAIL = 4096;

const lastLine = (text: string) =>
  cleanShellOutput(text)
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1);

/// Integrate a harness (cx-uj5g8), in place in the pane: the agent CLIs cmux knows and their state
/// on this Mac, each with one action. Start Chat starts a chat on it in this tab; Sign In runs its
/// login in a terminal tab and the row waits for it; Install… runs its install command in place
/// (its setup page when it has none) and then has acpmux look for it again; a harness acpmux cannot
/// run offers one fix (cx-apoko). Custom harness… starts the chat that wires your own CLI in with
/// `cmux harness guide`, in this tab and folder. Coming back from a terminal tab checks the
/// harnesses again.
export function HarnessesScreen({
  catalog,
  acpmux,
  cwd,
  callNative,
  onClose,
  onStart = onClose,
  onStartChat,
  checking = false,
  refreshCatalog,
  signInPollMs = 3000,
}: {
  catalog: PickerCatalog;
  acpmux: AcpmuxSnapshot["catalog"];
  /// acpmux has not answered with its harnesses yet (the first open after a launch).
  checking?: boolean;
  /// Reads the harness catalog again, after acpmux looked for harnesses again.
  refreshCatalog?(): Promise<void>;
  /// How often a sign-in started from the page is checked.
  signInPollMs?: number;
  /// The chat's folder: where a chat or a login from the page runs.
  cwd?: string;
  callNative: Native;
  onClose(): void;
  /// A chat starts in this tab: the page leaves (and a New Tab page becomes the chat).
  onStart?(): void;
  /// A New Tab setup request continues its pending draft instead of creating an empty chat.
  onStartChat?(harness: string): void;
}) {
  const t = useT();
  const [health, setHealth] = useState<Record<string, HarnessHealth | undefined>>({});
  const [checks, setChecks] = useState(0);
  const [progress, setProgress] = useState<Record<string, Progress | undefined>>({});
  const live = useRef(true);
  const launching = useRef(new Set<string>());
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  const mark = (harness: string, next: Progress | undefined) => {
    if (live.current) setProgress((current) => ({ ...current, [harness]: next }));
  };
  const remember = (harness: string, reply: unknown) => {
    const row = (reply as { health?: HarnessHealth | null } | null)?.health ?? {
      id: harness,
      auth: "unknown" as const,
    };
    if (live.current) setHealth((current) => ({ ...current, [harness]: row }));
    return row;
  };
  useEffect(() => {
    // A failed terminal launch can race with a health refresh that reports the harness ready.
    // Reconcile that completed state so the stale failure cannot keep the row stuck on Sign In.
    setProgress((current) => {
      let changed = false;
      const next = { ...current };
      for (const [harness, state] of Object.entries(current)) {
        if (state?.kind === "failed" && state.retrySignIn && health[harness]?.auth === "signedIn") {
          next[harness] = undefined;
          changed = true;
        }
      }
      return changed ? next : current;
    });
  }, [health, progress]);
  const installed = useMemo(
    () =>
      catalog.harnesses
        .filter((entry) => entry.installed && entry.pickable)
        .map((entry) => entry.acpmuxHarness ?? entry.id)
        .join("\n"),
    [catalog],
  );
  useEffect(() => {
    let live = true;
    for (const id of installed ? installed.split("\n") : [])
      void callNative("harness.health", { id, ...(checks > 0 ? { refresh: true } : {}) })
        .then((reply) => {
          const row = (reply as { health?: HarnessHealth | null } | null)?.health ?? {
            id,
            auth: "unknown" as const,
          };
          if (live) setHealth((current) => ({ ...current, [id]: row }));
        })
        .catch(() => {
          // A failed health read is not evidence of a usable harness. Keep the row actionable.
          if (live) setHealth((current) => ({ ...current, [id]: { id, auth: "unknown" } }));
        });
    return () => {
      live = false;
    };
  }, [callNative, installed, checks]);
  useEffect(() => {
    // After a Sign In ran in a terminal tab, coming back checks again.
    const recheck = () => setChecks((count) => count + 1);
    window.addEventListener("focus", recheck);
    return () => window.removeEventListener("focus", recheck);
  }, []);
  const waiting = Object.keys(progress)
    .filter((harness) => progress[harness]?.kind === "waiting")
    .join("\n");
  useEffect(() => {
    // A sign-in started here: checked until it lands (the row turns ready) or the wait ends.
    if (!waiting) return;
    const ids = waiting.split("\n");
    const ends = Date.now() + SIGN_IN_WAIT_MS;
    let busy = false;
    const timer = setInterval(() => {
      if (busy) return;
      if (Date.now() > ends) {
        for (const id of ids) mark(id, undefined);
        return;
      }
      busy = true;
      void Promise.all(
        ids.map((id) =>
          callNative("harness.health", { id, refresh: true })
            .then((reply) => {
              if (!needsLogin(remember(id, reply)?.auth)) mark(id, undefined);
            })
            .catch(() => {
              remember(id, { health: { id, auth: "unknown" } });
              mark(id, undefined);
            }),
        ),
      ).finally(() => {
        busy = false;
      });
    }, signInPollMs);
    return () => clearInterval(timer);
  }, [callNative, waiting, signInPollMs]);
  useEscapeCloses(true, onClose);
  const rows = harnessRows(catalog, acpmux, health, checking);
  const inFolder = cwd ? { cwd } : {};
  const openDocs = (row: HarnessRow) =>
    void callNative("tab.open", { kind: "browser", text: row.docsUrl, keep: true }).catch(() => undefined);
  /// acpmux looks for harnesses again (PATH and profiles, `rescan`), and the page reads its catalog.
  const rescan = async (row: HarnessRow) => {
    try {
      remember(row.harness, await callNative("harness.health", { id: row.harness, refresh: true, rescan: true }));
      await refreshCatalog?.();
    } catch {
      // The row shows what the catalog says.
    }
  };
  /// Runs an install or update command in place: the row shows its last output line, and when it
  /// ends well acpmux looks for the harness again; otherwise the row says why.
  const runInPlace = (row: HarnessRow, command: string) => {
    mark(row.harness, { kind: "installing" });
    void (async () => {
      let tail = "";
      try {
        // Straight from the click: the host runs a command only on the user's gesture.
        const started = (await callNative("shell.run", { command, ...inFolder })) as { id: string };
        let after = 0;
        for (;;) {
          const read = (await callNative("shell.read", { id: started.id, after })) as HostRead;
          // The page closed: the command stops with it (another open offers Install again).
          if (!live.current) {
            if (!read.exit) void callNative("shell.stop", { id: started.id }).catch(() => undefined);
            return;
          }
          after = read.next ?? after;
          if (read.output) {
            tail = (tail + read.output).slice(-TAIL);
            const line = lastLine(tail);
            mark(row.harness, { kind: "installing", ...(line ? { line } : {}) });
          }
          if (read.exit) {
            if (read.exit.code !== 0) throw new Error(lastLine(tail) ?? t("harnesses.commandFailed"));
            break;
          }
        }
        if (!live.current) return;
        await rescan(row);
        mark(row.harness, { kind: "done" });
      } catch (error) {
        mark(row.harness, {
          kind: "failed",
          reason: error instanceof Error ? error.message : String(error),
        });
      }
    })();
  };
  const checkAgain = (row: HarnessRow) => {
    mark(row.harness, { kind: "installing" });
    void rescan(row).then(() => mark(row.harness, { kind: "done" }));
  };
  /// The one fix a row acpmux cannot run offers: its update when acpmux has one that needs no
  /// admin rights (through the channel it was installed with), its setup page, or another look.
  const fix = (row: HarnessRow): { label: string; run(): void } => {
    const update = health[row.harness]?.update;
    if (update?.command && !update.elevated)
      return { label: t("harnesses.update"), run: () => runInPlace(row, update.command) };
    if (row.docsUrl) return { label: t("harnesses.setupGuide"), run: () => openDocs(row) };
    return { label: t("harnesses.checkAgain"), run: () => checkAgain(row) };
  };
  /// Opens a terminal or chat on the host: the row spins (its action disabled) until the host
  /// answers, a second click while it does is ignored, and a rejection stays on the row with its
  /// reason and a retry (`failure`) instead of waiting for a tab that never opened.
  const launch = (
    row: HarnessRow,
    method: string,
    params: Record<string, unknown>,
    started: () => void,
    failure: Partial<Extract<Progress, { kind: "failed" }>>,
  ) => {
    if (launching.current.has(row.harness)) return;
    launching.current.add(row.harness);
    mark(row.harness, { kind: "launching" });
    void callNative(method, params).then(
      () => {
        launching.current.delete(row.harness);
        if (live.current) started();
      },
      (error) => {
        launching.current.delete(row.harness);
        mark(row.harness, {
          ...failure,
          kind: "failed",
          reason: error instanceof Error ? error.message : String(error),
        });
      },
    );
  };
  const retrySignIn = (row: HarnessRow, login: string) =>
    // Keep the original login command. A health refresh can make the row ready before this button
    // is clicked; routing through act(row) then starts a chat instead of retrying the login.
    launch(
      row,
      "tab.open",
      { kind: "terminal", text: login, ...inFolder, run: true, keep: true },
      () => mark(row.harness, { kind: "waiting" }),
      { retrySignIn: true, login },
    );
  const act = (row: HarnessRow) => {
    if (row.status === "signIn" && row.login) {
      // `keep`: the page stays beside the new tab and checks again on return (a page with no chat
      // yet would otherwise be replaced by it).
      retrySignIn(row, row.login);
    } else if (row.status === "signIn") {
      // Signed-out evidence without a command must never fall through to Start Chat.
      fix(row).run();
    } else if (row.status === "notInstalled" && row.install) {
      runInPlace(row, row.install);
    } else if (row.status === "notInstalled" && row.docsUrl) {
      openDocs(row);
    } else if (row.status === "unavailable") {
      fix(row).run();
    } else if (row.status === "ready") {
      if (onStartChat) return onStartChat(row.harness);
      launch(
        row,
        "chat.new",
        { harness: row.harness, ...inFolder },
        () => {
          mark(row.harness, undefined);
          onStart();
        },
        { retryLaunch: true },
      );
    }
  };
  const custom = () => {
    onStart();
    void (async () => {
      await callNative("chat.new", inFolder);
      await callNative("chat.send", { text: t("harnesses.customRequest") });
    })().catch(() => undefined);
  };
  const action = (row: HarnessRow): string | undefined =>
    row.status === "ready"
      ? t("harnesses.startChat")
      : row.status === "signIn" && row.login
        ? t("harnesses.signIn")
        : row.status === "signIn"
          ? fix(row).label
          : row.status === "notInstalled" && (row.install || row.docsUrl)
            ? t("harnesses.install")
            : row.status === "unavailable"
              ? fix(row).label
              : undefined;
  return (
    <section className="acpmux-harnesses" aria-label={t("harnesses.title")}>
      <header className="acpmux-harnesses-head">
        <div className="acpmux-harnesses-heading">
          <h2>{t("harnesses.title")}</h2>
          <p>{t("harnesses.subtitle")}</p>
        </div>
        <button type="button" className="acpmux-harnesses-close" aria-label={t("harnesses.close")} onClick={onClose}>
          <Icon name="action.close" size={14} />
        </button>
      </header>
      <ul className="acpmux-harnesses-list">
        {rows.map((row) => {
          const finished = progress[row.harness];
          // A command that finished while acpmux still cannot run the harness reads as failed.
          const stuck = finished?.kind === "done" && (row.status === "notInstalled" || row.status === "unavailable");
          const doing: Progress | undefined = stuck
            ? { kind: "failed", reason: t("harnesses.stillCannotRun") }
            : finished?.kind === "done"
              ? undefined
              : finished;
          // A failed login launch retries the login; failed installs offer setup or another look.
          const failedFix =
            doing?.kind === "failed"
              ? doing.retrySignIn && doing.login
                ? { label: t("harnesses.signIn"), run: () => retrySignIn(row, doing.login!) }
                : doing.retryLaunch && action(row)
                  ? { label: action(row)!, run: () => act(row) }
                  : row.docsUrl
                    ? { label: t("harnesses.setupGuide"), run: () => openDocs(row) }
                    : { label: t("harnesses.checkAgain"), run: () => checkAgain(row) }
              : undefined;
          const label =
            doing?.kind === "installing" || doing?.kind === "waiting" ? undefined : (failedFix?.label ?? action(row));
          // acpmux's reason can run to several lines: the row shows the first, the tooltip all.
          const status =
            doing?.kind === "installing"
              ? (doing.line ?? t("harnesses.installing"))
              : doing?.kind === "failed"
                ? stuck
                  ? doing.reason
                  : t("harnesses.commandFailedBecause", { reason: doing.reason })
                : doing?.kind === "waiting" && row.status === "signIn"
                  ? t("harnesses.waitingSignIn")
                  : (row.detail?.split("\n")[0] ?? t(STATUS[row.status]));
          return (
            <li
              key={row.harness}
              className="acpmux-harness-row"
              data-harness-row={row.harness}
              data-harness-status={
                doing && (doing.kind !== "waiting" || row.status === "signIn") ? doing.kind : row.status
              }
            >
              <AgentMark agent={row.mark} size={18} reserve />
              <span className="acpmux-harness-text">
                <span className="acpmux-harness-name">{row.name}</span>
                <span
                  className="acpmux-harness-detail"
                  {...(doing?.kind === "failed" ? { title: doing.reason } : row.detail ? { title: row.detail } : {})}
                >
                  {status}
                </span>
              </span>
              {(doing?.kind === "installing" ||
                doing?.kind === "waiting" ||
                doing?.kind === "launching" ||
                row.status === "checking") && <span className="acpmux-harness-spinner" aria-hidden="true" />}
              {label && (
                <button
                  type="button"
                  className={row.status === "ready" ? "acpmux-harness-action" : "acpmux-harness-action is-primary"}
                  disabled={doing?.kind === "launching"}
                  onClick={() => (failedFix ? failedFix.run() : act(row))}
                >
                  {label}
                </button>
              )}
            </li>
          );
        })}
      </ul>
      <button type="button" className="acpmux-harnesses-custom" data-harness-custom onClick={custom}>
        <span className="acpmux-harness-name">{t("harnesses.custom")}</span>
        <span className="acpmux-harness-detail">{t("harnesses.customDetail")}</span>
      </button>
    </section>
  );
}
