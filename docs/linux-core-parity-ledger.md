# Linux Core Parity Ledger

Last updated: April 30, 2026

이 문서는 Linux cmux가 macOS cmux의 핵심 작업 흐름과 어느 정도 맞춰져 있는지 추적한다. 기준은 `Packages/CMUXCore/Sources/CMUXCore/SocketMethodRegistry.swift`의 production method 목록과 macOS 앱의 workspace/surface/pane/browser 동작이다.

## 완료 기준

1차 완료 기준은 다음 핵심 흐름이 Linux GTK/VTE/WebKitGTK 구현에서도 같은 사용자 모델로 동작하는 것이다.

1. workspace 안에 surface/tab이 있고 각 surface가 pane split tree를 가진다.
2. terminal, browser, split, close, focus, send/read 명령이 workspace 범위 안에서 동작한다.
3. `system.capabilities`가 구현된 method와 Linux 한계를 정확히 드러낸다.
4. macOS production socket method 이름은 Linux에서도 모두 선언되고, 1차 MVP 구현 또는 명확한 capability 한계로 설명된다.

## 기능 매트릭스

| 영역 | 상태 | Linux 구현 | 남은 차이 |
|---|---|---|---|
| Window/system | API parity 구현 | `system.tree`, `window.list/current/focus/create/close`를 지원한다. Linux는 application-level GTK window registry를 두고 `window.create`로 독립 window를 만들며, 조회성 command는 focus를 훔치지 않는다. `window.focus`만 명시적 focus-intent로 GTK window를 present한다. 마지막 window close 정책은 `quit_app`으로 고정했다. Window payload는 workspace id 목록과 current workspace aliases를 포함한다. JSON socket smoke와 v1 text CLI smoke가 window create/focus/close lifecycle을 검증한다. | VM/CI에서 실제 GTK window manager별 focus behavior 확인이 남아 있다. |
| Workspace 기본 | 동일 구현 진행 | `workspace.list/current/create/select/close/reorder/rename/action/next/previous/last/equalize_splits/move_to_window` 지원. `workspace.action`은 macOS action 목록의 pin/unpin, rename/clear_name, set/clear description, set/clear color, move_up/down/top, close_others/above/below, mark_read/unread를 Linux runtime state와 연결한다. workspace snapshot과 persisted session snapshot은 `is_pinned`, `description`, `color` alias를 포함한다. `workspace.create`는 기본적으로 focus를 훔치지 않고 `select/focus/activate`가 있을 때 선택한다. `workspace.move_to_window`는 GTK window registry에서 source/target window를 찾아 workspace surface root를 실제로 target stack에 옮기고 current window focus를 보존한다. close는 현재 workspace를 닫을 때 macOS처럼 같은 index의 다음 workspace를 우선 선택한다. `workspace.remote.*`는 configuration/status/foreground-auth/terminal-session-end 계약을 persistent Linux runtime state로 구현하고, 설치된 `cmuxd-remote` 실행 파일 상태를 `workspace.remote.status.daemon`에 노출한다. Remote configure/reconnect는 SSH bootstrap, `cmuxd-remote serve --stdio` hello/ping probe, HMAC local relay server, `ssh -N -R` reverse-forward subprocess lifecycle을 시작한다. `workspace.remote.foreground_auth_ready`는 foreground auth/token presence를 secret 없이 저장하고 auto-connect proxy가 없으면 bootstrap/proxy lifecycle을 재개한다. `workspace.remote.terminal_session_end`는 surface 전체 또는 pane 단위 종료를 기록하고, status active session detail은 같은 surface의 다른 terminal pane을 보존한다. | remote relay end-to-end smoke는 CI에 연결됐다. GitHub Actions runner에서 localhost sshd, reverse-forward, HMAC relay ping 통과 확인이 남아 있다. |
| Surface/tab 기본 | 동일 구현 진행 | `surface.list/current/create/focus/select/close/move/reorder/drag_to_split/refresh/health/trigger_flash/split/action/clear_history`, `tab.action` 지원. `surface.current/list`는 `workspace_id`를 받아 현재 workspace 밖 surface도 조회한다. `move/reorder`는 현재 workspace/sidebar 순서를 갱신하고, `health/refresh/flash`는 조회성 또는 redraw 동작으로 focus를 훔치지 않는다. | Linux pane 모델은 surface가 split tree를 소유하므로 `surface.drag_to_split`과 pane 대상 `surface.move`는 MVP에서 단일-pane surface 이동만 지원한다. |
| Pane 기본 | 동일 구현 진행 | `pane.list/focus/surfaces/create/resize/swap/break/join/last/close`, legacy `pane.sendText` 지원. pane 조회는 surface/workspace 범위를 존중하고 `swap/break/join`은 명시적 `focus=true`가 없으면 현재 선택을 보존한다. | Linux pane은 현재 macOS처럼 pane 안에 여러 surface tab을 보관하지 않고 surface 안 split pane으로 매핑한다. resize는 GTK split divider 조작 기반이다. |
| Terminal | Linux-native 대응 | VTE terminal을 사용하고 `surface.send_text`, `surface.send_key`, `surface.read_text`, `surface.clear_history`, `surface.report_tty`, `surface.ports_kick`를 지원한다. `report_tty`는 socket telemetry로 받은 tty 이름을 surface에 저장하고, `ports_kick`는 Linux VTE에서 아직 포트 스캔을 수행하지 않는 안정 shape 응답을 반환한다. | GhosttyKit 렌더링과 macOS 포트 스캐너 parity는 아직 없다. |
| Browser chrome | 동일 구현 진행 | WebKitGTK toolbar, address entry, back/forward/reload/stop/close, blank/data URL 숨김 규칙, title/url sync를 제공한다. | macOS WKWebView와 완전히 같은 process/profile 격리는 아직 없다. |
| Browser/markdown automation | Linux MVP 구현 확대 | navigate, eval, wait, element action, find, storage/cookie, screenshot, console/error, tab surface 관리 명령을 지원한다. `frame.select/main`, dialog policy, viewport size request, geolocation/offline JS emulation, trace/performance 수집, network request listing, screencast frame capture, raw keyboard/mouse/touch emulation을 socket method로 제공한다. `markdown.open`은 파일을 읽어 WebKitGTK preview split으로 연다. | WebKitGTK native hook 부재로 network route/unroute는 request interception이 아니라 metadata 보존이다. touch/geolocation/offline/dialog는 JS emulation이며 macOS WKWebView 수준의 process/profile 격리는 아직 없다. Markdown preview는 Linux-native HTML preview이며 macOS SwiftUI markdown panel과 완전히 같지는 않다. |
| Notification/debug | API parity 1차 구현 | `notification.create/list/clear/create_for_surface/create_for_target`를 지원한다. 생성 경로는 `Gio.Notification`을 유지하고 socket 조회용 in-memory ledger에 workspace/surface target metadata를 보존한다. `workspace.action mark_read/mark_unread`는 workspace notification ledger의 읽음 상태를 갱신한다. `debug.terminals`는 현재 VTE terminal pane의 workspace/surface/pane/tty 진단 정보를 반환한다. | 원격 terminal 진단, macOS GhosttyKit 전용 필드는 아직 없다. |
| Auth/feed/feedback/session | backend 연결 진행 | `auth.login/status/begin_sign_in/sign_out`는 Swift `CMUXAuthCore` auth bridge가 있으면 shared cached user/team/session state를 사용하고, bridge unavailable 시 Linux local fallback 상태를 명시한다. `feed.push/list/jump/*reply`는 persistent workstream ledger, 120초 soft wait, reply delivery stdout decision JSON을 제공한다. `feedback.submit`은 HTTP multipart upload endpoint가 있으면 전송하고 실패 시 local queued submission으로 남긴다. `session.restore_previous`는 저장된 workspace/surface/pane snapshot을 현재 GTK window에 복원한다. | feed coordinator UI와 full cloud/backend 성공 경로는 CI/제품 backend 환경에서 추가 검증이 필요하다. |
| Public API | 동일 구현 진행 | Linux `SUPPORTED_METHODS`는 macOS production method 이름을 모두 선언한다. `UNSUPPORTED_METHODS`는 현재 비어 있으며, `legacyAliases`, `methodStatus`, `features`, `remoteDaemon`을 capabilities에 포함하고 `settings.open`, `app.focus_override.set`, `app.simulate_active`는 Linux-native 상태 처리로 연결한다. 실패 응답은 공통 failure code와 backend/capability reason을 우선한다. | 모든 method 이름은 응답하지만 일부 backend-limit method는 Linux WebKitGTK/VTE 의미다. |
| CLI | 호환 유지 | `bin/cmux` fallback CLI는 socket JSON protocol로 Linux 앱과 통신한다. Linux socket server는 remote Go CLI용 v1 text command(`ping`, `new_window`, `current_window`, `focus_window`, `close_window`, `list_windows`)도 macOS text response shape로 처리한다. Xvfb socket smoke는 이 v1 text command를 실제 Unix socket으로 호출한다. Artifact validator는 `--require-swift-cli` 사용 시 `bin/cmux` content를 검사해 ELF Swift CLI binary가 아닌 fallback shebang wrapper나 일반 텍스트 payload를 auth bridge CLI로 오인하지 않도록 거부한다. | Swift/Go CLI parity는 CI/VM 빌드 결과 확인이 필요하다. |
| Shortcuts/settings | 동일 구현 진행 | `~/.config/cmux/settings.json` 또는 `CMUX_SETTINGS_PATH`에서 `keyboardShortcuts`/`shortcuts`를 읽고 핵심 action을 GTK key event에 연결한다. Linux에서는 `cmd`/`command`를 Meta/Super로 해석하며 command palette와 `settings.open` 기반 shortcut editor UI를 제공한다. | macOS Settings 전체 화면 parity는 아직 없다. |
| Packaging | Linux-native 대응 | `linux/package.sh`가 tarball을 만들고, `linux/package-deb.sh`, `linux/package-appimage.sh`, `linux/package-rpm.sh`, `linux/package-flatpak.sh`가 같은 staging으로 Debian/AppImage/rpm/Flatpak package를 만든다. Linux에서 `scripts/reload.sh --tag ...`는 `scripts/reload-linux.sh`로 전환되어 Python tool compile, package shell syntax, Linux contract validator, socket parity, tarball packaging을 수행한다. `--launch`를 주면 tag별 socket/log/pid 경로로 GTK 앱을 실행한다. Package validator가 필수 파일, 실행 권한, pycache 누락, desktop entry, artifact manifest를 확인하고 CI artifact는 Swift CLI와 `cmuxd-remote` Linux 바이너리를 포함하도록 검증한다. CI validator는 `--probe-remote-daemon`으로 각 artifact에서 꺼낸 `cmuxd-remote serve --stdio` hello/ping을 실행하고 `pong=true`와 `proxy.stream.push` capability를 확인한다. Tarball/deb/AppImage/rpm/Flatpak builders는 포함된 binary에 맞춰 자체 validator에도 `--require-swift-cli`/`--require-remote-daemon`을 넘긴다. Flatpak validator도 bundle import 후 OSTree checkout의 `/app` tree를 검사한다. CI job은 tarball/deb/AppImage/rpm/Flatpak artifact를 각각 업로드한다. | full SSH end-to-end 검증은 CI smoke에 연결됐고 runner 결과 확인이 남아 있다. |

