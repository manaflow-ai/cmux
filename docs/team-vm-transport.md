# Team VM transport

`TEAM_VM_TRANSPORT=vm-api` selects the tenant VM API for new TeamVmDO allocations.
Missing or `direct` keeps the legacy transport. Unknown values refuse new creates.
Each allocation records its transport in the private owner ledger; deployment
defaults never reroute existing, pending or retired VMs. Existing owner records,
including retired VMs, backfill as direct allocations by exact ID.

The API route needs dedicated `TEAM_VM_API_ORIGIN`, `TEAM_VM_API_SERVICE_KEY`,
`TEAM_VM_API_IMAGE` and `TEAM_VM_API_IMAGE_REVISION` settings, plus the existing
environment-specific `TEAM_VM_SLUG_PREFIX`. Use a Team VM service credential with
the lifecycle, read, exec and file scopes and required label `role=team-vm`.
Cloud credentials and images are separate. The target tenant comes from TeamDO's
canonical identity mapping. Only an admitted create with a current wake lease can
provision a personal tenant; reads, binding and cleanup never provision one.

Create intents pin the approved image revision and idle timeout before external
I/O. Development/test allocations request 300 seconds. Production remains blocked
by the existing plan gate. This change does not activate an environment or add
billing entitlements.

A lost create response replays the identical request and idempotency key only in
the original endpoint/tenant/credential context and within 23 hours of its first
send, inside the API's 24-hour retention. The owner persists the context hash and
first-send time before sending. A discovery match alone cannot confirm the boot
image or network receipt. Expired or changed contexts remain unresolved for
operator reconciliation; neither a fresh key nor name matching permits another
allocation.

An ordinary API 404 can hide an inaccessible allocation. Replacement requires
the owned identity endpoint's explicit `checkPresence=true` / `presence=missing`
receipt. Authorization and provider failures leave the existing allocation in
place. Retirement requires the API's fence receipt; export uses saved-disk file
APIs without starting or executing the guest. Delete marks the ledger only after
a confirmed 204. An uncertain delete retains its ledger record.

The existing account-prefix report remains a legacy, read-only operator report.
API allocations use the owner ledger and registry; the tenant service credential
cannot enumerate the provider account. Never use either report to adopt or delete
resources outside an owner's ledger.
