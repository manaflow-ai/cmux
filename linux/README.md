# cmux Linux 배포본

이 디렉터리는 Linux용 cmux 초기 배포본을 만드는 최소 런타임을 담고 있습니다. 현재 Linux 포트는 GTK4/VTE를 우선 사용하고 GTK3/VTE2.91로 폴백하며, CLI/소켓 호환성, 터미널 워크스페이스, pane split, WebKitGTK 기반 브라우저 pane을 먼저 제공합니다.

## 런타임 의존성

Ubuntu/Debian 계열 기준 GTK4/VTE3 패키지를 먼저 권장합니다.

```bash
sudo apt install python3 python3-gi gir1.2-gtk-4.0 gir1.2-vte-3.91
```

배포판에 VTE 3.91 패키지가 없으면 GTK3/VTE2.91 폴백으로 실행할 수 있습니다.

```bash
sudo apt install python3 python3-gi gir1.2-gtk-3.0 gir1.2-vte-2.91
```

브라우저 pane은 WebKitGTK introspection 패키지가 있으면 실제 WebView를 사용합니다. 패키지가 없으면 앱 안에 설치 안내 pane을 표시합니다. GTK4 backend에서는 WebKitGTK 6.0, GTK3 fallback에서는 WebKit2GTK 4.1 또는 4.0 binding을 사용합니다.

```bash
sudo apt install gir1.2-webkitgtk-6.0
sudo apt install gir1.2-webkit2-4.1
```

## 실행

패키지 압축을 풀고 다음 명령을 실행합니다.

```bash
./bin/cmux-linux
```

기본 소켓 경로는 `$XDG_RUNTIME_DIR/cmux/cmux.sock`입니다. `XDG_RUNTIME_DIR`이 없으면 `/tmp/cmux/cmux.sock`을 사용합니다. 별도 경로가 필요하면 `--socket` 또는 `CMUX_SOCKET_PATH`를 사용할 수 있습니다.

tarball에는 `bin/cmux` CLI도 함께 들어갑니다. CI/VM에서 SwiftPM Release CLI가 빌드된 경우 실제 Swift CLI를 포함하고, 로컬 패키징 환경에 Swift 툴체인이 없으면 같은 socket JSON 프로토콜을 사용하는 Python fallback CLI를 포함합니다. 앱을 먼저 실행해 socket을 연 뒤 같은 패키지의 CLI로 socket 명령을 보낼 수 있습니다.

```bash
./bin/cmux-linux --socket /tmp/cmux-dev.sock
CMUX_SOCKET_PATH=/tmp/cmux-dev.sock ./bin/cmux ping
CMUX_SOCKET_PATH=/tmp/cmux-dev.sock ./bin/cmux browser.open_split '{"url":"https://example.com"}'
```

## 패키징

저장소 루트에서 다음 스크립트가 tarball을 생성합니다.

```bash
bash linux/package.sh
```

결과물은 `dist/cmux-linux-x86_64.tar.gz`에 생성됩니다. `CLI/.build/release/cmux`가 있으면 `bin/cmux`로 함께 포함하고, 없으면 `linux/bin/cmux` fallback CLI를 포함합니다. 다른 경로의 CLI 바이너리를 넣으려면 `CMUX_LINUX_CLI_BINARY`를 지정합니다.

`daemon/remote/cmuxd-remote` 또는 `CMUX_LINUX_REMOTE_DAEMON_BINARY`가 가리키는 파일이 있으면 tarball의 `bin/cmuxd-remote`로 함께 포함합니다. remote daemon을 필수 artifact로 검증하려면 validator에 `--require-remote-daemon`을 추가합니다.
tarball에는 `share/cmux/package-manifest.json`도 포함됩니다. manifest는 GTK 앱, CLI, Python 런타임, desktop entry, 선택적 remote daemon 포함 여부와 현재 배포 포맷 상태를 기록하며, `linux/tools/validate_package.py`가 manifest와 실제 tarball 내용을 함께 검증합니다.

```bash
CMUX_LINUX_CLI_BINARY=CLI/.build/release/cmux \
CMUX_LINUX_REMOTE_DAEMON_BINARY=daemon/remote/cmuxd-remote \
  bash linux/package.sh
python3 linux/tools/validate_package.py dist/cmux-linux-x86_64.tar.gz --require-remote-daemon
```

Debian 계열 배포용 `.deb` artifact는 tarball staging을 재사용해 생성합니다. CI에서는 Swift CLI와 Go remote daemon이 들어간 staging을 먼저 만든 뒤 `.deb` validator를 `--require-remote-daemon --require-swift-cli` 조건으로 실행합니다.

```bash
bash linux/package-deb.sh
python3 linux/tools/validate_package.py dist/cmux-linux_*.deb
```

