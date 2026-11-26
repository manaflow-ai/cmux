// Agents (first run): a row per agent CLI with its mark, name and sign-in, and Sign In on each one
// not known to be signed in; an agent not on this Mac offers Install (its step while it runs, the
// installer's text and the vendor's page when it fails) and turns into the normal row once
// installed. One line under the list: Checking…, none found, finish in the terminal tab, or the tab
// did not open. Every row's trailing control keeps one slot, so Sign In, Install and the spinner
// swap in place and a signed-in row keeps the room its button had.
// When the host sends the providers' readiness (logins done right), the same list signs them in in
// place: Claude Code and Codex take their provider's state, status and one action (the device card,
// with the code, opens inside the row), and GitHub is one more row. Without it the list is as before.
import type { ReactNode } from "react";
import { Button } from "../../ui/Button";
import { StableLabel } from "../../ui/StableLabel";
import { StatusGlyph } from "../../ui/StatusGlyph";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { cx } from "../../ui/cx";
import type { AgentRow, AgentsState } from "./ops";
import { OPS } from "./ops";
import { HostIcon, useOnboarding } from "./parts";
import { agentDetail, agentsStatus } from "./text";
import { FAMILY_BRAND } from "../shared/signIn/accountSignIn";
import { DeviceSignInCard, ProviderMark } from "../shared/signIn/DeviceSignInCard";
import {
  READINESS_ACTION_KEY,
  agentFamily,
  readinessAction,
  readinessStatus,
  type ProviderReadinessProps,
  type ReadinessRow,
} from "../shared/signIn/ProviderReadiness";
import { useSignInStrings } from "../shared/signIn/strings";

/** How the agent list is drawn (the gallery compares them; `list` ships). */
export type AgentsLook = "cards" | "list" | "compact";
export const DEFAULT_AGENTS_LOOK: AgentsLook = "list";

/** The row's trailing control: Sign In, Install (or Try Again), the install spinner, or nothing.
 *  retry-prompt-ok: Try Again runs the agent's install again, an install the person chooses. */
type Trailing = "signIn" | "install" | "retry" | "installing" | "none";

export function trailingFor(row: AgentRow): Trailing {
  const install = row.install;
  if (install != null && install.state !== "installed") {
    if (install.state === "installing") return "installing";
    return install.state === "failed" ? "retry" : "install";
  }
  return row.offersSignIn ? "signIn" : "none";
}

function AgentListRow({ row, look }: { row: AgentRow; look: AgentsLook }) {
  const { strings, store } = useOnboarding();
  const trailing = trailingFor(row);
  const install = row.install;
  const failed = install?.state === "failed";
  const vendorURL = install != null && install.state !== "installed" ? (install.vendorURL ?? null) : null;
  const signInLabel = strings.t("onboarding.agents.signIn");
  const labels = [signInLabel, strings.t("onboarding.agents.install"), strings.t("onboarding.agents.installAgain")];
  const action = trailing === "signIn" ? "signIn" : trailing === "install" || trailing === "retry" ? "install" : null;
  // retry-prompt-ok: a failed install's Try Again installs the agent again, an install the person chooses.
  const label =
    trailing === "install"
      ? strings.t("onboarding.agents.install")
      : trailing === "retry"
        ? strings.t("onboarding.agents.installAgain")
        : signInLabel;
  return (
    <RowShell
      look={look}
      attrs={{
        "data-agent": row.id,
        "data-auth": row.auth,
        "data-install": install?.state ?? undefined,
        "data-trailing": trailing,
      }}
      mark={
        row.icon == null ? (
          <AgentMark agent={row.id} size={24} />
        ) : (
          <HostIcon image={row.icon} className="onb-agent-icon" />
        )
      }
      name={row.name}
      detail={agentDetail(strings, row)}
      failed={failed}
      // tooltip-allow: a failed install's reason shows nowhere else.
      failedTitle={failed ? (install?.message ?? undefined) : undefined}
      done={trailing === "none" && row.auth === "signedIn"}
      vendorURL={vendorURL && (failed || trailing === "install") ? vendorURL : null}
      button={
        action
          ? {
              label,
              labels,
              ariaLabel: action === "signIn" ? strings.format("onboarding.agents.signIn.named", row.name) : undefined,
              onClick: () => {
                if (action === "signIn") store.call(OPS.signIn, { id: row.id });
                else store.call(OPS.install, { id: row.id });
              },
            }
          : { label, labels, onClick: null }
      }
      spinner={trailing === "installing"}
    />
  );
}

/** A row the provider's readiness draws: Claude Code or Codex in place, or GitHub as one more row. */
function ReadinessListRow({
  ready,
  look,
  readiness,
  name,
  mark,
  agentId,
}: {
  ready: ReadinessRow;
  look: AgentsLook;
  readiness: ProviderReadinessProps;
  name: string;
  mark: ReactNode;
  agentId: string;
}) {
  const strings = useSignInStrings();
  const offered = readinessAction(ready.state);
  // GitHub's CLI has no Install here: a provider no agent row installs shows its state only.
  const action = offered === "install" && readiness.canInstall?.(ready.family) === false ? null : offered;
  const labels = (["signIn", "install", "tryAgain", "addAccount"] as const).map((key) =>
    strings.t(READINESS_ACTION_KEY[key]),
  );
  const signing = ready.state === "signingIn" && ready.view != null;
  return (
    <RowShell
      look={look}
      attrs={{
        "data-agent": agentId,
        "data-ready-family": ready.family,
        "data-ready-state": ready.state,
        "data-signing": signing ? "" : undefined,
      }}
      mark={mark}
      name={name}
      detail={readinessStatus(strings, ready)}
      failed={ready.state === "failed"}
      done={ready.state === "ready"}
      vendorURL={null}
      button={{
        label: action ? strings.t(READINESS_ACTION_KEY[action]) : labels[0]!,
        labels,
        onClick: action ? () => readiness.onAction?.(ready.family, action) : null,
        readyAction: action ?? undefined,
      }}
      spinner={ready.state === "installing"}
      below={
        signing ? (
          <div className="onb-agent-signin">
            <DeviceSignInCard family={ready.family} view={ready.view!} look="inline" {...readiness.card} />
          </div>
        ) : null
      }
    />
  );
}

