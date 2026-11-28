import { readFileSync } from "node:fs";

const supervisor = readFileSync(new URL("./devbox-agent-launch.py", import.meta.url)).toString("base64");
const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;

/** Render an output-driven PTY probe under the same login environment as a machine pane. */
export function agentLaunchCheck(
  user: string,
  home: string,
  label: string,
  command: string,
  marker: string,
  forbidden: string,
): string {
  const python = `import base64; exec(compile(base64.b64decode("${supervisor}"), "devbox-agent-launch.py", "exec"))`;
  return `sudo -n -u ${quote(user)} env -i HOME=${quote(home)} USER=${quote(user)} TERM=xterm-256color PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin python3 -c ${quote(python)} --command ${quote(command)} --ready ${quote(marker)} --forbidden ${quote(forbidden)} --label ${quote(label)}`;
}

const hookTrust = readFileSync(new URL("./devbox-codex-hook-trust.py", import.meta.url)).toString("base64");

/**
 * Codex's own verdict on the hooks a daemon pane's codex starts with: the
 * wrapper's exact argv, then `hooks/list`, every hook trusted. Prints
 * `<label>-ok <count>`. `socket` is evaluated by the guest shell.
 */
export function codexHookTrustCheck(user: string, home: string, label: string, wrapper: string, socket: string): string {
  const python = `import base64, sys; sys.argv[0] = "devbox-codex-hook-trust.py"; exec(compile(base64.b64decode("${hookTrust}"), "devbox-codex-hook-trust.py", "exec"))`;
  const command = `python3 -c ${quote(python)} --wrapper ${quote(wrapper)} --socket "${socket}" --label ${quote(label)}`;
  return `sudo -n -u ${quote(user)} env -i HOME=${quote(home)} USER=${quote(user)} PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -lc ${quote(command)}`;
}
