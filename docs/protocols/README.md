# Wire protocols

Every protocol two cmux programs speak to each other, where its spec lives, the code on each end,
and the shared test vectors that keep the ends in step. A protocol with ends in two languages (or
two repositories) stays correct only while both ends test against the same vector file, so this page
also says which ends load it and where that is still missing.

Paths under `crates/` are in `cmux-tui/crates/`. "Both ends" means each end's own test suite reads
the vector file from its repo path; a generator that writes the file counts as its source, not as a
test.

## Adding or changing a protocol

1. Write the contract down where the table points (a spec page or a JSON schema), with a version.
2. Put the vectors in one file in the repo: under `schemas/<protocol>/` for a contract between
   languages, or beside the owning crate (`tests/vectors/`) when it is Rust on both ends. Each case
   holds the input, the exact expected bytes or string, and the expected verdict, so an end can be
   checked without running the other. Random output (ECDSA signatures) is generated once and
   checked in, with its generator beside it.
3. Load the file from every end's tests by its repo path (`include_str!`, a JSON import, or a walk
   up from `#filePath` in Swift), never a copy.
4. Add or update the row below.

## Index

| Protocol | Spec | Ends (owner) | Shared vectors | Ends that test them |
|---|---|---|---|---|
| Device-signed requests (device hub v1) | [docs/device-hub/PROTOCOL.md](../device-hub/PROTOCOL.md), "Device-signed requests" | Verifier: `workers/device-hub/src/{crypto,deviceAuth}.ts`. Signers: Linux host `crates/cmux-rd-host/src/linux_host/hub.rs`, apps `Packages/Shared/CmuxDeviceHub` and `Packages/macOS/CmuxNext/Sources/CmuxNextDevices` | [schemas/device-hub/request-signing-vectors.json](../../schemas/device-hub/request-signing-vectors.json) | Hub (`test/request-signing-vectors.test.ts`), Linux host (`hub.rs` tests), both Swift copies (`RequestSigningVectorTests`) |
| Device hub HTTP, sockets and session tickets (v1) | [docs/device-hub/PROTOCOL.md](../device-hub/PROTOCOL.md) | Server: `workers/device-hub`. Clients: the apps (`CmuxDeviceHub`), the Linux host (`hub.rs`), `crates/cmux-cloud-config/src/device_list.rs` | none | Gap: server-only tests; ticket and record shapes have no vector file |
| Relay frame v1 (`[ver][kind][peer][payload]`) | doc comment in `crates/cmux-transport/src/relay_frame.rs` | `backend/apps/api/src/host-relay/frame.ts`, `crates/cmux-transport/src/relay_frame.rs` | `crates/cmux-transport/tests/vectors/relay-frames.json` | Both: `backend/apps/api/test/host-relay.test.ts`, `crates/cmux-transport/tests/relay_vectors.rs` |
| Relay v2 control and lane tickets | `cmux-tui/relays/cloudflare-do/README.md`, [cmux-tui/spec/remote-rpc.md](../../cmux-tui/spec/remote-rpc.md) | Types: `crates/cmux-remote-protocol/src/relay.rs`. Self-host relay `crates/cmux-relay`, hosted relay `cmux-tui/relays/cloudflare-do`, client `crates/cmux-remote/src/provider/relay.rs` | `crates/cmux-remote-protocol/tests/fixtures/relay-control-v1.jsonl` | Both relays (`cmux-relay/src/relay.rs`, `cloudflare-do/src/wire.rs`). Gap: ticket signing payloads (`RelayTicketClaims::signing_payload`) have no vectors |
| Remote wire frame and remote RPC (protocol 5, frame 2) | [cmux-tui/spec/remote-rpc.md](../../cmux-tui/spec/remote-rpc.md), [remote-daemon.md](../../cmux-tui/spec/remote-daemon.md) | `crates/cmux-remote-protocol/src/{frame,rpc}.rs`; `cmux-remote`, `cmux-server` | none | Gap: Rust on both ends; no vector file for frames |
| Link token (`cmux-link+jwt`, v1) | the `$comment` of the vector file | Signer: `backend/apps/api/src/link-token.ts`. Verifier: `crates/cmux-link/src/token.rs` | [schemas/link-token/vectors.json](../../schemas/link-token/vectors.json) (from `backend/packages/protocol/scripts/export-link-token-vectors.ts`) | Gap: no test loads it, and the Rust side has only the deny-all verifier so far |
| Link keyset (bind answer) | `crates/cmux-link/src/keyset.rs` module doc | `backend/apps/api/src/link-keyset.ts`, `crates/cmux-link/src/keyset.rs` | [schemas/link-token/keyset-vectors.json](../../schemas/link-token/keyset-vectors.json) | Rust (`keyset_tests.rs`); the TypeScript end generates the file |
| Carrier grant (`cmux-carrier+jwt`) | `crates/cmux-link/src/carrier_grant.rs` module doc | Verifier: `crates/cmux-link/src/carrier_grant.rs`, `crates/cmux-remote/src/grant.rs`. Issuer: not in this repo | none | Gap: the issuer lives with the hosted service; it needs a vector file here that both test |
| Carrier child argv | none | `crates/cmux-tui/src/carrier/`, `Packages/macOS/CmuxNext` | `cmux-tui/spec/fixtures/carrier-child-argv.json` | Both: `carrier/argv_contract_tests.rs`, `CloudCarrierArgvContractTests.swift` |
| Remote desktop `cmux.rd/1` | [plans/cmux-next/remote-desktop-DESIGN.md](../../plans/cmux-next/remote-desktop-DESIGN.md) | `crates/cmux-rd-proto`, `cmux-rd-link`, `cmux-rd-host`, `cmux-rd-ffi`; Swift `CmuxNextRemoteView`, `CmuxNextMacScreen` | `crates/cmux-rd-proto/tests/vectors/{app_lines,control}.json` | Both: `cmux-rd-proto/tests`, `cmux-rd-ffi` tests, `MacScreenRdLineTests.swift`, `RemoteCursorTests.swift`. Gap: no vectors for frames and datagrams |
| Remote tab | [plans/cmux-next/remote-tab-protocol.md](../../plans/cmux-next/remote-tab-protocol.md) | `crates/cmux-remote-browser`, `cmux-rd-ffi`; Swift `CmuxNextRemoteBrowser` | `schemas/remote-tab/*.json` | Rust (`cmux-remote-browser/tests`, `cmux-rd-ffi`). Gap: no Swift test loads them |
| Control plane (`hello`, `ack`, `directory`, ...) | `schemas/control-plane/*.schema.json` | `workers/presence/src/controlPlane*.ts`, `Packages/Shared/CmuxIrxTransport` | `schemas/control-plane/fixtures/` | Both: `workers/presence/test/controlPlaneFixtures.test.ts`, `IrxControlPlaneTests.swift`, `IrxCtlListAuthTests.swift` |
| Presence | [docs/presence-service.md](../presence-service.md) | `workers/presence`; app clients | none | Gap |
| Mobile link (`cmux-mobile.v1`) | [cmux-next-ios/PROTOCOL.md](../../cmux-next-ios/PROTOCOL.md) | `cmux-next-ios/backend`, `cmux-next-ios/rust/crates/cmux-mobile-link`, `CmuxMobileKit` | none | Gap: three ends, no vector file |
| Cloud ops and ownership mirror | TypeScript op definitions in `backend/packages/protocol/src` | `backend/packages/{protocol,ownership}`, `crates/cmux-cloud-wire`, `cmux-mobile-ffi` | `backend/catalog/cloud-vectors.json`, `schemas/ownership-mirror/vectors.json` | Rust (`cmux-cloud-wire/tests`, `cmux-host`, `cmux-mobile-ffi/tests`); the TypeScript end generates the files |
| Pane protocol `cmux.pane/0` | `crates/cmux-pane-protocol/spec/pane-protocol.json`, [plans/cmux-next/pane-protocol.md](../../plans/cmux-next/pane-protocol.md) | `crates/cmux-pane-protocol`; generated Go, TypeScript and Python clients | `crates/cmux-pane-protocol/spec/pane-protocol-vectors.json` | Rust, Go (`bindings/go-pane`), Python codegen. Gap: no TypeScript test |
| Agent bridge (agent page and app) | `schemas/agent-bridge/contract.json` | `webviews/src/agent-session`, `Packages/macOS/CmuxNext` `CmuxNextAgentPane` | `schemas/agent-bridge/contract.json` | Both: `agentBridgeContract.test.ts`, `AgentBridgeContractTests.swift` |
| Socket API (resource API v2) | [cmux-tui/spec/resource-api-v2.md](../../cmux-tui/spec/resource-api-v2.md), [docs/cli-contract.md](../cli-contract.md), [cmux-tui/docs/protocol.md](../../cmux-tui/docs/protocol.md) | Daemon `cmux-server`, `cmux-tui-core`; CLI, app and SDK clients | `cmux-tui/spec/api-compat-fixtures.json`, `cmux-tui/bindings/conformance/` | Rust (`cmux-api-compat/tests`); bindings conformance |
| Machine provider and machine agent (v1) | [machine-provider.md](../../cmux-tui/spec/machine-provider.md), [machine-agent.md](../../cmux-tui/spec/machine-agent.md) | `crates/cmux-tui-machine-protocol`, `crates/cmux-tui-machine-agent-protocol` | none | Gap |
| Overlay netmap, tickets and relay frames | `plans/cmux-next/mesh-DESIGN.md` | `crates/cmux-weft`, `crates/cmux-wg/src/wire.rs` | none | Gap: Rust on both ends, deterministic, easy to add |
| Holder v3 | [plans/cmux-next/holder-protocol-v1.md](../../plans/cmux-next/holder-protocol-v1.md) | `crates/cmux-holder-v3/src/wire.rs` | none | Gap |
| Daemon pairing (remote access) | none | `crates/cmux-tui-remote-access/src/pairing.rs` | none | Gap: no spec |
| Chat relay | crate README | `crates/chatmux-relay/src/{wire,relay_wire,pairing}.rs` | none | Gap: no spec |
