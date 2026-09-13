import { readFileSync } from "node:fs";
import { shellQuote } from "./drivers/cmuxTuiDaemon";

export type GuestPromptIdentity = {
  readonly machineId: string;
  readonly name: string;
  readonly revision: number;
};

/** A display label becomes a prompt slug; the machine's routing id stays stable. */
export function vmPromptIdentity(row: {
  readonly id: string;
  readonly slug: string | null;
  readonly displayName: string | null;
  readonly updatedAt: Date;
}): GuestPromptIdentity {
  const slug = (value: string) => value.normalize("NFKD").toLowerCase()
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-").slice(0, 63).replace(/^-+|-+$/g, "");
  return {
    machineId: row.id,
    name: slug(row.displayName ?? "") || slug(row.slug ?? "") || "cmux",
    revision: row.updatedAt.getTime(),
  };
}

const bashrc = readFileSync(new URL("./images/devbox/cmux-bashrc", import.meta.url), "utf8");
const prompt = readFileSync(new URL("./images/devbox/cmux-prompt.bash", import.meta.url), "utf8");

// Runs on lifecycle operations, never during shell startup or prompt drawing.
// A lock serializes competing attaches/renames. Atomic replacement gives every
// shell either the old complete name or the new one. The machine id prevents a
// fork from inheriting its source's revision. User rc files are never touched.
const install = String.raw`
import fcntl, json, os, pathlib, sys, tempfile
directory = pathlib.Path(sys.argv[1])
payload = json.loads(sys.argv[2])
directory.mkdir(parents=True, exist_ok=True)
def replace(name, content):
    target = directory / name
    if target.is_file() and not target.is_symlink() and target.read_text() == content:
        return
    fd, temporary = tempfile.mkstemp(prefix=".prompt-", dir=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
with (directory / ".prompt-lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        current = json.loads((directory / ".prompt-identity").read_text())
    except (FileNotFoundError, ValueError):
        current = {}
    if not isinstance(current, dict) or not isinstance(current.get("revision", -1), int):
        current = {}
    incoming = payload["identity"]
    if current.get("machineId") != incoming["machineId"] or current.get("revision", -1) <= incoming["revision"]:
        replace("vm-name", incoming["name"] + "\n")
        replace(".prompt-identity", json.dumps(incoming))
    for name, content in payload["files"].items():
        replace(name, content)
`;

export function guestPromptInstallCommand(identity: GuestPromptIdentity, directory = "/etc/cmux"): string {
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(identity.name) || !Number.isSafeInteger(identity.revision)) {
    throw new Error("Invalid Cloud prompt identity");
  }
  const files = {
    "prompt.bash": prompt.replaceAll("/etc/cmux", directory),
    bashrc: bashrc.replaceAll("/etc/cmux", directory),
  };
  return `python3 -c ${shellQuote(install)} ${shellQuote(directory)} ${shellQuote(JSON.stringify({ identity, files }))}`;
}
