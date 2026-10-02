# cmux-next Cloud and Freestyle parity inventory

Inventory captured 2026-10-02 from `origin/main`, `origin/feat-cmux-next` (`4eacb7d418f`), Freestyle npm `freestyle@0.2.16`, and `cmux-next-spec` draft 2. This is a proposal and implementation plan. It does not modify the spec repository.

## Main Cloud surface

- CLI: `CLI/cmux.swift` dispatches `cmux vm`/`cloud`; `CMUXCLI+VMHelp.swift` documents verb help and validation; `CMUXCLI+VMSnapshots.swift` covers snapshot list/delete; `CMUXCLI+VMTransfer.swift` covers push/pull; `CMUXCLI+VMSCP.swift` covers SCP metadata; `CMUXCLI+VMNetwork.swift` covers network/route; `CMUXCLI+CloudDomains.swift` covers domain publications; `FreestyleInteractiveShellScript.swift` bootstraps the remote shell, cmux context, zsh and tmux. `cmux vm help` includes create/list/status/stats/rename/start/pause/resize/delete/restore/fork/exec/ssh/snapshot/transfer/tree/workspace/terminal/open/route/agent/tui and domains.
- App: the main `Packages/macOS/CmuxCloud` feature owns Cloud auth, machine cache/list/rename/lifecycle, CloudMachineLink, per-machine sidebar trees, create sheet, private-network state, port forwarding and the userspace WireGuard hub. `CLI/CMUXCLI+CloudSidebar.swift` and Cloud actions expose the sidebar and machine operations. `cmux-wg` is the in-process BoringTun/smoltcp hub used by remote attach.
- Web/backend: `web/services/vms/drivers/freestyle.ts` implements VM lifecycle, exec, resize, snapshots, file/transfer and private-network provider calls; `web/services/vms/privateNetwork.ts` owns per-account VPC/tunnel enrollment and reconciliation; `web/db/schema.ts` and migration `20260902090000_cloud_vm_private_networks` own `cloud_vm_tunnels`; firewall/publication and domain routes are in the VMs service. Cloud VM workflows include `.github/workflows/cloud-vm-{canary,dogfood,env-audit,guest-install,image-contract,image-reachability,migrate,smoke}.yml`, plus `cmux-cloud-cli.yml`.
- iOS: `Packages/iOS/CmuxMobileCloud` provides Cloud API/auth, machine lifecycle, terminal attachment, session controller, WireGuard key/config, system VPN and tunnel enrollment; bridge/UI packages project Cloud machines and catalog actions.

## feat-cmux-next coverage

`Packages/macOS/CmuxNextCloud` has `CloudAPIClient` list/get/create/rename/delete/attach-endpoint/stats/resize/snapshot/list/restore/fork/exec and tunnel enroll/revoke. `CloudService` reconciles `/api/vm` into `MachineRegistry` Cloud sessions, starts `CloudTunnelHub`, and `CloudHandlers`/`CloudActionCatalog` provide create/open/terminal/rename/kill/link/port/resize/status/tools/handoff/fork/snapshot/template/restore plus auth/team/mobile actions. The sidebar renders each Cloud machine as a normal machine tree.

Gaps are substantial: no CloudAPI start/pause/resume/update/idle-policy or snapshot delete; no catalog/CLI lifecycle rows; exec is API-only and there are no guest ssh/scp/fs operations; the tunnel hub only enrolls this device and has no VPC/firewall policy surface; no domains/TLS, identity/permission, API-token, account/team/billing read views, or full skill surface. Unsupported daemon compatibility is explicitly reported as “cloud not wired into cmux-next yet” for several methods.

### cmux-next UI mapping

cmux-next does not have a right sidebar. Do not port main's right-sidebar Cloud panel. The parity design uses cmux-next's existing surfaces:

1. A built-in **Machines** section in the left sidebar shows the machine list, status dot, inline pause/resume, and a `+` create action.
2. Every Freestyle operation is an action-catalog entry, so it is reachable from the palette, CLI, MCP, and keyboard surfaces.
3. Opening a machine shows a Settings-style page/tab with overview, snapshots, tunnels, firewall, domains, and usage.
4. Machine terminals and file operations are ordinary panes tagged with their machine.
5. Team-level identities, tokens, VPC/network policy, and billing live under **Settings > Cloud**.

The one-sidebar model has two compatible Cloud navigation options to prototype:

- **Machines section:** keep all machines in one built-in left-sidebar section with status dots, inline pause/resume, and `+` create. Selecting a machine shows its workspaces, terminals, files, and the machine page in the same sidebar and content area.
- **Machine spaces:** treat one machine or a selected set of machines as a Zen/Arc-style space. Space switching uses the existing sidebar-edge dots/swipe affordance; the active machine space fills the one sidebar with that machine set's workspaces, terminals, and files. There is no second permanent panel or default skinny icon rail.

The implementation should keep the Machines section as the baseline and make the space projection a navigation mode over the same `MachineRegistry`, catalog actions, and machine-tagged panes. Both modes must expose the same operations and permissions.

## Freestyle 0.2.16 command inventory

Global flags: `--api-key`, `--team`, `--proxy`, `--output pretty|json`, `-h`, `-v`. The package bin is `freestyle: dist/cli/index.js`.

