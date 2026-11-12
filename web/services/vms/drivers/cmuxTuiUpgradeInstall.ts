import { createHash } from "node:crypto";
import { guestBrowserInstallCommand } from "../guestBrowser";
import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH } from "../guestCli";
import { guestCliDistributionCommand } from "../guestCliDistribution";
import { cmuxTuiInstallCommand, cmuxTuiServiceInstallCommand, shellQuote, type CmuxTuiSource } from "./cmuxTuiDaemon";

const adapterDigest = createHash("sha256").update(GUEST_CMUX_SHIM).digest("hex");

/**
 * The install script of an in-place cmux-tui upgrade (scripts/upgrade-fleet-cmux-tui.ts):
 * the pinned binary and its service, then the guest `cmux` integration of this web build,
 * the same steps the image bake runs. The integration is an image asset, so a machine
 * upgraded in place would otherwise keep the adapter its image baked, and an adapter older
 * than the binary misreads a newer exit (a `process wait` that timed out exits 124). The
 * current adapter reads the old binary's exits too, so a rollback of the binary stays safe.
 *
 * `adapterFile` is the adapter (`GUEST_CMUX_SHIM`), uploaded beside the script: inlined, it
 * would pass Linux's 128 KiB limit on one exec argument. A file that is not this build's
 * adapter stops the install before anything changes.
 */
export function cmuxTuiUpgradeInstallScript(source: CmuxTuiSource, adapterFile: string): string {
  return [
    "set -e",
    `printf '%s  %s\\n' ${adapterDigest} ${shellQuote(adapterFile)} | sha256sum -c -`,
    cmuxTuiInstallCommand(source),
    cmuxTuiServiceInstallCommand(),
    "mkdir -p /usr/local/libexec",
    `install -m 0755 ${shellQuote(adapterFile)} ${GUEST_CMUX_SHIM_PATH}.upgrade`,
    `mv -f ${GUEST_CMUX_SHIM_PATH}.upgrade ${GUEST_CMUX_SHIM_PATH}`,
    `${guestBrowserInstallCommand()} && ${guestCliDistributionCommand()} && ${guestCliDistributionCommand(true)}`,
  ].join("\n");
}
