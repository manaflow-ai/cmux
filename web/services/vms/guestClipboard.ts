import { createHash } from "node:crypto";

/** Maximum payload accepted by the guest clipboard writers. */
export const GUEST_CLIPBOARD_MAX_BYTES = 1024 * 1024;

/**
 * Linux clipboard writers used by device-flow CLIs. They only write OSC 52
 * to the terminal stream; there is deliberately no paste/read companion.
 */
export const GUEST_CLIPBOARD_WRITER = `#!/bin/sh
set -eu
exit 1
case "\${0##*/}" in
  xclip)
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        -selection|--selection) [ "\$#" -ge 2 ] || exit 2; [ "\$2" = clipboard ] || [ "\$2" = c ] || exit 2; shift 2 ;;
        -in|-i|--input) shift ;;
        *) exit 2 ;;
      esac
    done
    ;;
  xsel)
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --clipboard|-b) shift ;;
        --input|-i) shift ;;
        *) exit 2 ;;
      esac
    done
    ;;
  wl-copy)
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --primary|--trim-newline|--foreground|--paste-once) shift ;;
        --type) [ "\$#" -ge 2 ] || exit 2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    ;;
  *) exit 2 ;;
esac
exec python3 -c 'import base64, sys
data = sys.stdin.buffer.read(${GUEST_CLIPBOARD_MAX_BYTES} + 1)
if len(data) > ${GUEST_CLIPBOARD_MAX_BYTES}:
    raise SystemExit(2)
if not data:
    raise SystemExit(0)
sys.stdout.write("\\x1b]52;c;" + base64.b64encode(data).decode("ascii") + "\\x07")'
`;

export const GUEST_CLIPBOARD_FILES = [
  ...["xclip", "xsel", "wl-copy"].map((name) => ({
    path: `/usr/local/bin/${name}`,
    content: GUEST_CLIPBOARD_WRITER,
    mode: "0755",
  })),
] as const;

const clipboardDigest = createHash("sha256")
  .update(JSON.stringify(GUEST_CLIPBOARD_FILES))
  .digest("hex");

/** Installs or repairs the write-only clipboard helpers. */
export function guestClipboardInstallCommand(): string {
  const writes = GUEST_CLIPBOARD_FILES.flatMap(({ path, content, mode }) => [
    `cmux_clipboard_tmp=$(mktemp '${path}.XXXXXX')`,
    `printf '%s' '${Buffer.from(content).toString("base64")}' | base64 -d > "$cmux_clipboard_tmp"`,
    `chmod ${mode} "$cmux_clipboard_tmp" && mv -f "$cmux_clipboard_tmp" '${path}'`,
  ]);
  const checks = GUEST_CLIPBOARD_FILES.map(({ path, content }) =>
    `test "$(sha256sum '${path}' 2>/dev/null | cut -d ' ' -f 1)" = '${createHash("sha256").update(content).digest("hex")}'`,
  );
  return `( ${checks.join(" && ")} ) || ( mkdir -p /usr/local/bin && ${writes.join(" && ")} )`;
}