- `vm`: `create` (`--snapshot-id --slug --replace-slug/--reassign-slug --display-name --idle-timeout-seconds --ephemeral --vpc --ipv4 --metadata` repeatable `--internet/--no-internet --automatic-restart --ssh/--no-ssh`), `list` (`--state --slug --snapshot-id --metadata --limit --offset`), `get`, `update` (slug/display-name/idle-timeout/automatic-restart/metadata), `start`, `pause`, `resize` (`--cpu --memory --storage` MiB), `delete`, `exec` (`--interactive/-i --tty/-t --linux-user --timeout-ms --env` repeatable), `ssh` (`--linux-user --exec`), `scp` (`--recursive`), and `fs read|write|ls|mkdir|rm|stat` (`read --out`).
- `snapshot`: `create [vmId]` (script/interactive/base/internet/keep-vm/linux-user options), `list` (`--source-vm-id --limit --offset`), `get`, `update` (slug/replace-slug/display-name), `delete`.
- `vpc`: `create` (`--cidr --cidr-v6 --slug --display-name`), `list|get|update|delete`, `tunnels <vpcId>`.
- `tunnels`: `create` (`--slug --display-name --public-key`), `list|get|update`, `attach <tunnelId> <vpcId>` (`--ipv4 --ipv6 --remote-cidr` repeatable), `detach`, `rotate-key` (`--public-key`), `delete`.
- `firewall`: `create` (`--from --to --description`), `list` (`--vm --vpc --tunnel`), `get`, `delete`.
- `tls`: `create|list|get|update|delete`; create/update support `--domain --from --to --header` repeatable, JSON `--match`/`--json-patch`, Postgres and SOCKS5 credential fields, and `--protocol http|tcp|postgres|minecraft|imap|imaps|socks5`; list filters `--vm/--vpc`.
- `domain`: list/create/get/complete/delete verification challenges, `verify`, `wildcard`, and `cert list`.
- `identity`: create/list/get/delete; `token create|list|revoke`; `permission grant|list|get|update|revoke` with repeatable `--allowed-linux-user`.
- `tokens`: create/list/revoke team API keys. `account`: signup/claim. `auth`: login/logout/whoami/list/current/use/team. `billing`: redeem/claim-yc. `skill install` (`--agent --project --print`).

## Parity table

| Freestyle command | cmux main equivalent | cmux-next equivalent | Gap |
| --- | --- | --- | --- |
| vm create/list/get/update/start/pause/resize/delete | `cmux vm new/list/status/rename/start/pause/resize/delete`; provider in `drivers/freestyle.ts` | CloudAPI create/list/get/delete/rename/resize; CloudService/sidebar; catalog create/kill/resize | Add Machines left-sidebar section, update/start/pause/idle policy, delete confirmation, catalog and CLI parity; preserve idempotency |
| vm snapshot + snapshot group | `vm snapshot`, `snapshot_list/delete`, restore/fork backend | CloudAPI snapshot/list/restore/fork and catalog snapshot/restore/fork | Add snapshot delete and complete top-level snapshot API/catalog |
| vm exec/ssh | `vm exec`, `vm ssh`/`ssh-attach`, `FreestyleInteractiveShellScript` | CloudAPI exec; CloudMachineLink daemon terminal | Add backend-wrapped ssh/pty attach as ordinary machine-tagged panes and catalog/CLI/MCP actions |
| vm scp/fs | `VMTransfer`, `VMSCP`, `file_put/pull` and tree/workspace helpers | none beyond daemon panes | Add backend file read/write/list/mkdir/rm/stat and scp, exposed as ordinary panes and file actions |
| vpc | `privateNetwork.ts` and provider private networking | device tunnel enrollment only | Add VPC CRUD and Settings > Cloud team policy binding |
| tunnels | `privateNetwork.ts`, `cloud_vm_tunnels`, `cmux-wg` | `CloudTunnelHub` enroll/revoke | Add tunnel CRUD/attach/detach/rotate and policy reconciliation |
| firewall | Freestyle provider firewall/private-network policy routes | none | Add network-policy compiler/reconciler and Settings > Cloud read/write UI/CLI |
| domain + verify/wildcard | `CMUXCLI+CloudDomains.swift`, backend domain/publication routes | none | Add API, catalog and read/write views |
| tls | main Cloud publication/TLS backend and domain CLI | none | Add backend-wrapped TLS rules/certificates |
| identity + permission | main auth/access-grant control plane; no Freestyle group | auth/team only | Add identities, token mint/revoke, per-VM grants in Settings > Cloud |
| tokens | main auth/token control plane | auth/team only | Add team API-token read/write views in Settings > Cloud with secrets never in client |
| account/team/billing | Cloud auth/sidebar/mobile/account routes | sign-in/out/team picker/mobile | Add read-only account, team membership and billing views in Settings > Cloud |
| skill/auth | `vm prompt/skill`, bundled Cloud skill and interactive shell bootstrap | no full skill installer; auth actions exist | Add backend-served skill install and auth/account parity |

## Slice plan

1. Machine lifecycle: backend adapters plus CloudAPI/handlers/catalog/CLI for create/list/get/update/start/pause/resize/delete, idle policy, and snapshots. Every create uses an idempotency key and reconciles indeterminate provider results.
2. Exec/ssh/scp/fs: wrap through the cmux backend. Open ssh/exec as ordinary machine panes and expose file operations through pane/file actions. Do not shell out to a user's `freestyle` binary; the Freestyle API key stays server-side.
3. VPC/tunnels/firewall: compile `spec/network-policy.md` into provider VPC, WireGuard tunnel, and firewall operations with idempotent reconciliation, default-deny inbound, and revocation.
4. Domains/TLS, then identities/tokens, then read-only account/team/billing views and skill/auth parity.

Spec constraints carried forward: cloud D21 maps `idle_policy` to Freestyle `idleTimeoutSeconds` (automation/pool 300 seconds; interactive 3600 seconds when link keepalives do not count, otherwise explicit pause); network policy is one team document compiled to provider rules; agent egress uses the gateway/proxy with short-lived credentials and no secret in a guest. Any spec change belongs as a proposal here for Lawrence to apply.
