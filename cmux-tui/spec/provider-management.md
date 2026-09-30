# Provider Management Protocol v1

Provider management installs or rotates the authority used by provider-owned workspace mirrors. It is a root-only Linux Unix-socket protocol, separate from mux control and machine-provider protocols.

Each connection carries exactly one UTF-8 JSON request line and one JSON response line. A request is limited to 8 KiB. Read and write deadlines are three seconds. The server verifies `SO_PEERCRED.uid == 0` before accepting a request and sets `PR_SET_DUMPABLE=0` before serving.

## Requests

Status:

```json
{"operation":"status","protocol":1}
```

Install or rotate:

```json
{
  "operation":"install_or_rotate",
  "protocol":1,
  "mux_generation":"boot-uuid",
  "expected_authority_generation":4,
  "authority_generation":5,
  "authority":"secret"
}
```

`mux_generation` fences the running daemon. `expected_authority_generation` is the compare-and-swap value. `authority_generation` must advance according to the server's authority rules. `authority` is required, validated, redacted, and overwritten when its owned buffer is dropped.

## Response

```text
object{
  protocol:1,
  ok:boolean,
  status?:ProviderWorkspaceAuthorityStatus,
  error?:object{code:string,message:string}
}
```

Stable error codes are `access_denied`, `invalid_request`, `unsupported_version`, `invalid_authority`, `unmanaged`, `mux_generation_mismatch`, `expected_generation_mismatch`, `generation_conflict`, and `invalid_generation`.

The protocol never returns the installed authority. `status` contains only non-secret state required to plan the next rotation.

## Trust boundary

Ordinary mux clients cannot install or rotate this authority. Provider frontends use the already provisioned authority only with `mark-workspaces-provider-managed`, `close-provider-managed-workspace`, and `rename-provider-managed-workspace`. Machine-provider transport tickets do not imply provider-management authority.

Provider-management protocol changes use their own version and do not change `identify.protocol`.
