// Settings > Server: each server the app heard from (cmux-tui, acpmux), as the host reports it
// (host lists `server`, every text localized by the host): its status and version line, a "Restart
// Recommended" row when a restart would turn on new features, the local control socket, and the
// Tailscale address with Pair. Restart… opens the host's own confirm (the toast's); the page never
// restarts anything itself (plans/cmux-next/server-updates-DESIGN.md section 10).
import { useSettingsState, useStore } from "../context";
import type { ServerHostState } from "../ops";
import { ActionRow } from "./ActionRow";

type ServerRow = ServerHostState["servers"][number];

function ServerSection({ state, server }: { state: ServerHostState; server: ServerRow }) {
  const store = useStore();
  const copy = (text: string) => () => void store.copy(text);
  return (
    <section
      className="group"
      data-card="server"
      data-server={server.id}
      data-running={server.running ? "true" : "false"}
    >
      <h3 className="group-title">{server.name}</h3>
      <div className="rows">
        <ActionRow title={server.status} help={server.version_line}>
          {null}
        </ActionRow>
        {server.restart && (
          <ActionRow title={server.restart.title} help={server.restart.help}>
            <button
              type="button"
              className="button"
              data-server-restart={server.id}
              onClick={() => void store.restartServer(server.kind, server.host)}
            >
              {server.restart.button}
            </button>
          </ActionRow>
        )}
        {server.socket !== null && (
          <ActionRow title={state.socket_title} help={server.socket}>
            <button type="button" className="button" data-server-copy="socket" onClick={copy(server.socket)}>
              {state.copy_title}
            </button>
          </ActionRow>
        )}
        {server.tailnet !== null && (
          <ActionRow title={state.tailnet_title} help={server.tailnet}>
            <button type="button" className="button" data-server-pair="" onClick={() => void store.pairServer()}>
              {state.pair_title}
            </button>
            <button type="button" className="button" data-server-copy="tailnet" onClick={copy(server.tailnet)}>
              {state.copy_title}
            </button>
          </ActionRow>
        )}
      </div>
    </section>
  );
}

export function ServerCard() {
  const state = useSettingsState().host?.server;
  if (!state) return null;
  if (state.servers.length === 0)
    return (
      <section className="group" data-card="server" data-empty="">
        <h3 className="group-title">{state.title}</h3>
        <div className="rows">
          <div className="row">
            <div className="empty">{state.empty}</div>
          </div>
        </div>
      </section>
    );
  return (
    <>
      {state.servers.map((server) => (
        <ServerSection key={server.id} state={state} server={server} />
      ))}
    </>
  );
}
