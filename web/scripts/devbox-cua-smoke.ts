import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
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

/** The guest file reads proof collection needs (a Freestyle `vm.fs`). */
export interface CuaProofFiles {
  readDir(path: string): Promise<readonly { readonly name: string }[]>;
  readFile(path: string): Promise<Uint8Array>;
}

/**
 * Save the probe log and the guest's screenshots and reports, then fail when
 * the smoke failed. A failed probe may stop before it creates its output
 * directory, so collection is best effort then and the smoke's own output is
 * the reported cause; after a pass, a missing proof is an error.
 */
export async function saveCuaProof(options: {
  readonly files: CuaProofFiles;
  readonly guestDirectory: string;
  readonly destination: string | undefined;
  readonly output: string;
  readonly passed: boolean;
  readonly label: string;
}): Promise<void> {
  const { files, guestDirectory, destination, output, passed, label } = options;
  if (destination) {
    mkdirSync(destination, { recursive: true });
    writeFileSync(path.join(destination, "probe.log"), output);
    const collect = async () => {
      for (const file of await readCuaProof(() => files.readDir(guestDirectory))) {
        if (/^[a-z-]+\.(png|json)$/.test(file.name)) {
          writeFileSync(path.join(destination, file.name), await readCuaProof(() => files.readFile(`${guestDirectory}/${file.name}`)));
        }
      }
    };
    if (passed) await collect();
    else await collect().catch((error: unknown) => console.warn(`${label}: no computer-use proof collected: ${String(error)}`));
  }
  if (!passed) throw new Error(`${label}: computer-use smoke failed: ${output.slice(-2000)}`);
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
