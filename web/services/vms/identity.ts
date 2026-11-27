/**
 * The devbox identity contract: what a cmux Cloud machine calls itself.
 *
 * A machine's own name is the identity string every surface repeats: the
 * prompt in every pane (`\u@\h`), `hostname` and `uname -n`, `$HOSTNAME` in
 * login shells, the journal's host field, sudo's resolver check, and the
 * comment on its SSH host keys. The Freestyle base ships `freestyle-vm`
 * there, so a cmux machine used to introduce itself as the provider's. The
 * bake renames the machine to DEVBOX_HOSTNAME (the static name in
 * /etc/hostname, the kernel's live name, and Ubuntu's 127.0.1.1 loopback
 * alias in /etc/hosts), regenerates the SSH host keys under that name, and
 * starts the journal over; the verifier and the size derive prove all of it
 * on machines booted from the snapshot (scripts/devbox-image-common.ts holds
 * the shell for each step).
 *
 * What stays the provider's, by design, because the exec/fs API and the
 * transport depend on it: the guest agent (`freestyle-vms-agent`), its
 * first-boot host-key unit (`freestyle-vms-hostkeys`), the resolver drop-in
 * (`/etc/systemd/resolved.conf.d/60-freestyle-vms.conf`), the power-off
 * wrappers under /usr/local/sbin, the `# BEGIN freestyle-tls-egress` block
 * the agent keeps in /etc/hosts, the metadata service, and the gateway
 * endpoints (`vm-ssh.freestyle.sh`, `*.vm.freestyle.sh`). Those name the
 * platform (`freestyle-vms`), never the machine, and the residue audit's
 * whole-word match leaves them alone.
 */

/** The machine's name: static (/etc/hostname), live (the kernel's), and the loopback alias. */
export const DEVBOX_HOSTNAME = "cmux";

/**
 * The name the provider's base image ships. It must not survive the bake
 * anywhere the machine speaks for itself (whole-word match: the provider's
 * own `freestyle-vms` naming is not residue).
 */
export const DEVBOX_PROVIDER_HOSTNAME = "freestyle-vm";

/** Ubuntu's loopback alias for the machine's own name; sudo and `getent hosts` resolve it there. */
export const DEVBOX_HOSTNAME_LOOPBACK = "127.0.1.1";
