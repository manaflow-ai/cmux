// The sha256 of web/public/tui/install-static.sh, served unchanged forever at
// /tui/install-static/<sha256>.sh. cmux-tui/scripts/install-static-pin.py --write sets it; its check
// (tests/test_tui_install_pin.py) fails when it differs from the script. The commands built here never
// pipe a moving URL into sh (cmuxterm-hq docs/design/linux-signed-packages.md, section 4): the script is
// saved in a fresh `mktemp -d` directory, checked against this sha256 (sha256sum on Linux, shasum -a 256
// on a Mac), and only then run.
export const INSTALL_STATIC_SHA256 = "f2cbb6f11bd4743973c3f492e8fe2d1c4700c114784394da909890adec3e57de";

export const INSTALL_STATIC_PINNED_URL = `https://cmux.com/tui/install-static/${INSTALL_STATIC_SHA256}.sh`;

/** The pinned install command, with `args` for the script (` --server`, say). */
export function pinnedInstallCommand(args = ""): string {
  return (
    `d="$(mktemp -d)" && curl -fsSL ${INSTALL_STATIC_PINNED_URL} -o "$d/install.sh"` +
    ` && echo "${INSTALL_STATIC_SHA256}  $d/install.sh" | $(command -v sha256sum || echo shasum -a 256) -c` +
    ` && sh "$d/install.sh"${args}; rm -rf "$d"`
  );
}
