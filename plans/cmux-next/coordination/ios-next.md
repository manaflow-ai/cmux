# Lane: ios-next

Plan and graph: plans/cmux-next/ios-next/PLAN.md.

## Active streams
- 2026-10-06 wave 0: A0 rpc, A1 shell, A2 ghostty, A3 link.

## Landed
- 2026-10-06 A0 rpc (branch feat-cmux-next-ios-a0-rpc): `cmux.mobile/1` wire. Design ios-next/a0-rpc.md; catalog, JSON Schemas and fixtures in schemas/mobile-rpc/; Swift `Packages/Shared/CmuxMobileWire` (module CmuxMobileWire); TS `@cmux/protocol` (`mobile-wire.ts`, `mobile-wire-binary.ts`, `mobile-wire-catalog.ts`). Control frames are cmux.wire/1 plus `hello`/`hello.ok`, `read`/`read.result`, `signal`, `channel.*`; stream records reuse the u32 channel/u64 seq/u8 flags header. B1 must add `hello`, `read`, `signal` and HostDO op forwarding to the DO gateway.
