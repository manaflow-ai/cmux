# Refactor log

Append-only. One line per landing: date, SHA, lane, what moved where, old -> new lines, gate and minutes. Rules: plans/cmux-next/code-quality.md (R1-R10). Design notes for later phases go under "Phase 2 designs" at the end.

## Landings

- 2026-10-09 82fa0c39103c refactor-swift-ts: plans/cmux-next/code-quality.md added (docs only, no gate).
- 2026-10-09 7a6fbf50b615 refactor-swift-ts: webviews/src/App.tsx -> webviews/src/diff-viewer/{state,session,item-languages,item-navigation}.ts; App.tsx 3311 -> 2649; nx-remote web gate (bundles, check, budgets, 331 test files) 2 min.
- 2026-10-09 1fcf1f23a7a9..999d5b6a4d70 refactor-swift-ts: webviews/src/App.tsx -> webviews/src/diff-viewer/{Toolbar,FileHeader,FilesSidebar,Loading,WorkerRenderOptionsSync}.tsx, useSyncedRef.ts, useRenderDiff.ts, useDiffComments.ts, bootstrap.ts, page-effects.ts; App.tsx 2649 -> 697; nx-remote web gate (332 test files) 3.5 min.
- 2026-10-09 e6c55a6eab8d refactor-swift-ts: HomeStore.swift -> HomeStore+{Cache,Paging,Writing,Attachments,Uploads,Backoff,BlobCache,Events,Hooks}.swift (phase 1, extension split); file 1427 -> 285, type unchanged; cmux-ci CmuxHomeCoreTests 120/120, about 5 min.

- 2026-10-09 cdde5b4d3a34 refactor-swift-ts: MobileCoreRPCSession.swift -> MobileCoreRPCSession+{TearDown,Connect,ReadWrite,PendingRequests,CancelledWrites,ControlStreamRepair,TransportClose}.swift (phase 1); 1741 -> 430; cmux-ci CmuxMobileRPCTests 221/223 (2 named reds, bead filed), about 6 min.
- 2026-10-09 3a3629c3d9b6 refactor-swift-ts: MobilePairedMacStore.swift -> MobilePairedMacStore+{Migrations,Upsert,RouteAuthority}.swift (phase 1); 1616 -> 362; cmux-ci CmuxMobilePairedMacTests 45/45, about 5 min.
- 2026-10-09 0b8109dc0e0c refactor-swift-ts: test-only fix of the RPCStackTokenGate reset tests (helper raced a 1 ns timeout against the released provider); suite 10/10 x10 green, step 16763635.
- 2026-10-09 6963cf9ff635 refactor-swift-ts: HomeStore phase 2 step 1, HomeConversationHookRegistry owns the conversation hooks (owner split); CmuxHomeCoreTests 122/122, CmuxHomeRenderTests 115/115, about 6 min.
- 2026-10-09 38aedaf5abc1 refactor-swift-ts: HomeStore phase 2 step 2, HomeClientViewCache owns drafts, scroll anchors and cache writes; CmuxHomeCoreTests 125/125, CmuxHomeRenderTests 115/115, about 6 min.
- 2026-10-09 c93ed1f5c300 refactor-swift-ts: HomeStore phase 2 step 3, HomeTranscriptPager owns view counts, epochs and reads; CmuxHomeCoreTests 128/128, CmuxHomeRenderTests 115/115, about 12 min (one compile fix).

## Phase 2 designs

### HomeStore owner split (proposed, needs hq-6d agreement)

Phase 1 only spread HomeStore over extension files; the type still owns about 30 stored properties and every concern. Phase 2 moves each concern's state into its own type that HomeStore owns, so HomeStore is a thin `@MainActor` coordinator of the mirror, the intent log and the connection. Each step is one landing with tests unchanged (the public HomeStore API stays) plus focused tests for the new type.

1. `HomeConversationHookRegistry` (struct): owns `hooks`; register, unregister, prune, live hooks for an intent. Smallest, no async. First, to prove the pattern.
2. `HomeClientViewCache` (`@MainActor` final class): owns `drafts`, `scrollAnchors`, `cacheWrite`, `restoringCache`, the clock-coalesced write and restore. HomeStore passes it a snapshot provider closure for mirror and log state.
3. `HomeTranscriptPager` (`@MainActor` final class): owns `viewers`, `openEpochs`, `loads`, `olderLoading`; open, close, loadOlder, the single transcript read. Calls back into the store only to apply pages to the mirror.
4. `HomeBlobCache` (`@MainActor` final class with `@concurrent` statics): owns `blobCacheDirectory`, `localFiles`, `pruneLoop`, `pruning`, `preparing`, `createdAt`; prepare, prune, local stand-ins, fetch. It reads the pinned hashes from a closure that the store supplies (pending sends and the session's attachments).
5. `HomeSendPipeline` (`@MainActor` final class): owns `uploads`, `sendQueue`, `turnWaiters`, `backoffTasks`, `backoffAttempts`, and `UploadJob`; the upload passes, the per-conversation send order, and backoff. It talks to the store through a narrow protocol (submit an intent, bump a row, report a refusal or an unanswered op). It is the largest and riskiest step, so it goes last, after 1-4 show the pattern.

Decided (hq-6d, 2026-10-09): steps 1-4 stay in Swift as above. Step 5 moves to the Rust conversation owner instead, so the app, `cmux chief` and the JS runtime share one send queue and retry rule. Step 5 needs the CORE token and v2 upload ops; design it with hq-6d before any code. HomeSendPipeline is not built in Swift.

### Same rule for the other phase-1 splits

MobileCoreRPCSession (actor) and MobilePairedMacStore (actor) get the same treatment after their phase-1 landings: MobilePairedMacStore's schema migrator (open connection, run migrations, tableColumns, user_version) becomes a `MobilePairedMacSchema` value that owns the connection setup; MobileCoreRPCSession's control-stream repair state and cancelled-write resolution become owned helper types.
