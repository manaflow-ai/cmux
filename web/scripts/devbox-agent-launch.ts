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