/** One list row: mark, name and detail (or the compact pill), then the trailing slot. */
function RowShell({
  look,
  attrs,
  mark,
  name,
  detail,
  failed,
  failedTitle,
  done,
  vendorURL,
  button,
  spinner,
  below,
}: {
  look: AgentsLook;
  attrs: Record<string, string | undefined>;
  mark: ReactNode;
  name: string;
  detail: string;
  failed: boolean;
  failedTitle?: string;
  done: boolean;
  vendorURL: string | null;
  button: {
    label: string;
    labels: readonly string[];
    ariaLabel?: string;
    onClick: (() => void) | null;
    readyAction?: string;
  };
  spinner: boolean;
  below?: ReactNode;
}) {
  const { strings } = useOnboarding();
  const shown = button.onClick != null;
  return (
    <li className="onb-agent" {...attrs}>
      <span className="onb-agent-mark">{mark}</span>
      <span className="onb-agent-names">
        <span className="onb-agent-name">{name}</span>
        {look === "compact" ? null : (
          <span
            className={cx("onb-agent-detail", failed && "is-error")}
            // tooltip-allow: a failed install's reason shows nowhere else.
            title={failedTitle}
          >
            {detail}
          </span>
        )}
      </span>
      {look === "compact" && (
        <span
          className="onb-agent-pill"
          data-state={failed ? "error" : done ? "done" : "idle"}
          // tooltip-allow: a failed install's reason shows nowhere else.
          title={failedTitle}
        >
          {(failed || done) && <StatusGlyph name={failed ? "error" : "done"} size={12} />}
          <span>{detail}</span>
        </span>
      )}
      <span className="onb-agent-trailing">
        {vendorURL && (
          <a className="onb-link" href={vendorURL} target="_blank" rel="noreferrer">
            {strings.t("onboarding.agents.setupGuide")}
          </a>
        )}
        <span className="onb-slot">
          <Button
            variant={look === "compact" ? "ghost" : "subtle"}
            size={look === "cards" ? "md" : "sm"}
            className="onb-capsule"
            data-shown={shown ? "" : undefined}
            data-ready-action={button.readyAction}
            aria-hidden={shown ? undefined : true}
            tabIndex={shown ? undefined : -1}
            aria-label={button.ariaLabel}
            onClick={() => button.onClick?.()}
          >
            <StableLabel label={button.label} alternatives={button.labels} />
          </Button>
          <span className="onb-slot-spinner" data-shown={spinner ? "" : undefined}>
            <Spinner size={16} loading />
          </span>
        </span>
      </span>
      {below}
    </li>
  );
}

export function AgentsStep({
  agents,
  look,
  readiness,
}: {
  agents: AgentsState | null;
  look: AgentsLook;
  /** The providers' readiness (logins done right, onboarding/signInReadiness.ts): signs Claude
   * Code, Codex and GitHub in in place in this list when the host sends `signInReadiness`. */
  readiness?: ProviderReadinessProps;
}) {
  const { strings } = useOnboarding();
  const status = agentsStatus(strings, agents);
  const rows = agents?.rows ?? [];
  const readyFor = (family: string | null) =>
    family == null ? undefined : readiness?.rows.find((ready) => ready.family === family);
  // A provider no agent row stands for (GitHub, or an agent this Mac does not list) is one more row.
  const extra = (readiness?.rows ?? []).filter((ready) => !rows.some((row) => agentFamily(row.id) === ready.family));
  return (
    <div className="onb-agents">
      <div className="onb-scroll">
        <ul className="onb-agent-list" data-look={look} hidden={rows.length + extra.length === 0}>
          {rows.map((row) => {
            const ready = readiness ? readyFor(agentFamily(row.id)) : undefined;
            return ready && readiness ? (
              <ReadinessListRow
                key={row.id}
                ready={ready}
                look={look}
                readiness={readiness}
                name={row.name}
                agentId={row.id}
                mark={
                  row.icon == null ? (
                    <AgentMark agent={row.id} size={24} />
                  ) : (
                    <HostIcon image={row.icon} className="onb-agent-icon" />
                  )
                }
              />
            ) : (
              <AgentListRow key={row.id} row={row} look={look} />
            );
          })}
          {readiness &&
            extra.map((ready) => (
              <ReadinessListRow
                key={ready.family}
                ready={ready}
                look={look}
                readiness={readiness}
                name={FAMILY_BRAND[ready.family]}
                agentId={ready.family}
                mark={<ProviderMark family={ready.family} size={24} />}
              />
            ))}
        </ul>
      </div>
      <output className="onb-status" aria-live="polite">
        {status ?? ""}
      </output>
    </div>
  );
}
