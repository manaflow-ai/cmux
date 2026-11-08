// Agents (first run): a row per agent CLI with its mark, name and sign-in, and Sign In on each one
// not known to be signed in; an agent not on this Mac offers Install (its step while it runs, the
// installer's text and the vendor's page when it fails) and turns into the normal row once
// installed. One line under the list: Checking…, none found, finish in the terminal tab, or the tab
// did not open. Every row's trailing control keeps one slot, so Sign In, Install and the spinner
// swap in place and a signed-in row keeps the room its button had.
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

/** How the agent list is drawn (the gallery compares them; `list` ships). */
export type AgentsLook = "cards" | "list" | "compact";
export const DEFAULT_AGENTS_LOOK: AgentsLook = "list";

/** The row's trailing control: Sign In, Install (or Try Again), the install spinner, or nothing. */
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
  const label =
    trailing === "install"
      ? strings.t("onboarding.agents.install")
      : trailing === "retry"
        ? strings.t("onboarding.agents.installAgain")
        : signInLabel;
  const detail = agentDetail(strings, row);
  const signedIn = trailing === "none" && row.auth === "signedIn";
  return (
    <li
      className="onb-agent"
      data-agent={row.id}
      data-auth={row.auth}
      data-install={install?.state ?? undefined}
      data-trailing={trailing}
    >
      <span className="onb-agent-mark">
        {row.icon == null ? (
          <AgentMark agent={row.id} size={24} />
        ) : (
          <HostIcon image={row.icon} className="onb-agent-icon" />
        )}
      </span>
      <span className="onb-agent-names">
        <span className="onb-agent-name">{row.name}</span>
        {look === "compact" ? null : (
          <span
            className={cx("onb-agent-detail", failed && "is-error")}
            title={failed ? (install?.message ?? undefined) : undefined}
          >
            {detail}
          </span>
        )}
      </span>
      {look === "compact" && (
        <span
          className="onb-agent-pill"
          data-state={failed ? "error" : signedIn ? "done" : "idle"}
          title={failed ? (install?.message ?? undefined) : undefined}
        >
          {(failed || signedIn) && <StatusGlyph name={failed ? "error" : "done"} size={12} />}
          <span>{detail}</span>
        </span>
      )}
      <span className="onb-agent-trailing">
        {vendorURL && (failed || trailing === "install") && (
          <a className="onb-link" href={vendorURL} target="_blank" rel="noreferrer">
            {strings.t("onboarding.agents.setupGuide")}
          </a>
        )}
        <span className="onb-slot">
          <Button
            variant={look === "compact" ? "ghost" : "subtle"}
            size={look === "cards" ? "md" : "sm"}
            className="onb-capsule"
            data-shown={action ? "" : undefined}
            aria-hidden={action ? undefined : true}
            tabIndex={action ? undefined : -1}
            aria-label={action === "signIn" ? strings.format("onboarding.agents.signIn.named", row.name) : undefined}
            onClick={() => {
              if (action === "signIn") store.call(OPS.signIn, { id: row.id });
              else if (action === "install") store.call(OPS.install, { id: row.id });
            }}
          >
            <StableLabel label={label} alternatives={labels} />
          </Button>
          <span className="onb-slot-spinner" data-shown={trailing === "installing" ? "" : undefined}>
            <Spinner size={16} loading />
          </span>
        </span>
      </span>
    </li>
  );
}

export function AgentsStep({ agents, look }: { agents: AgentsState | null; look: AgentsLook }) {
  const { strings } = useOnboarding();
  const status = agentsStatus(strings, agents);
  const rows = agents?.rows ?? [];
  return (
    <div className="onb-agents">
      <div className="onb-scroll">
        <ul className="onb-agent-list" data-look={look} hidden={rows.length === 0}>
          {rows.map((row) => (
            <AgentListRow key={row.id} row={row} look={look} />
          ))}
        </ul>
      </div>
      <output className="onb-status" aria-live="polite">
        {status ?? ""}
      </output>
    </div>
  );
}
