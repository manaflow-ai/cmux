import { useEffect, useMemo, useState } from "react";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import { AgentMark } from "../../shared/AgentMark";
import type { HarnessHealth } from "../HarnessHealthNotice";
import { type StringKey, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxSnapshot } from "../model";
import type { PickerCatalog } from "../modelCatalogData";
import { harnessRows, type HarnessRow, type HarnessStatus } from "./harnessRows";
import "./harnesses.css";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

const STATUS: Record<HarnessStatus, StringKey> = {
  ready: "harnesses.ready",
  signIn: "harnesses.signedOut",
  unavailable: "harnesses.unavailable",
  notInstalled: "harnesses.notInstalled",
};

/// Integrate a harness (cx-uj5g8), in place in the pane: the agent CLIs cmux knows and their state
/// on this Mac, each with one action. Start Chat starts a chat on it in this tab; Sign In runs its
/// login in a terminal tab; Install… opens its setup page. Custom harness… starts the chat that
/// wires your own CLI in with `cmux harness guide`, in this tab and folder. Coming back from a
/// terminal tab checks the harnesses again.
export function HarnessesScreen({
  catalog,
  acpmux,
  cwd,
  callNative,
  onClose,
  onStart = onClose,
}: {
  catalog: PickerCatalog;
  acpmux: AcpmuxSnapshot["catalog"];
  /// The chat's folder: where a chat or a login from the page runs.
  cwd?: string;
  callNative: Native;
  onClose(): void;
  /// A chat starts in this tab: the page leaves (and a New Tab page becomes the chat).
  onStart?(): void;
}) {
  const t = useT();
  const [health, setHealth] = useState<Record<string, HarnessHealth | undefined>>({});
  const [checks, setChecks] = useState(0);
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
          const row = (reply as { health?: HarnessHealth | null } | null)?.health ?? undefined;
          if (live) setHealth((current) => ({ ...current, [id]: row }));
        })
        .catch(() => undefined);
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
  useEscapeCloses(true, onClose);
  const rows = harnessRows(catalog, acpmux, health);
  const inFolder = cwd ? { cwd } : {};
  const act = (row: HarnessRow) => {
    if (row.status === "signIn" && row.login) {
      // `keep`: the page stays beside the new tab and checks again on return (a page with no chat
      // yet would otherwise be replaced by it).
      void callNative("tab.open", { kind: "terminal", text: row.login, ...inFolder, run: true, keep: true }).catch(
        () => undefined,
      );
    } else if (row.status === "notInstalled" && row.docsUrl) {
      void callNative("tab.open", { kind: "browser", text: row.docsUrl, keep: true }).catch(() => undefined);
    } else if (row.status === "ready") {
      void callNative("chat.new", { harness: row.harness, ...inFolder }).catch(() => undefined);
      onStart();
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
      : row.status === "signIn"
        ? t("harnesses.signIn")
        : row.status === "notInstalled" && row.docsUrl
          ? t("harnesses.install")
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
          const label = action(row);
          return (
            <li
              key={row.harness}
              className="acpmux-harness-row"
              data-harness-row={row.harness}
              data-harness-status={row.status}
            >
              <AgentMark agent={row.mark} size={18} />
              <span className="acpmux-harness-text">
                <span className="acpmux-harness-name">{row.name}</span>
                <span className="acpmux-harness-status">{row.detail ?? t(STATUS[row.status])}</span>
              </span>
              {label && (
                <button
                  type="button"
                  className={row.status === "ready" ? "acpmux-harness-action" : "acpmux-harness-action is-primary"}
                  onClick={() => act(row)}
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
        <span className="acpmux-harness-status">{t("harnesses.customDetail")}</span>
      </button>
    </section>
  );
}
