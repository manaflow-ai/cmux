/**
 * The image's one boot unit, `cmux host run` (plans/cmux-next/vm-image.md 6.3, 11 step 2): the
 * bind agent, the session host supervisor and the Cloud agent role in the Rust binary. It replaces
 * the interim Bun agent (vm-agent.ts) and the shell supervisor (cmux-devbox-boot), with the same
 * file contracts (/var/lib/cmux/bind.json, bound.json, /run/cmux-vm-agent/agent.sock,
 * /etc/cmux/daemon-instance-id, /etc/cmux/bake-instance-id).
 *
 * The session host's remote entry comes only from /etc/cmux/host.json. Cloud machines use the
 * Freestyle edge; the file holds no secret. With the client-grant rollout on,
 * the edge decides reachability and the daemon still requires enrollment.
 */
import { CURRENT_BIN } from "./lock";
import { cloudClientGrantRequired } from "../../services/vms/clientGrant";

export const HOST_UNIT = "cmux-host.service";
export const HOST_CONFIG_PATH = "/etc/cmux/host.json";
/** The frozen unit command: `<current>/bin/cmux host run`; argv[0] named `cmux` selects the `host` verb. */
export const HOST_RUN = `${CURRENT_BIN}/cmux host run --mode system`;
export const HOST_CLI = `${CURRENT_BIN}/cmux host`;
/** The Cloud role's log lines (journal of the host unit). */
export const HOST_JOURNAL = `journalctl -m -u ${HOST_UNIT} --no-pager -o cat`;

/** The only API origin each environment may bind to (cmux-host cloud/wire.rs Env::api_origin). */
export const API_ORIGINS = {
  dev: "https://cmux-api-development.debussy.workers.dev",
  stg: "https://cloud-api-staging.cmux.dev",
  prod: "https://cloud-api.cmux.dev",
} as const;

/** ES256 over the UTF-8 message; WebCrypto returns raw r||s (64 bytes), sent base64url (test harness signing). */
export async function signMessage(privateKey: CryptoKey, message: string): Promise<string> {
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, new TextEncoder().encode(message));
  return Buffer.from(sig).toString("base64url");
}

/** host.json: edge reachability on the dual-stack wildcard; auth rolls to enrolled grants. */
export function hostConfig(): string {
  const carrier = cloudClientGrantRequired() ? "freestyle-edge-grant" : "freestyle-edge";
  return `${JSON.stringify({ remoteWs: { bind: "[::]:1337", carrier } }, null, 2)}\n`;
}

/** The host unit. `extraEnv` (agent tools) reaches the session host and every terminal it creates. */
export function hostUnit(envLines: readonly string[], storePath: string): string {
  return [
    "[Unit]",
    "Description=cmux host: bind agent, session host supervisor and Cloud agent (cmux host run)",
    "After=network.target",
    // Never give up (as acpmux.service): no start limit, 3 s backing off to 60 s.
    "StartLimitIntervalSec=0",
    "",
    "[Service]",
    "Type=simple",
    "User=root",
    // Each terminal host gets its own transient scope (cmux-tui host_scope.rs), so a stop or
    // restart of this unit (which takes the session host with it) keeps every terminal for
    // re-adoption by the next session host.
    "Environment=CMUX_TUI_HOST_SCOPES=systemd",
    // The browser host the session host supervises refuses metadata, link-local and
    // private ranges to every caller (cmux-browser-host egress_scope.rs); the image
    // marker also turns it on, this keeps it on without the marker.
    "Environment=CMUX_BROWSER_HOST_EGRESS=isolated",
    `Environment=PATH=${storePath}`,
    ...envLines,
    `ExecStart=${HOST_RUN}`,
    "Restart=always",
    "RestartSec=3",
    "RestartSteps=5",
    "RestartMaxDelaySec=60",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ].join("\n");
}
