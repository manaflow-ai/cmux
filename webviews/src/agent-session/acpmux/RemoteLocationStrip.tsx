import { ChevronIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import { remoteLocationState, type RemoteLocationState } from "./remoteLocationState";
import type { Environment } from "./environments";
import "./remoteLocationStrip.css";

/// Shares only the face/status between the two existing run-location pickers.
export function RemoteLocationStatus({
  machine,
  onReconnect,
}: {
  machine?: Environment;
  onReconnect?(peer: string): void;
}) {
  const t = useT();
  if (!machine) return null;
  const state = remoteLocationState(machine);
  const stateLabel = remoteStateLabel(state, t);
  const reconnectable = state === "offline" && onReconnect !== undefined;
  const statusProps = { "data-state": state };
  return reconnectable ? (
    <button
      type="button"
      className="acpmux-remote-location acpmux-remote-location-status acpmux-remote-location-reconnect"
      {...statusProps}
      aria-label={t("unavailable.reconnect")}
      title={t("composer.remoteReconnect", { name: machine.label })}
      onClick={() => onReconnect(machine.id)}
    >
      <span aria-hidden="true" />
      <span className="acpmux-remote-location-status-text">{stateLabel}</span>
    </button>
  ) : (
    <output
      className="acpmux-remote-location acpmux-remote-location-status"
      {...statusProps}
      aria-label={stateLabel}
      title={stateLabel}
    >
      <span aria-hidden="true" />
      <span className="acpmux-remote-location-status-text">{stateLabel}</span>
    </output>
  );
}

function remoteStateLabel(state: RemoteLocationState, t: ReturnType<typeof useT>): string {
  if (state === "connected") return t("composer.envConnected");
  if (state === "offline") return t("composer.envNotConnected");
  if (state === "connecting") return t("header.reconnecting");
  return t("composer.envStatusUnknown");
}

export function RemoteLocationFace({
  machine,
  chevron = true,
  presentation = "separated",
}: {
  machine: Environment;
  chevron?: boolean;
  presentation?: "labelled" | "compact" | "separated";
}) {
  const t = useT();
  return (
    <span className="acpmux-remote-location-face">
      <svg
        className="acpmux-icon acpmux-location-icon ui-ghost-icon"
        width={14}
        height={14}
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.25}
        aria-hidden="true"
        focusable="false"
      >
        <circle cx="8" cy="8" r="5.7" />
        <path d="M2.5 8h11M8 2.3c1.5 1.5 2.25 3.4 2.25 5.7S9.5 12.2 8 13.7C6.5 12.2 5.75 10.3 5.75 8S6.5 3.8 8 2.3Z" />
      </svg>
      {presentation !== "compact" && <span className="acpmux-remote-location-kind">{t("composer.remote")}</span>}
      {presentation === "separated" && (
        <svg
          className="acpmux-icon acpmux-location-icon ui-ghost-icon"
          width={14}
          height={14}
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          strokeWidth={1.25}
          aria-hidden="true"
          focusable="false"
        >
          <rect x="3" y="2.5" width="10" height="7.5" rx="1" />
          <path d="M1.5 12.5h13M6 10v2.5m4-2.5v2.5" strokeLinecap="round" />
        </svg>
      )}
      <span className="acpmux-remote-location-machine">{machine.label}</span>
      {chevron && (
        <span className="ui-ghost-icon" aria-hidden="true">
          <ChevronIcon />
        </span>
      )}
    </span>
  );
}