AppImage/rpm/Flatpak은 같은 tarball staging과 manifest contract를 재사용합니다. 각 스크립트는 필요한 외부 builder가 설치되어 있을 때 산출물을 만들고 `linux/tools/validate_package.py`로 artifact를 검증합니다. Flatpak validator는 `ostree`를 사용해 bundle을 임시 repo로 import한 뒤 app checkout의 `/app` 파일 tree, desktop entry, manifest, 실행 권한까지 확인합니다.

```bash
bash linux/package-appimage.sh
bash linux/package-rpm.sh
bash linux/package-flatpak.sh
python3 linux/tools/validate_package.py dist/cmux-linux-x86_64.AppImage
python3 linux/tools/validate_package.py dist/cmux-linux-*.x86_64.rpm
python3 linux/tools/validate_package.py dist/cmux-linux-x86_64.flatpak
```

macOS 개발용 `scripts/reload.sh`는 Linux에서 자동으로 Linux reload 경로로 전환됩니다. 저장소 루트에서 다음 명령을 실행하면 Python tool compile, shell syntax, Linux contract validator, socket parity 정적 검증과 tarball 패키징을 한 번에 수행합니다.

```bash
./scripts/reload.sh --tag linux-core-parity
```

GUI 세션에서 앱까지 실행하려면 `--launch`를 추가합니다. 이 경우 tag별 socket/log/pid 경로를 `/tmp` 아래에 분리해서 사용합니다.

```bash
./scripts/reload.sh --tag linux-core-parity --launch
CMUX_SOCKET_PATH=/tmp/cmux-linux-linux-core-parity.sock linux/bin/cmux ping
```

## 설정과 단축키

Linux 앱은 macOS와 같은 우선순위로 `~/.config/cmux/settings.json`을 읽습니다. 다른 파일을 테스트하려면 `CMUX_SETTINGS_PATH`를 지정할 수 있습니다.

```json
{
  "keyboardShortcuts": {
    "newSurface": "ctrl+t",
    "splitRight": "ctrl+d",
    "focusBrowserAddressBar": "ctrl+l"
  }
}
```

현재 설정 가능한 핵심 action은 `newSurface`, `openBrowser`, `splitRight`, `splitDown`, `closeTab`, `nextSurface`, `previousSurface`, `nextSidebarTab`, `previousSidebarTab`, `focusBrowserAddressBar`, `browserBack`, `browserForward`, `browserReload`, `commandPalette`, `openSettings`입니다. 기본값은 macOS 단축키 이름을 따르며 Linux에서는 `cmd`/`command`를 Meta/Super 키로 해석합니다. `settings.open` 또는 기본 `cmd+,` 단축키로 Linux-native Settings dialog를 열어 단축키를 편집할 수 있고, `system.capabilities.settings.shortcuts`에서 실제 로드된 단축키 token을 확인할 수 있습니다.

## 현재 지원 범위

- GTK4/VTE 또는 GTK3/VTE2.91 기반 터미널 창
- 새 터미널 tab 생성
- 터미널 pane 좌우/상하 분할
- WebKitGTK 기반 브라우저 pane
- `~/.config/cmux/settings.json` 기반 핵심 단축키, Linux-native Settings dialog, 간단한 command palette
- Unix domain socket 기반 JSON 명령 수신
- Linux SwiftPM Release CLI 바이너리 또는 Python fallback socket CLI 포함
- 선택적 `bin/cmuxd-remote` remote daemon 바이너리 포함, artifact manifest, tarball/deb/AppImage/rpm/Flatpak 구조 검증
- `system.ping`, `system.identify`, `system.capabilities`, `settings.open`
- `workspace.list`, `workspace.current`, `workspace.create`, `workspace.select`, `workspace.close`, `workspace.reorder`, `workspace.rename`, `workspace.action`, `workspace.next`, `workspace.previous`, `workspace.last`, `workspace.equalize_splits`
- `surface.list`, `surface.current`, `surface.create`, `surface.focus`, `surface.select`, `surface.close`, `surface.move`, `surface.reorder`, `surface.drag_to_split`, `surface.refresh`, `surface.health`, `surface.trigger_flash`, `surface.split`, `surface.action`, `surface.send_text`, `surface.send_key`, `surface.read_text`, `surface.clear_history`
- `tab.action` 호환 surface action 경로
- `pane.list`, `pane.focus`, `pane.surfaces`, `pane.create`, `pane.resize`, `pane.swap`, `pane.break`, `pane.join`, `pane.last`, `pane.close`
- `browser.open`, `browser.open_split`, `browser.navigate`, `browser.url.get`, `browser.back`, `browser.forward`, `browser.reload`
- WebKitGTK JavaScript bridge 기반 `browser.eval`, `browser.wait`, `browser.fill`, `browser.click`, `browser.get.*`, `browser.is.*`, `browser.snapshot`, `browser.screenshot`
- 브라우저 보조 명령: element find refs, storage/cookie 기초 명령, browser tab surface 관리, addscript/addstyle/addinitscript
- Linux MVP browser automation: `browser.frame.*`, `browser.dialog.*`, `browser.viewport.set`, `browser.geolocation.set`, `browser.offline.set`, `browser.trace.*`, `browser.network.*`, `browser.screencast.*`, `browser.input_*`
- `markdown.open` WebKitGTK preview split, `app.focus_override.set`, `app.simulate_active`
- Linux local-state MVP API: `auth.*`, `feed.*`, `feedback.*`, `workspace.remote.*`, `session.restore_previous`
- `system.capabilities`는 `methods`, `methodStatus`, `unsupportedMethods`, `legacyAliases`, `features`, `settings`, `state`, `remoteDaemon`, `limitations`를 노출
- WebKitGTK에서 native hook을 직접 제공하지 않는 일부 browser automation은 JS emulation 또는 metadata-preserving MVP로 동작한다. 예를 들어 network route는 실제 request interception 대신 route metadata를 보존한다.
- `notification.create`의 데스크톱 알림 연결

