# cmux-tui aggregate change log

Snapshot: 2026-08-23. Aggregate branch: `aggregate-final`, current code tip [`cfb0684e75`](https://github.com/manaflow-ai/cmux/commit/cfb0684e75). The prior documented code tip was [`ace9e5f57f`](https://github.com/manaflow-ai/cmux/commit/ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6), which was 459 commits ahead of `origin/main` and 0 behind it (`git rev-list` counts). The prior accepted tip was [`e8df21eed2`](https://github.com/manaflow-ai/cmux/commit/e8df21eed2866eba03b2548e790ba8a5a887b5da). This update records the CLI simplification and the explicit user-intent board after the 17-commit tail.

Earlier aggregate rows retained for history:

| Commit | Change | Verification / residual | Revert |
| --- | --- | --- | --- |
| [`efbe0bcceb`](https://github.com/manaflow-ai/cmux/commit/efbe0bcceb) | Reject invalid relay configuration before use. | Focused Rust checks are hosted-only; malformed-config callers now fail closed. | `git revert efbe0bcceb` |
| [`836ec27806`](https://github.com/manaflow-ai/cmux/commit/836ec27806) | Bound websocket ingress before allocation. | Hosted Rust verification required; oversized frames are rejected. | `git revert 836ec27806` |
| [`a44378f1d8`](https://github.com/manaflow-ai/cmux/commit/a44378f1d8) | Cap and validate persisted relay configuration. | Diff and static checks; migration risk for over-capacity stored config. | `git revert a44378f1d8` |
| [`7a1816acf6`](https://github.com/manaflow-ai/cmux/commit/7a1816acf6) | Bound relay PTY input frames. | Hosted relay tests required; excess input is rejected. | `git revert 7a1816acf6` |
| [`d1277ff2b5`](https://github.com/manaflow-ai/cmux/commit/d1277ff2b5) | Fail closed on mandatory relay queue overflow. | Hosted behavior proof required; clients must handle explicit closure. | `git revert d1277ff2b5` |
| [`70ac436947`](https://github.com/manaflow-ai/cmux/commit/70ac436947) | Bound preview-proxy websocket queues. | Hosted integration coverage required; slow consumers can be disconnected. | `git revert 70ac436947` |
| [`30419a1ad9`](https://github.com/manaflow-ai/cmux/commit/30419a1ad9) | Bound remote stream chunk queues. | Hosted integration coverage required; queue pressure is now visible as failure. | `git revert 30419a1ad9` |
| [`33c5804900`](https://github.com/manaflow-ai/cmux/commit/33c5804900) | Bound websocket writes and cancel replaced peers. | Hosted relay checks required; replacement closes the old peer. | `git revert 33c5804900` |
| [`80d5a5393c`](https://github.com/manaflow-ai/cmux/commit/80d5a5393cc5654d00d254adc9c9b78c4e1573df) | Validate relay frame protocol bounds at the aggregate tip. | Static checks only in this snapshot; hosted exact-head run remains required. | `git revert 80d5a5393c` |

Known residuals: no claim is made for local Rust test execution, full end-to-end relay coverage, journal/WAL latency, deterministic shutdown of every admitted task, or complete cloud-TUI acceptance. These remain open until an exact pushed SHA has hosted evidence.

Session-count honesty: the accompanying board records at least 180 substantive agent turns for this run. The requested 10,000-session target was not reached, and no empty sessions were created to inflate the count.

## Tail after `ace9e5f57f`

| Commit | Change | Verification / residual | Revert |
| --- | --- | --- | --- |
| [`0917e9918f`](https://github.com/manaflow-ai/cmux/commit/0917e9918fbf56267c978d8e05d857f11204a693) | Accept standard `--socket=`, `--session=`, and `--machine=` forms, while retaining separated values and rejecting empty inline values. | `cargo fmt --check` and CLI behavior tests are present. Hosted Rust CLI coverage remains required; nested command options intentionally keep their existing grammar. | `git revert 0917e9918fbf56267c978d8e05d857f11204a693` |
| [`cfb0684e75`](https://github.com/manaflow-ai/cmux/commit/cfb0684e75) | Apply formatter output to the inline global-option parser. | Formatting-only; no behavior change. | `git revert cfb0684e75` |
| [`46b5d0c044`](https://github.com/manaflow-ai/cmux/commit/46b5d0c044) | Add a durable user-intent board with local-session evidence and explicit acceptance gaps. | Documentation-only. The board records a multilingual emoji fixture request and search limitations. | `git revert 46b5d0c044` |

## Final accepted tail from `b61f1bada6` to `e8df21eed2`

The table is exhaustive for the 49-commit inclusive tail. Revert commands use
full object IDs. A merge uses `-m 1` and must be reviewed against the parent
chosen by the integration owner. “Hosted” means the focused test or check must
run on the hosted builder; this documentation worktree makes no local Rust
test claim.

| Commit | Change | Tests / residual risk | Exact revert |
| --- | --- | --- | --- |
| [`b61f1bada6498ee9d6549f4550f9a062f327f22c`](https://github.com/manaflow-ai/cmux/commit/b61f1bada6498ee9d6549f4550f9a062f327f22c) | Apply hosted relay rustfmt. | Formatter-only; rerun hosted compile after further edits. | `git revert b61f1bada6498ee9d6549f4550f9a062f327f22c` |
| [`74c2d71c7ea58949a744e1545f49c72329d0e53e`](https://github.com/manaflow-ai/cmux/commit/74c2d71c7ea58949a744e1545f49c72329d0e53e) | Add publish-workflow security validation. | `tests/test_tui_publish_workflow_security.py`; hosted workflow remains required. | `git revert 74c2d71c7ea58949a744e1545f49c72329d0e53e` |
| [`1e1800db80e54d7f63e02ae5a30bbd1b2f7cb3d0`](https://github.com/manaflow-ai/cmux/commit/1e1800db80e54d7f63e02ae5a30bbd1b2f7cb3d0) | Expose the session port to agents. | Hosted Rust behavior test required; port ownership remains a product contract. | `git revert 1e1800db80e54d7f63e02ae5a30bbd1b2f7cb3d0` |
| [`1956d7f440add80ba35e585d83697d9dae44d3e2`](https://github.com/manaflow-ai/cmux/commit/1956d7f440add80ba35e585d83697d9dae44d3e2) | Define relay cleanup cancellation contract. | Docs-only, `git diff --check`; runtime implementation remains separate. | `git revert 1956d7f440add80ba35e585d83697d9dae44d3e2` |
| [`51294051938830a1e3d3013a256d851ad4cfa1d3`](https://github.com/manaflow-ai/cmux/commit/51294051938830a1e3d3013a256d851ad4cfa1d3) | Remove the redundant initial build step from TUI setup. | Docs-only, `git diff --check`; users still need the canonical build path. | `git revert 51294051938830a1e3d3013a256d851ad4cfa1d3` |
| [`8af5331e27b832eb517bb5c1892391348b5cb6e9`](https://github.com/manaflow-ai/cmux/commit/8af5331e27b832eb517bb5c1892391348b5cb6e9) | Route runtime diagnostics through the client log. | Hosted TUI runtime check required; raw-terminal ownership and log backpressure remain risks. | `git revert 8af5331e27b832eb517bb5c1892391348b5cb6e9` |
| [`409e9dc1620d47489313752f6cae4b5987d7b274`](https://github.com/manaflow-ai/cmux/commit/409e9dc1620d47489313752f6cae4b5987d7b274) | Add headerless sidebar rails and `+` action rows. | Hosted Rust/UI compile and focused behavior checks required; full visual parity remains open. | `git revert 409e9dc1620d47489313752f6cae4b5987d7b274` |
| [`2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278`](https://github.com/manaflow-ai/cmux/commit/2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278) | Define the cross-language socket-discovery contract. | Docs-only, `git diff --check`; every binding still needs exact-contract tests. | `git revert 2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278` |
| [`91b991496de2667a22e65176a8f11f715e6c089b`](https://github.com/manaflow-ai/cmux/commit/91b991496de2667a22e65176a8f11f715e6c089b) | Reject empty explicit socket paths. | TypeScript Unix-transport test added; hosted cross-language path checks remain required. | `git revert 91b991496de2667a22e65176a8f11f715e6c089b` |
| [`02d1ad45eee31f5d06bad8721b27109eda9c5b6c`](https://github.com/manaflow-ai/cmux/commit/02d1ad45eee31f5d06bad8721b27109eda9c5b6c) | Group terminal-client stream-supervisor state. | Hosted Rust compile/tests required; lifecycle ordering is not proven by refactoring alone. | `git revert 02d1ad45eee31f5d06bad8721b27109eda9c5b6c` |
| [`8cacdf3a375316469672e0e7994eb27190da2318`](https://github.com/manaflow-ai/cmux/commit/8cacdf3a375316469672e0e7994eb27190da2318) | Apply hosted rustfmt to the terminal client. | Formatter-only; `cargo fmt --check` hosted. | `git revert 8cacdf3a375316469672e0e7994eb27190da2318` |
| [`723f2079b3a23536f0deb0d953ed6732f60fa339`](https://github.com/manaflow-ai/cmux/commit/723f2079b3a23536f0deb0d953ed6732f60fa339) | Merge `origin/main` into the relay-tech-debt branch. | Merge integration only; exact-head Rust, SDK, and behavior checks required. | `git revert -m 1 723f2079b3a23536f0deb0d953ed6732f60fa339` |
| [`bf117369edd4fefba01d70de301df7ca9f32f73d`](https://github.com/manaflow-ai/cmux/commit/bf117369edd4fefba01d70de301df7ca9f32f73d) | Fix the macOS autostart clippy warning. | Hosted `cargo clippy`; no behavioral coverage added. | `git revert bf117369edd4fefba01d70de301df7ca9f32f73d` |
| [`ab5e7eb837ce9f11763d7863587acf6edda39042`](https://github.com/manaflow-ai/cmux/commit/ab5e7eb837ce9f11763d7863587acf6edda39042) | Resolve hosted clippy and test imports. | Hosted clippy and focused Rust tests; compile confidence is hosted-only. | `git revert ab5e7eb837ce9f11763d7863587acf6edda39042` |
| [`82ad9c3e555856a34a49617b7302e49a9c78d672`](https://github.com/manaflow-ai/cmux/commit/82ad9c3e555856a34a49617b7302e49a9c78d672) | Apply hosted rustfmt layout to TUI app code. | Formatter-only; hosted compile remains required. | `git revert 82ad9c3e555856a34a49617b7302e49a9c78d672` |
| [`39ba818933857c1d00f5d742349497938091888d`](https://github.com/manaflow-ai/cmux/commit/39ba818933857c1d00f5d742349497938091888d) | Record the relay formatting tail in the board. | Docs-only, `git diff --check`; no runtime claim. | `git revert 39ba818933857c1d00f5d742349497938091888d` |
| [`c11cb7fe95ac7ee6acedf2f8a7db5e17bbec39c8`](https://github.com/manaflow-ai/cmux/commit/c11cb7fe95ac7ee6acedf2f8a7db5e17bbec39c8) | Share socket text-send handling for heartbeat and outbound frames. | Hosted relay tests required; producer cancellation and reconnect ordering remain open. | `git revert c11cb7fe95ac7ee6acedf2f8a7db5e17bbec39c8` |
| [`4d9681833950f454c27060f62d800897ab2488ee`](https://github.com/manaflow-ai/cmux/commit/4d9681833950f454c27060f62d800897ab2488ee) | Bound heartbeat intervals to the Node timer limit. | Boundary tests and hosted cross-language timer checks required; reconnect liveness remains open. | `git revert 4d9681833950f454c27060f62d800897ab2488ee` |
| [`ba8f2941a6b3b32ce73c295605bec86fa1cdc010`](https://github.com/manaflow-ai/cmux/commit/ba8f2941a6b3b32ce73c295605bec86fa1cdc010) | Clean fairness gauge and pending-byte accounting on failed sends. | Hosted relay fairness/disconnect tests required; starvation proof remains open. | `git revert ba8f2941a6b3b32ce73c295605bec86fa1cdc010` |
| [`4325b759694e57af819fd4075045431086717e02`](https://github.com/manaflow-ai/cmux/commit/4325b759694e57af819fd4075045431086717e02) | Service critical relay traffic in bounded bursts. | Hosted relay fairness tests required; queue ownership across retry and shutdown remains open. | `git revert 4325b759694e57af819fd4075045431086717e02` |
| [`2e33e1a07b5a25bccb93fb9e191539127163ab7e`](https://github.com/manaflow-ai/cmux/commit/2e33e1a07b5a25bccb93fb9e191539127163ab7e) | Release shell-start reservation after cap rejection. | Hosted PTY admission test required; process-group cleanup remains open. | `git revert 2e33e1a07b5a25bccb93fb9e191539127163ab7e` |
| [`05c0b30277f5ab9c22516b17a285756e0edbde32`](https://github.com/manaflow-ai/cmux/commit/05c0b30277f5ab9c22516b17a285756e0edbde32) | Merge the relay-tech-debt integration into `aggregate-final`. | Merge only; exact-head Rust, SDK, relay, and UI checks are required. | `git revert -m 1 05c0b30277f5ab9c22516b17a285756e0edbde32` |
| [`ddda4d5e9f9adbf9488e46c4b0e462d262d057ae`](https://github.com/manaflow-ai/cmux/commit/ddda4d5e9f9adbf9488e46c4b0e462d262d057ae) | Record the Wave 23 merge tail. | Docs-only, `git diff --check`; no runtime proof. | `git revert ddda4d5e9f9adbf9488e46c4b0e462d262d057ae` |
| [`f36f57d56ffe90f3ec0cee1069c40b52622f9468`](https://github.com/manaflow-ai/cmux/commit/f36f57d56ffe90f3ec0cee1069c40b52622f9468) | Fix the Java Unix-transport accept test race. | Focused Java UnixTransport test; hosted Java run remains required. | `git revert f36f57d56ffe90f3ec0cee1069c40b52622f9468` |
| [`41c5e637a587c2a7db84d0ddfcb2083894cedb73`](https://github.com/manaflow-ai/cmux/commit/41c5e637a587c2a7db84d0ddfcb2083894cedb73) | Clean up a watch before installing its handle. | Hosted relay watch tests required; disconnect cancellation and filesystem TOCTOU remain open. | `git revert 41c5e637a587c2a7db84d0ddfcb2083894cedb73` |
| [`97dbc18bfd0d83f4abfbe247024fb105f27a411d`](https://github.com/manaflow-ai/cmux/commit/97dbc18bfd0d83f4abfbe247024fb105f27a411d) | Signal raw PTY backlog overflow. | Hosted PTY overflow tests required; raw attach loss semantics remain incomplete. | `git revert 97dbc18bfd0d83f4abfbe247024fb105f27a411d` |
| [`e9a9f89c1ebde8f60d8242c78baac4fcdd30ef3a`](https://github.com/manaflow-ai/cmux/commit/e9a9f89c1ebde8f60d8242c78baac4fcdd30ef3a) | Bound Git workspace paths and status output. | Hosted relay workspace tests required; synchronous filesystem work and TOCTOU remain risks. | `git revert e9a9f89c1ebde8f60d8242c78baac4fcdd30ef3a` |
| [`df28816dba899e11296775a98182a583f431be88`](https://github.com/manaflow-ai/cmux/commit/df28816dba899e11296775a98182a583f431be88) | Correct Rust MSRV component installation syntax. | Workflow YAML/static validation and hosted MSRV job required. | `git revert df28816dba899e11296775a98182a583f431be88` |
| [`bcf0bb643b1031010deab5fa40040d31f2fc94f1`](https://github.com/manaflow-ai/cmux/commit/bcf0bb643b1031010deab5fa40040d31f2fc94f1) | Fix the Zig `Client.connect` resolved type. | Hosted Zig compile/tests required; cross-SDK socket parity remains open. | `git revert bcf0bb643b1031010deab5fa40040d31f2fc94f1` |
| [`8b61aede0bf33318d1bf9f5e04d19bab5256e88b`](https://github.com/manaflow-ai/cmux/commit/8b61aede0bf33318d1bf9f5e04d19bab5256e88b) | Close the Java Unix transport on EOF. | Focused Java transport test; hosted interruption and reconnect checks remain required. | `git revert 8b61aede0bf33318d1bf9f5e04d19bab5256e88b` |
| [`57b8bbeba9c5d44385e1530682c9299ca3db0db6`](https://github.com/manaflow-ai/cmux/commit/57b8bbeba9c5d44385e1530682c9299ca3db0db6) | Satisfy full-workspace clippy. | Hosted `cargo clippy`; no new behavior proof. | `git revert 57b8bbeba9c5d44385e1530682c9299ca3db0db6` |
| [`d85629e39e82e5560818af811bf0f35a255686ce`](https://github.com/manaflow-ai/cmux/commit/d85629e39e82e5560818af811bf0f35a255686ce) | Pass rustup components as separate workflow flags. | Workflow static check and hosted workflow run required. | `git revert d85629e39e82e5560818af811bf0f35a255686ce` |
| [`051d8c17b2a117414245c71c6e02ffb40214554d`](https://github.com/manaflow-ai/cmux/commit/051d8c17b2a117414245c71c6e02ffb40214554d) | Fix Zig connect allocation unwind. | Hosted Zig tests required; allocator failure coverage remains narrow. | `git revert 051d8c17b2a117414245c71c6e02ffb40214554d` |
| [`dfdcf8729466104544fda5a73d337f648b44346c`](https://github.com/manaflow-ai/cmux/commit/dfdcf8729466104544fda5a73d337f648b44346c) | Reject invalid Go transport write counts. | Go socket test added; hosted Go package and protocol checks remain required. | `git revert dfdcf8729466104544fda5a73d337f648b44346c` |
| [`d372eb573dad43bd127a29d9f1b64b1216bf68fa`](https://github.com/manaflow-ai/cmux/commit/d372eb573dad43bd127a29d9f1b64b1216bf68fa) | Close replaced C++ UnixTransport sockets on move assignment. | Hosted C++ transport tests required; move/EOF parity remains cross-SDK risk. | `git revert d372eb573dad43bd127a29d9f1b64b1216bf68fa` |
| [`6d364cf1718ba6fd60556304c411c0af146b2ba1`](https://github.com/manaflow-ai/cmux/commit/6d364cf1718ba6fd60556304c411c0af146b2ba1) | Pin socket runtime fallback order in TypeScript. | TypeScript fallback-order test added; hosted SDK matrix remains required. | `git revert 6d364cf1718ba6fd60556304c411c0af146b2ba1` |
| [`175243036f6a2625d4b9f469b142d6eee2ba40ad`](https://github.com/manaflow-ai/cmux/commit/175243036f6a2625d4b9f469b142d6eee2ba40ad) | Ignore non-contract temporary variables. | Hosted TypeScript tests required; legacy environment ambiguity remains. | `git revert 175243036f6a2625d4b9f469b142d6eee2ba40ad` |
| [`77520f11b8e30aef0bf7750e237b828c1661f644`](https://github.com/manaflow-ai/cmux/commit/77520f11b8e30aef0bf7750e237b828c1661f644) | Suppress TypeScript errors after transport close. | Unix-transport tests added; hosted close/reconnect and callback ordering remain required. | `git revert 77520f11b8e30aef0bf7750e237b828c1661f644` |
| [`5fe58262de2321833f1ee6a69c7391e494976eaf`](https://github.com/manaflow-ai/cmux/commit/5fe58262de2321833f1ee6a69c7391e494976eaf) | Centralize CLI boolean-flag metadata. | Hosted Rust CLI parser tests required; generated help/config parity remains open. | `git revert 5fe58262de2321833f1ee6a69c7391e494976eaf` |
| [`b94e6fd14b9d847bfdc272d90a2827f0781581db`](https://github.com/manaflow-ai/cmux/commit/b94e6fd14b9d847bfdc272d90a2827f0781581db) | Document connection-progress capability. | Docs/spec diff check; runtime capability negotiation remains unproven. | `git revert b94e6fd14b9d847bfdc272d90a2827f0781581db` |
| [`db18624a11397629d8219e4530516fa7009e5526`](https://github.com/manaflow-ai/cmux/commit/db18624a11397629d8219e4530516fa7009e5526) | Await the relay cleanup task after abort. | Hosted relay shutdown test required; all admitted-task ownership is not complete. | `git revert db18624a11397629d8219e4530516fa7009e5526` |
| [`9d0d631694852ec75eb33a1e15c2be44abcafb55`](https://github.com/manaflow-ai/cmux/commit/9d0d631694852ec75eb33a1e15c2be44abcafb55) | Test Python async-close cancellation joining. | `bindings/python/tests/test_resource_api.py`; hosted Python run required. | `git revert 9d0d631694852ec75eb33a1e15c2be44abcafb55` |
| [`b94f21108ee5fd8c6ede4cbc94bf4a9a1dc8c068`](https://github.com/manaflow-ai/cmux/commit/b94f21108ee5fd8c6ede4cbc94bf4a9a1dc8c068) | Bound the relay PTY backlog protocol. | Hosted relay PTY tests required; complete-frame admission and raw attach loss signaling remain separate. | `git revert b94f21108ee5fd8c6ede4cbc94bf4a9a1dc8c068` |
| [`47082c21d40db9c956404e1483984dc8ef510c72`](https://github.com/manaflow-ai/cmux/commit/47082c21d40db9c956404e1483984dc8ef510c72) | Return an explicit relay PTY backlog overflow error. | Hosted PTY overflow behavior required; clients must handle closure and retry. | `git revert 47082c21d40db9c956404e1483984dc8ef510c72` |
| [`0a6a7e2e918e006299d4074197c7966b7d1dc3c6`](https://github.com/manaflow-ai/cmux/commit/0a6a7e2e918e006299d4074197c7966b7d1dc3c6) | Disconnect preview peers on queue saturation. | Hosted preview-proxy saturation test required; one-second flush and loss reporting remain open. | `git revert 0a6a7e2e918e006299d4074197c7966b7d1dc3c6` |
| [`8113a59bd5f5f8443e13277c7f45a096b07c0771`](https://github.com/manaflow-ai/cmux/commit/8113a59bd5f5f8443e13277c7f45a096b07c0771) | Centralize remote invocation classification. | Hosted Rust CLI tests required; non-Unix parity follows in the next commit. | `git revert 8113a59bd5f5f8443e13277c7f45a096b07c0771` |
| [`a6a900a96942f2e61570346f542ea4c7bd69712d`](https://github.com/manaflow-ai/cmux/commit/a6a900a96942f2e61570346f542ea4c7bd69712d) | Reuse invocation classification on non-Unix. | Hosted cross-platform compile/test required; platform-specific CLI behavior remains open. | `git revert a6a900a96942f2e61570346f542ea4c7bd69712d` |
| [`4b12ef9e070558bd3caa50fe8f6407319231863e`](https://github.com/manaflow-ai/cmux/commit/4b12ef9e070558bd3caa50fe8f6407319231863e) | Place connection-progress capability in the summary. | Docs/spec diff check; capability runtime remains unverified. | `git revert 4b12ef9e070558bd3caa50fe8f6407319231863e` |
| [`e8df21eed2866eba03b2548e790ba8a5a887b5da`](https://github.com/manaflow-ai/cmux/commit/e8df21eed2866eba03b2548e790ba8a5a887b5da) | Apply rustfmt to the preview saturation guard. | Formatter-only; hosted exact-head compile and relay tests remain required. | `git revert e8df21eed2866eba03b2548e790ba8a5a887b5da` |

## Final accepted tail from `e8df21eed2` to `ace9e5f57f`

This table records every commit after the previous documented tip. Revert
commands use full object IDs. “Hosted” means the focused check must run on the
hosted builder; this documentation worktree makes no local Rust test claim.

| Commit | Change | Tests / residual risk | Exact revert |
| --- | --- | --- | --- |
| [`c906a2ff62b73968b32d00e48072f5afe15d5351`](https://github.com/manaflow-ai/cmux/commit/c906a2ff62b73968b32d00e48072f5afe15d5351) | Reap the relay child process on every credential failure. | Hosted remote-provider failure test required; process-group and descendant cleanup remain open. | `git revert c906a2ff62b73968b32d00e48072f5afe15d5351` |
| [`fb3ac754c5d55869f968289e3906e3b6b6b0872e`](https://github.com/manaflow-ai/cmux/commit/fb3ac754c5d55869f968289e3906e3b6b6b0872e) | Own the journal-writer lifecycle in the TUI core. | Hosted journal/mux shutdown tests required; reducer ownership and restart recovery remain open. | `git revert fb3ac754c5d55869f968289e3906e3b6b6b0872e` |
| [`42b776a327c17386d131ef1b1f8a382b02683954`](https://github.com/manaflow-ai/cmux/commit/42b776a327c17386d131ef1b1f8a382b02683954) | Record the Wave 24 SDK and overflow tail in the board. | Docs-only, `git diff --check`; no runtime proof. | `git revert 42b776a327c17386d131ef1b1f8a382b02683954` |
| [`cef7c71460f72444e874f7c9f26100e9259874c1`](https://github.com/manaflow-ai/cmux/commit/cef7c71460f72444e874f7c9f26100e9259874c1) | Record the aggregate changelog at the prior tip. | Docs-only, `git diff --check`; superseded by this final-tip update. | `git revert cef7c71460f72444e874f7c9f26100e9259874c1` |
| [`ab2b944ab81a2ebf09a0c595b185344665f9c74f`](https://github.com/manaflow-ai/cmux/commit/ab2b944ab81a2ebf09a0c595b185344665f9c74f) | Hand journal-writer self-join back to the owner. | Hosted journal shutdown test required; cross-owner cancellation ordering remains open. | `git revert ab2b944ab81a2ebf09a0c595b185344665f9c74f` |
| [`5f6bf91e760c1feb97671aa19f800e3e4f80674d`](https://github.com/manaflow-ai/cmux/commit/5f6bf91e760c1feb97671aa19f800e3e4f80674d) | Use bindable legacy fallback sessions in the Rust SDK. | Hosted Rust SDK socket tests required; legacy path and long-name compatibility remain open. | `git revert 5f6bf91e760c1feb97671aa19f800e3e4f80674d` |
| [`8523b8f7151bdb032d011cb512a32e878fc813da`](https://github.com/manaflow-ai/cmux/commit/8523b8f7151bdb032d011cb512a32e878fc813da) | Name the Zig resolved connection result consistently. | Hosted Zig compile/tests required; cross-SDK result-shape parity remains open. | `git revert 8523b8f7151bdb032d011cb512a32e878fc813da` |
| [`5f8860398ee30e255f37cc5e8633159fb0058aa1`](https://github.com/manaflow-ai/cmux/commit/5f8860398ee30e255f37cc5e8633159fb0058aa1) | Coordinate journal finalization across ingress and mux. | Hosted journal finalization/restart tests required; append ownership and idempotency remain open. | `git revert 5f8860398ee30e255f37cc5e8633159fb0058aa1` |
| [`09190e6da92b60a60000913b9cbf9931ea4b94c7`](https://github.com/manaflow-ai/cmux/commit/09190e6da92b60a60000913b9cbf9931ea4b94c7) | Apply hosted formatting to journal finalization. | Formatter-only; hosted journal compile remains required. | `git revert 09190e6da92b60a60000913b9cbf9931ea4b94c7` |
| [`782fba0f2abe4f41c74a060caffa36a9c3efc73d`](https://github.com/manaflow-ai/cmux/commit/782fba0f2abe4f41c74a060caffa36a9c3efc73d) | Create missing parent directories for explicit sockets. | Hosted server socket tests required; permissions and symlink/TOCTOU policy remain open. | `git revert 782fba0f2abe4f41c74a060caffa36a9c3efc73d` |
| [`f5fdf26ccd8f931623adabe711b898b47665d722`](https://github.com/manaflow-ai/cmux/commit/f5fdf26ccd8f931623adabe711b898b47665d722) | Clean Unix sockets synchronously when the remote server drops. | Hosted remote drop/cleanup tests required; crash recovery and cross-platform parity remain open. | `git revert f5fdf26ccd8f931623adabe711b898b47665d722` |
| [`80fd1621fa8dfa5b25b5767f9711c8afa15e5b65`](https://github.com/manaflow-ai/cmux/commit/80fd1621fa8dfa5b25b5767f9711c8afa15e5b65) | Retain the socket lease until the listener task drops. | Hosted listener lifecycle tests required; abandoned-task cleanup remains open. | `git revert 80fd1621fa8dfa5b25b5767f9711c8afa15e5b65` |
| [`c8ec5be775352f54acb0707abc13efa6e4be163b`](https://github.com/manaflow-ai/cmux/commit/c8ec5be775352f54acb0707abc13efa6e4be163b) | Construct hashed fallback endpoints safely in Rust SDK clients. | Hosted Rust SDK fallback tests required; cross-language long-path parity remains open. | `git revert c8ec5be775352f54acb0707abc13efa6e4be163b` |
| [`44a2f0513465da2e81c484319f2e44827a0491d8`](https://github.com/manaflow-ai/cmux/commit/44a2f0513465da2e81c484319f2e44827a0491d8) | Apply hosted Rust formatting to SDK fallback changes. | Formatter-only; hosted SDK compile remains required. | `git revert 44a2f0513465da2e81c484319f2e44827a0491d8` |
| [`11c309d7013a5be96a9bc0d00a44f7b75e850399`](https://github.com/manaflow-ai/cmux/commit/11c309d7013a5be96a9bc0d00a44f7b75e850399) | Preserve executable mode for relay and cmux npm launchers. | Package artifact mode/smoke checks required; registry-install and platform matrix remain open. | `git revert 11c309d7013a5be96a9bc0d00a44f7b75e850399` |
| [`c56afcad5fe8ba0c1583e9b8f53335faaeeb4e3a`](https://github.com/manaflow-ai/cmux/commit/c56afcad5fe8ba0c1583e9b8f53335faaeeb4e3a) | Add coverage for 8-bit C1 cursor controls. | Focused cursor-provenance test; hosted TUI parser suite remains required. | `git revert c56afcad5fe8ba0c1583e9b8f53335faaeeb4e3a` |
| [`ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6`](https://github.com/manaflow-ai/cmux/commit/ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6) | Parse 8-bit C1 cursor controls in the TUI session parser. | Focused cursor-provenance test from the prior commit; hosted parser and compatibility tests remain required. | `git revert ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6` |

## User-session intent audit

The following intents were mined from local `~/.codex` and `~/.claude` session
records and remain acceptance requirements. A code commit or documentation
entry is not completion evidence unless the stated behavior is exercised.

| Intent | Evidence | Current status |
| --- | --- | --- |
| One canonical session with stable device/session IDs across macOS and iPhone. | `/Users/lawrence/.codex/history.jsonl`, `/Users/lawrence/.claude/history.jsonl` | Open. No multi-device catalog and reorder proof. |
| PTY ownership survives cmux or renderer restart, with one worker per workspace. | `/Users/lawrence/.codex/sessions/2026/07/16/` rollout record | Open. No restart, duplicate-reader, or startup-order proof. |
| Versioned TUI IPC carries input, resize, focus, sequence, launch, and restart state with measured isolation. | Same 2026-07-16 rollout record | Open. No valid renderer/PTY performance result. |
| Stale panes and surfaces self-heal without duplicate viewers or orphan PTYs. | Local history and rollout records | Open. Reconnect and stale-host behavior need bounded tests. |
| Journal-first persistence restores projections, receipts, PTY intent, and host reboot outcomes. | `/Users/lawrence/.codex/history.jsonl`, `/Users/lawrence/.claude/history.jsonl` | Open. Snapshots and process restarts are not restore proof. |
| npm/PyPI packages install offline and pass executable smoke checks on supported targets. | `.github/workflows/cmux-tui-build-package.yml`, `tests/test_tui_npm_package_artifact.py` | Partial. Hosted publish and registry-install proof remain open. |
| One authenticated socket/WebSocket/Iroh contract supports ordered events, bounded frames, reconnect, and close. | Local history and socket contract docs | Open. Cross-transport exact-head tests remain required. |
| Remote attach and Iroh discovery preserve PTY ownership, latency, reconnect, and cleanup. | Local history and Iroh preflight records | Open. Existing preflight did not establish a live host/socket. |
| Cloud snapshots package tools only, never serve as live PTY persistence or restart guarantees. | Local cloud-session records | Explicit no-go. Provider restore semantics and secret boundaries remain unproven. |
| Semantic colors, cursor, font, graphics, and theme-query behavior match Ghostty across platforms. | Local history and [PR #10612](https://github.com/manaflow-ai/cmux/pull/10612) | Open. `theme.chrome=auto` documentation/runtime mismatch remains. |

## Residual risks and verification boundary

- Queue count and byte caps do not yet prove producer cancellation, permit
  release, or ownership across disconnect, retry, and shutdown.
- PTY admission bounds complete frames, but raw attach backlog loss still lacks
  a complete rejection or loss signal and late output after close needs a
  contract.
- Synchronous filesystem work and canonicalization can block request paths;
  validation and later use retain a parent-directory TOCTOU window.
- Relative PTY cwd migration needs an absolute or home-relative contract, and
  Iroh teardown can wait through a long pre-auth timeout.
- The 25-file integration merge needs exact-head Rust, SDK, relay, and UI
  checks. No local Rust compile or end-to-end hosted result is claimed here.
- Journal finalization and self-join handoff now have explicit owners, but
  restart recovery, abort races, and durable outcome receipts still need an
  end-to-end hosted test.
- Explicit socket parent creation, synchronous unlink, and lease retention
  improve cleanup, but permissions, symlink/TOCTOU behavior, crash recovery,
  and abandoned listener tasks remain open.
- The npm executable-mode fix and C1 cursor parser tests cover narrow artifact
  and parser paths only. Registry installation, platform parity, and complete
  terminal escape compatibility remain unverified.

Session ledger honesty: the board's lower bound is at least 180 substantive
agent turns, including audits, research, session mining, fixes, reviews, and
merge gates. It is not an exact session-file count. The requested 10,000-session
goal was not reached. Empty or duplicate turns were not created to inflate it.
