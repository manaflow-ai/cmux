import { readFileSync } from "node:fs";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../services/vms/images/workUser";
import { shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";

const probe = readFileSync(new URL("./devbox-cua-smoke.py", import.meta.url)).toString("base64");

/** Read immutable evidence without repeating any desktop actions. */
export async function readCuaProof<T>(read: () => Promise<T>): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await read();
    } catch (error) {
      const code = error instanceof Error && "code" in error ? error.code : undefined;
      if (attempt >= 3 || !["ECONNRESET", "EPIPE", "ETIMEDOUT"].includes(String(code))) throw error;
      console.warn(`CUA proof read interrupted (${code}); retry ${attempt}/2`);
    }
  }
}

/** Speak MCP using the guest's native agent configuration, under its desktop login environment. */
export function devboxCuaSmokeCommand(outputDirectory: string): string {
  const python = `import base64; exec(compile(base64.b64decode("${probe}"), "devbox-cua-smoke.py", "exec"))`;
  // Provider exec starts as root in /root. sudo changes the uid, not cwd;
  // Codex explicitly chdirs its MCP children and correctly rejects that path.
  // A new machine terminal starts in the work user's home instead.
  const command = `cd ${shellQuote(DEVBOX_WORK_HOME)} && python3 -c ${shellQuote(python)} --out ${shellQuote(outputDirectory)}`;
  return `sudo -n -u ${shellQuote(DEVBOX_WORK_USER)} env -i HOME=${shellQuote(DEVBOX_WORK_HOME)} USER=${shellQuote(DEVBOX_WORK_USER)} PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -lc ${shellQuote(command)}`;
}
