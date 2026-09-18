import { createHash } from "node:crypto";
import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH } from "../guestCli";
import { guestPromptInstallCommand, type GuestPromptIdentity } from "../guestPrompt";
import { shellQuote } from "./cmuxTuiDaemon";

const digest = createHash("sha256").update(GUEST_CMUX_SHIM).digest("hex");

// Validate the uploaded generation and all required setup before publishing it.
// os.replace replaces a symlink itself and refuses a directory destination;
// `mv -f source destination` can instead move source *inside* a directory.
const install = String.raw`
import hashlib, json, os, stat, subprocess, sys
source, target, digest, prompt = sys.argv[1:]
stage = "validate"
try:
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("upload is not a regular file")
        if hashlib.sha256(stream.read()).hexdigest() != digest:
            raise ValueError("upload checksum mismatch")
        os.fchmod(stream.fileno(), 0o755)
    stage = "verify"
    subprocess.run([source, "--help"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if prompt:
        stage = "prompt"
        subprocess.run(["/bin/sh", "-c", prompt], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stage = "publish"
    os.replace(source, target)
except Exception as error:
    # Bounded, structured diagnostics: no prompt payload or guest output.
    print("CMUX_GUEST_INSTALL_FAILURE=" + json.dumps({
        "stage": stage, "error": type(error).__name__,
        "errno": getattr(error, "errno", None),
        "exitCode": getattr(error, "returncode", None)
    }), file=sys.stderr)
    sys.exit(1)
`;

export function guestCliInstallCommand(temporaryPath: string, identity?: GuestPromptIdentity): string {
  return `python3 -c ${shellQuote(install)} ${shellQuote(temporaryPath)} ${shellQuote(GUEST_CMUX_SHIM_PATH)} ${shellQuote(digest)} ${shellQuote(identity ? guestPromptInstallCommand(identity) : "")}`;
}
