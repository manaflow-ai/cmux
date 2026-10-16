import { readFileSync } from "node:fs";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../services/vms/images/workUser";
import { shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";

const probe = readFileSync(new URL("./devbox-cua-smoke.py", import.meta.url)).toString("base64");

/** Speak MCP using the guest's native agent configuration, under its desktop login environment. */
export function devboxCuaSmokeCommand(outputDirectory: string): string {
  const python = `import base64; exec(compile(base64.b64decode("${probe}"), "devbox-cua-smoke.py", "exec"))`;
  const command = `python3 -c ${shellQuote(python)} --out ${shellQuote(outputDirectory)}`;
  return `sudo -n -u ${shellQuote(DEVBOX_WORK_USER)} env -i HOME=${shellQuote(DEVBOX_WORK_HOME)} USER=${shellQuote(DEVBOX_WORK_USER)} PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -lc ${shellQuote(command)}`;
}