## Capability 정책

Linux 앱의 `system.capabilities`는 다음을 노출한다.

- `methods`: Linux socket server가 이름을 인지하는 method.
- `methodStatus`: method별 `supported` 또는 `unsupported`.
- `unsupportedMethods`: Linux backend에서 아직 실행하지 않는 method. 현재 macOS production parity 기준으로는 비어 있다.
- `legacyAliases`: Linux 호환 alias. 현재 `browser.open`, `pane.sendText`, `surface.select`를 유지한다.
- `features`: `terminal`, `surface-tabs`, `split-tabs`, `pane-split`, `browser-panel`, `browser-chrome`, `shortcut-settings`, `keyboard-shortcuts`, `window-api`, `notification-store`, `surface-telemetry`, `browser-automation-mvp`, `markdown-preview`, `app-focus-override`, `auth-local-mvp`, `feed-store`, `feedback-local-store`, `remote-workspace-status-mvp`, `session-restore-mvp`, `persistent-linux-runtime-state`, `session-restore-snapshot`.
- `settings`: 로드된 settings path, 편집 가능 여부, target 목록, 핵심 shortcut token 목록.
- `state`: runtime state path, load 여부, schema version, restore 가능 여부.
- `remoteDaemon`: packaged 또는 명시 경로의 `cmuxd-remote` 실행 파일 존재 여부, path, bundled 여부, lifecycle 상태.
- `limitations`: Linux backend의 명시적 한계.

