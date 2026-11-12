import { shellQuote } from "../drivers/cmuxTuiDaemon";
import { MACHINE_HYGIENE_SCRIPT } from "./script.generated";

/** The heredoc delimiter; the script never contains it as a line. */
export const MACHINE_HYGIENE_HEREDOC = "CMUX_MACHINE_HYGIENE_SCRIPT_EOF";

/**
 * The shell command that runs cmux-machine-hygiene on a machine through
 * exec. It writes the embedded script to a temp file and runs it, so it
 * reaches machines whose images never baked it. Without `apply` the script
 * runs in its default dry-run mode and deletes nothing.
 *
 * On a machine, home is the exec user's passwd home (exec's $HOME is not
 * reliable, cmux#20328) and the only root is that home. Tests pass explicit
 * paths to run the same command against a throwaway directory.
 */
export function machineHygieneCommand(input: {
  readonly apply: boolean;
  readonly home?: string;
  readonly roots?: readonly string[];
  readonly tmpDir?: string;
}): string {
  const home = input.home ? shellQuote(input.home) : '"$cmux_hygiene_home"';
  const roots = input.roots?.length ? input.roots.map((root) => `--root ${shellQuote(root)}`).join(" ") : `--root ${home}`;
  const script = MACHINE_HYGIENE_SCRIPT.endsWith("\n") ? MACHINE_HYGIENE_SCRIPT : `${MACHINE_HYGIENE_SCRIPT}\n`;
  return [
    'cmux_hygiene_home="$(getent passwd "$(id -u)" | cut -d: -f6)"',
    'cmux_hygiene_script="$(mktemp)" || exit 1',
    `trap 'rm -f "$cmux_hygiene_script"' EXIT`,
    `cat > "$cmux_hygiene_script" <<'${MACHINE_HYGIENE_HEREDOC}'`,
    `${script}${MACHINE_HYGIENE_HEREDOC}`,
    `bash "$cmux_hygiene_script" --home ${home} ${roots} --tmp-dir ${shellQuote(input.tmpDir ?? "/tmp")}${input.apply ? " --apply" : ""}`,
  ].join("\n");
}