macOS production socket method 이름은 모두 선언되어 있고 `UNSUPPORTED_METHODS`는 비어 있습니다. 다만 `auth.*`, `feed.*`, `feedback.*`, `workspace.remote.*`, `session.restore_previous`는 Linux local-state MVP 또는 backend fallback을 포함합니다. 계정 상태, feed/reply ledger, feedback submission ledger, remote workspace configuration/status, session snapshot은 Linux state 파일에 저장되고 다음 실행에서 복원할 수 있습니다. `bin/cmuxd-remote` 또는 `CMUX_LINUX_REMOTE_DAEMON_BINARY`가 가리키는 실행 파일은 `system.capabilities.remoteDaemon`과 `workspace.remote.status.daemon`에 노출됩니다. remote daemon SSH bootstrap/probe/reverse-forward process lifecycle과 local HMAC relay server는 연결되어 있지만, VM/CI full SSH relay smoke, GhosttyKit 기반 렌더링, SwiftUI 패널 전체는 후속 범위입니다.

## Linux runtime state

Linux 앱은 local-state MVP 데이터를 JSON state 파일에 저장합니다. 기본 경로는 `$XDG_STATE_HOME/cmux/linux-state.json`이고, `XDG_STATE_HOME`이 없으면 `~/.local/state/cmux/linux-state.json`을 사용합니다. 테스트나 tagged 개발 실행에서는 `CMUX_LINUX_STATE_PATH`로 격리된 파일을 지정할 수 있으며, `scripts/reload-linux.sh --tag ... --launch`는 자동으로 `/tmp/cmux-linux-<tag>.state.json`을 사용합니다.

저장되는 값은 Linux-local 의미의 auth 상태, feed item/reply ledger, feedback submission ledger, remote workspace configuration/status, workspace/surface/pane session snapshot입니다. `session.restore_previous`는 이 snapshot을 현재 GTK window에 복원하지만, terminal process의 shell history나 remote daemon/SSH 연결 자체를 되살리지는 않습니다. Remote daemon 실행 파일 탐지, SSH bootstrap/probe, reverse-forward subprocess, local HMAC relay server 상태는 `workspace.remote.status`에 포함됩니다.

## macOS socket method parity 확인

macOS production method 목록과 Linux socket server의 선언 상태는 저장소 루트에서 다음 명령으로 비교할 수 있습니다.

```bash
python3 linux/tools/socket_method_parity.py
python3 linux/tools/socket_method_parity.py --json
python3 linux/tools/socket_method_parity.py --strict --json
```

`--strict`는 macOS production method가 Linux에 선언되지 않았거나, Linux의 unsupported method 선언이 socket method 목록에서 빠졌을 때 실패합니다. 현재 parity 범위와 남은 차이는 `docs/linux-core-parity-ledger.md`에 기록합니다.

실행 중인 tagged Linux 앱을 대상으로 socket smoke를 돌리려면 다음 명령을 사용합니다. `--browser`는 WebKitGTK browser pane까지 생성해서 고급 automation MVP를 확인하고, `--state`는 Linux runtime state 파일에 auth/feed/feedback/remote/session snapshot이 저장되는지 확인합니다.

```bash
CMUX_SOCKET_PATH=/tmp/cmux-linux-linux-core-parity.sock python3 linux/tools/socket_smoke.py --json
CMUX_SOCKET_PATH=/tmp/cmux-linux-linux-core-parity.sock python3 linux/tools/socket_smoke.py --browser --state --json
```