## 정적 검증

macOS production method와 Linux method ledger는 다음 도구로 비교한다.

```bash
python3 linux/tools/socket_method_parity.py
python3 linux/tools/socket_method_parity.py --json
python3 linux/tools/socket_method_parity.py --strict --json
```

`--strict`는 macOS production method가 Linux에 선언되지 않은 경우 또는 `UNSUPPORTED_METHODS`에 선언된 method가 `SUPPORTED_METHODS`에 없는 경우 실패한다. 1차 API parity 이후 macOS-only method와 Linux unsupported method는 없어야 한다. 제품 의미가 macOS와 다른 Linux MVP는 `system.capabilities.features`와 `limitations`에 남긴다.

실행 중인 tagged Linux 앱을 대상으로 runtime socket smoke를 수행할 수 있다. `--state`는 Linux runtime state 파일에 auth/feed/feedback/remote/session snapshot이 저장되는지 검증한다.

```bash
CMUX_SOCKET_PATH=/tmp/cmux-linux-linux-core-parity.sock python3 linux/tools/socket_smoke.py --json
CMUX_SOCKET_PATH=/tmp/cmux-linux-linux-core-parity.sock python3 linux/tools/socket_smoke.py --browser --state --json
```

`--remote-ssh`는 CI/VM에서 localhost sshd 또는 테스트 SSH 대상이 준비된 경우에만 사용한다. 이 경로는 remote configure auto-connect, remote daemon stdio hello/ping, reverse-forward relay, HMAC-authenticated socket ping, disconnect cleanup을 검증한다.

## 다음 우선순위

1. CI의 `linux-distribution-artifact` job 결과를 기준으로 GTK/VTE/WebKitGTK smoke와 tarball artifact 검증을 안정화한다.
2. remote workspace의 SSH relay lifecycle은 CI smoke에 연결됐다. 다음은 GitHub Actions runner에서 localhost sshd, reverse-forward, HMAC relay ping 결과를 확인하고 실패 케이스를 보강한다.
3. AppImage/rpm/Flatpak CI artifact build/upload와 packaged remote daemon stdio probe는 workflow에 연결됐다. 다음 확인은 GitHub Actions runner에서 builder 설치와 artifact validation이 실제로 통과하는지 보는 것이다.
