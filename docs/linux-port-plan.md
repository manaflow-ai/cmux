# Linux Port Plan

Last updated: April 27, 2026
Status: Phase 2 Linux distribution skeleton ready for CI validation

이 문서는 cmux를 Linux로 포팅하기 위한 작업 경계와 실행 순서를 정리한다.
현재 저장소의 macOS 앱을 조건부 컴파일만으로 Linux에서 빌드하는 것은 목표가 아니다.
목표는 재사용 가능한 코어와 프로토콜을 분리하고, Linux용 앱 셸을 별도로 구현하는 것이다.

## 1. 결론

Linux 포팅은 가능하지만 앱 레이어는 대부분 재작성해야 한다.

현재 cmux 앱은 SwiftUI/AppKit, `NSWindow`/`NSView`, `WKWebView`, Metal,
IOSurface, Carbon, macOS 알림, Sparkle 업데이트, Keychain, AppleScript에 직접 의존한다.
이 의존성은 Linux에 대응되는 런타임이 없거나 API 모델이 크게 다르다.

반대로 다음 영역은 Linux 포팅의 기반으로 재사용할 수 있다.

1. `daemon/remote`의 Go 기반 `cmuxd-remote`
2. socket/JSON-RPC 명령 계약
3. 원격 SSH bootstrap, proxy, resize coordinator 설계
4. Ghostty 설정 파싱 일부
5. workstream/auth 모델 중 Foundation 수준으로 격리 가능한 데이터 모델
6. 웹사이트/문서/릴리스 문서 중 플랫폼 공통 설명

## 2. MVP 범위

Linux MVP는 macOS 버전의 모든 기능 복제가 아니라, cmux의 핵심 사용 흐름을 먼저 살린다.

### 2.1 포함

1. Linux 데스크톱 앱 창
2. 터미널 탭
3. 터미널 분할
4. workspace/session 목록
5. 로컬 PTY 실행
6. `cmux` CLI와 앱 socket 통신
7. `cmuxd-remote` 기반 SSH workspace 연결
8. Linux desktop notification
9. Ghostty config 호환의 최소 subset
10. 설정 파일 읽기/쓰기

### 2.2 제외

1. Sparkle auto-update
2. macOS Keychain 마이그레이션
3. AppleScript
4. AppKit debug windows
5. Dock tile badge
6. macOS window glass/sidebar material
7. WKWebView 기반 browser panel
8. Safari/Chrome profile import
9. WebAuthn browser integration
10. notarization/signing flow

브라우저 패널은 MVP 이후 WebKitGTK 또는 QtWebEngine 기반으로 별도 설계한다.

## 3. 현재 플랫폼 의존성

| 영역 | 현재 구현 | Linux 판단 |
|---|---|---|
| 앱 진입점 | `Sources/cmuxApp.swift`, SwiftUI `App`, AppKit delegate | 재작성 필요 |
| 창/포커스 | `NSWindow`, `NSApplication`, first responder | 재작성 필요 |
| 터미널 host | `NSViewRepresentable`, Metal, IOSurface, Carbon | 재작성 필요 |
| 브라우저 | `WKWebView`, AppKit view hierarchy | MVP 제외, 이후 재작성 |
| 알림 | macOS notification/AppKit | Linux notification portal/libnotify로 대체 |
| 업데이트 | Sparkle | MVP 제외, 이후 AppImage/Flatpak/deb/rpm 전략 |
| 보안 저장소 | Keychain/Security framework | Secret Service/libsecret 또는 파일 토큰으로 대체 |
| CLI | Swift + Darwin/POSIX 혼재 | command/path contract와 POSIX 조건부 처리 진행 중, Linux SwiftPM 빌드 경로 추가 |
| remote daemon | Go `cmuxd-remote` | 재사용 가능 |
| Workstream 모델 | 일부 `Darwin/Glibc` 조건부 존재 | 패키지 플랫폼 제한 제거 후보 |
| Auth 모델 | Apple 플랫폼 패키지 제한 | 토큰 저장소 분리 후 일부 재사용 후보 |

## 4. 권장 아키텍처

Linux 포트는 세 레이어로 나눈다.

### 4.1 Platform-neutral core

공유 코어는 UI 타입을 절대 노출하지 않는다.

책임:

1. workspace/session/tab/split 모델
2. socket protocol schema
3. command routing
4. config schema
5. keyboard shortcut schema
6. remote daemon bootstrap state model
7. notification event model

금지:

1. `NSWindow`, `NSView`, `NSEvent`
2. `WKWebView`
3. `UserDefaults`
4. `Bundle.main` 기반 앱 번들 탐색
5. AppKit/SwiftUI lifecycle

### 4.2 Platform adapters

각 OS별 구현을 adapter로 격리한다.

| 추상화 | macOS adapter | Linux adapter |
|---|---|---|
| Windowing | AppKit | GTK4/libadwaita 또는 Qt |
| Browser | WKWebView | WebKitGTK 또는 QtWebEngine |
| Notification | UserNotifications/AppKit | xdg desktop portal 또는 libnotify |
| Secret store | Keychain | Secret Service/libsecret |
| Settings path | macOS app support + XDG 일부 | XDG config/data/state |
| Terminal renderer | GhosttyKit/Metal | libghostty Linux path 또는 VTE fallback |
| Update | Sparkle | package manager/AppImage/Flatpak strategy |

### 4.3 Linux app shell

Linux 앱 셸은 별도 타깃으로 시작한다.

권장 후보:

1. GTK4/libadwaita
   - Linux 데스크톱과 가장 자연스럽다.
   - WebKitGTK, libadwaita, xdg portal과 잘 맞는다.
   - Ghostty/libghostty 통합 난이도는 별도 검증이 필요하다.
2. Qt 6
   - cross-platform widget/windowing이 강하다.
   - QtWebEngine 선택지가 있다.
   - GNOME 네이티브 감각은 GTK보다 약하다.
3. Tauri/Electron
   - 구현 속도는 빠르다.
   - 현재 프로젝트의 native/performance 방향성과 맞지 않아 기본 선택지로 두지 않는다.

초기 권장은 GTK4/libadwaita다.

## 5. Ghostty 전략

현재 macOS 앱은 `GhosttyKit.xcframework`와 Metal 렌더링 경로에 의존한다.
Linux에서는 xcframework를 사용할 수 없으므로 다음 중 하나를 선택해야 한다.
현재 checkout에서는 `ghostty` submodule이 초기화되지 않아 Linux artifact 검증은 대기 상태다.

### 5.1 Preferred: Linux libghostty embedding

목표:

1. Ghostty submodule에서 Linux용 library artifact를 빌드한다.
2. terminal surface 생성/입력/resize/render API를 C ABI로 호출한다.
3. GTK/Wayland/X11 렌더링 표면에 연결한다.

검증 항목:

1. Linux에서 headless 또는 GTK host 안에서 surface 생성 가능 여부
2. Wayland/X11별 renderer backend
3. IME, dead key, modifier, mouse reporting
4. font discovery/fontconfig 연동
5. GPU fallback과 software fallback

### 5.2 Fallback: VTE terminal MVP

libghostty Linux embedding이 막히면 MVP에서는 VTE를 사용한다.

장점:

1. GTK와 통합이 쉽다.
2. PTY/IME/selection/accessibility가 안정적이다.
3. Linux MVP를 빠르게 만들 수 있다.

단점:

1. Ghostty rendering/config 호환성이 제한된다.
2. macOS cmux와 terminal behavior가 달라질 수 있다.

이 경우 Linux MVP는 "cmux workspace/orchestration on Linux"로 정의하고,
Ghostty parity는 후속 milestone로 둔다.

## 6. 실행 계획

### Phase 0: Feasibility inventory

상태: 진행 시작

산출물:

1. 이 문서
2. 플랫폼 의존성 목록
3. 공유 가능/재작성 필요 모듈 분류
4. Linux UI toolkit 선택 근거
5. Ghostty embedding 검증 항목

완료 기준:

1. Linux MVP 범위가 명확하다.
2. 최소 프로토타입 기술 스택이 결정된다.
3. 재사용 가능한 코드 후보가 파일 단위로 식별된다.

### Phase 1: Core extraction

목표:

1. `CMUXCore` 또는 동등한 플랫폼 중립 모듈을 만든다.
2. workspace/session/config/socket schema를 UI에서 분리한다.
3. `CMUXWorkstream`의 Linux 빌드 제한을 검토한다.
4. CLI command schema를 Swift/AppKit 의존성 없이 표현한다.
5. CLI 기본 socket/config path를 `CMUXCore`의 XDG/macOS path policy로 통일한다.

완료 기준:

1. core 모듈이 Linux Swift 또는 Go/Rust 테스트 환경에서 빌드 가능하다.
2. AppKit/WebKit 타입이 core public API에 없다.
3. macOS 앱 동작이 유지된다.

### Phase 1 current extraction status

완료된 첫 절편:

1. `CMUXCore` SwiftPM package 추가
2. socket method/command/response/snapshot/path policy 타입 분리
3. CLI command registry와 browser command method alias 분리
4. macOS socket handler의 v1/v2 line routing을 `SocketCommandLine`으로 이동
5. app/CLI v2 method 문자열을 `SocketMethod` 기반으로 정리
6. `CMUXAuthCore`, `CMUXWorkstream`, `CMUXCore` Linux SwiftPM CI job 추가
7. CLI 기본 socket path를 `CMUXPathPolicy`에 연결하고 Linux XDG runtime path를 사용하도록 준비
8. CLI `Darwin`/`Glibc` 조건부 import, POSIX socket/file API, Linux polling wait fallback, `/proc/self/exe`, `/dev/urandom` fallback 정리
9. `CLI/Package.swift` 추가 및 CI에서 `swift build --package-path CLI` 실행하도록 구성
10. `linux/`에 GTK4/VTE Linux 실행기, Unix socket 서버, `.desktop` 파일, tarball 패키징 스크립트 추가
11. CI에 `linux-distribution-artifact` job을 추가해 Release CLI를 빌드하고 `cmux-linux-x86_64.tar.gz` artifact 생성/업로드 경로 구성

남은 첫 절편:

1. `swiftpm-linux-packages` CI 결과 확인 및 Linux-only compile failure 수정
2. Linux CI에서 `CLI/Package.swift` + Swift Crypto 해석 결과 확인
3. submodule 초기화 후 Ghostty Linux library artifact 가능성 확인

### Phase 2: Linux app skeleton

목표:

1. `linux/`에 GTK4/VTE 앱 골격을 만든다.
2. window, sidebar, terminal surface를 띄운다.
3. 설정 가능한 socket 경로는 XDG runtime 규칙을 따른다.
4. Linux notification adapter를 붙인다.

현재 상태:

1. `linux/bin/cmux-linux` 실행기 추가
2. `linux/lib/cmux_linux/app.py` GTK4/VTE 앱 추가
3. `linux/share/applications/com.cmuxterm.cmux.desktop` desktop entry 추가
4. `linux/package.sh` tarball 패키징 스크립트 추가
5. Release CLI를 포함한 `linux-distribution-artifact` CI job 추가

완료 기준:

1. Linux에서 앱 창이 뜬다.
2. workspace/tab 상태가 Linux socket 응답과 연결된다.
3. CI에서 `dist/cmux-linux-x86_64.tar.gz`가 생성된다.

### Phase 3: Terminal MVP

목표:

1. 로컬 PTY를 실행한다.
2. 탭별 terminal session을 유지한다.
3. resize, focus, copy/paste, keyboard input을 처리한다.
4. 가능하면 libghostty를 붙이고, 막히면 VTE fallback으로 진행한다.

완료 기준:

1. shell 실행 가능
2. 탭 전환 가능
3. split resize 가능
4. IME와 paste가 기본 동작

### Phase 4: CLI/socket integration

목표:

1. Linux 앱이 local socket server를 연다.
2. `cmux` CLI가 Linux 앱에 명령을 보낸다.
3. v1/v2 command compatibility를 유지한다.

완료 기준:

1. `cmux ping`
2. `cmux list-workspaces --json`
3. `cmux new-workspace`
4. `cmux rpc system.capabilities`

### Phase 5: Remote workspace integration

목표:

1. `cmuxd-remote`를 Linux 앱에서 재사용한다.
2. SSH bootstrap/reconnect/proxy/session resize flow를 연결한다.
3. 기존 remote daemon contract를 유지한다.

완료 기준:

1. remote shell workspace 생성
2. reconnect
3. proxy status surfacing
4. smallest-screen-wins resize semantics 유지

### Phase 6: Browser and packaging

목표:

1. WebKitGTK 또는 QtWebEngine browser panel을 붙인다.
2. remote workspace proxy auto-wiring을 구현한다.
3. AppImage/Flatpak/deb/rpm 중 배포 경로를 결정한다.

완료 기준:

1. local/remote browser panel 동작
2. remote browser egress가 remote network path를 따른다.
3. Linux release artifact가 CI에서 생성된다.

## 7. Core extraction candidates

초기 추출은 UI에서 멀리 떨어진 데이터 모델과 프로토콜부터 시작한다.

| 후보 | 현재 상태 | 판단 |
|---|---|---|
| `Packages/CMUXWorkstream` | `Darwin/Glibc` 조건부가 있고 UI 의존이 낮음. Apple 플랫폼 선언 제거 완료 | CI/VM에서 Linux SwiftPM 빌드 검증 필요 |
| `Packages/CMUXAuthCore` | Foundation-only auth state/store 모델, Apple 플랫폼 선언 제거 완료 | CI/VM에서 Linux SwiftPM 빌드 검증 필요 |
| `Sources/CmuxConfig.swift` | `Foundation` 중심이나 `Bonsplit`, `Combine`, workspace publisher 의존 포함 | schema 타입부터 분리 |
| `Sources/SessionPersistence.swift` | snapshot 정책과 Codable 모델 포함, `CoreGraphics`/`Bonsplit` 의존 있음 | geometry 타입 대체 후 후보 |
| `Sources/SocketControlSettings.swift` | socket path/mode 정책 포함, `Darwin`/`Security` 의존 있음 | path policy와 password store 분리 필요 |
| `CLI/cmux.swift` | command schema와 socket client가 한 파일에 혼재, `Darwin` 사용 | command schema를 먼저 분리 |
| `Sources/Workspace.swift` | model처럼 보이나 AppKit/SwiftUI/Network/CoreText와 결합 | 직접 추출보다 새 core 모델 작성 |
| `Sources/TabManager.swift` | AppKit/SwiftUI/CoreVideo와 lifecycle 결합 | 직접 추출보다 adapter 뒤로 이동 |
| `Sources/TerminalController.swift` | socket command 처리와 AppKit/WebKit 조작 혼재 | protocol handler와 UI executor 분리 필요 |
| `Sources/TerminalNotificationStore.swift` | notification domain과 macOS delivery가 혼재 | event model과 delivery adapter 분리 |

### 7.1 First extraction slice

첫 번째 실제 코드 변경은 작고 검증 가능한 단위로 제한한다.

1. `CMUXCore` 패키지 생성: 완료
2. `SocketMethod` command identifier 타입 추가: 완료
3. `SocketCommand` request envelope 타입 추가: 완료
4. `JSONValue` arbitrary JSON payload 타입 추가: 완료
5. `SocketResponse` success/error envelope 타입 추가: 완료
6. workspace/session snapshot DTO 추가: 완료
7. XDG/macOS path policy를 주입 가능한 pure function으로 추가: 완료
8. `CMUXWorkstream` 패키지의 Apple 플랫폼 선언 제거: 완료
9. macOS 앱은 기존 구현을 유지하고 새 core 타입을 read-only로 참조: 완료
10. CLI Xcode target을 `CMUXCore`에 연결하고 직접 `sendV2(method: "...")`로 보내던 v2 method를 `SocketMethod`로 참조: 완료
11. CLI command registry를 `CMUXCore`의 platform-neutral descriptor로 분리하고 CLI 진입점에서 canonical command lookup 사용: 완료
12. socket v2 method registry와 focus-intent metadata를 `CMUXCore`로 분리하고 `system.capabilities` 응답에서 재사용: 완료
13. socket line의 v1/v2 protocol routing classifier를 `CMUXCore`로 분리하고 macOS handler에서 재사용: 완료
14. Linux SwiftPM CI job을 추가해 `CMUXCore`, `CMUXAuthCore`, `CMUXWorkstream`을 Swift 공식 Linux 컨테이너에서 검증하도록 구성: 완료
15. CLI POSIX compatibility slice를 시작해 Linux용 `Glibc`, socket polling fallback, executable path, random source, CryptoKit/Swift Crypto 조건부 경계를 추가: 완료
16. `CLI/Package.swift`를 추가하고 CI에서 Linux CLI 컴파일을 시도하도록 구성: 완료

이 단계에서는 Linux UI를 만들지 않는다. 먼저 공유 contract를 안정화한다.

현재 추가된 `CMUXCore`와 platform declaration을 제거한 `CMUXAuthCore`/`CMUXWorkstream`은 SwiftPM이 지원하는 Linux 환경에서 빌드 가능한 구조를 목표로 한다.
`SocketMethod`, `SocketCommand`, `SocketResponse`, `JSONValue`는 기존 v2 socket wire shape를 플랫폼 중립 contract로 고정하기 위한 시작점이다.
macOS app target과 CLI target은 `CMUXCore`를 read-only contract로 참조하기 시작했다. CLI의 정적 v2 socket method 호출은 `SocketMethod` 상수를 사용하도록 정리했다. 동적 browser action method map은 `BrowserCommandMethod` registry로 `CMUXCore`에 분리했다. CLI top-level command registry도 `CLICommandRegistry`로 분리해 local/default socket route metadata와 canonical command lookup을 `CMUXCore`에서 제공한다. socket v2 method 목록, debug method 목록, focus-intent metadata, line-level v1/v2 protocol classifier도 `CMUXCore`로 이동해 Linux socket server가 같은 contract를 재사용할 수 있게 했다. `ci.yml`의 `swiftpm-linux-packages` job은 이 세 패키지와 CLI SwiftPM package를 Linux SwiftPM으로 검증하는 첫 CI 경로다.

### 7.2 Remaining first-slice work

다음 변경은 아래 순서로 진행한다.

1. `swiftpm-linux-packages` CI job 결과를 확인하고 Linux-only 컴파일 오류를 수정한다
2. Linux CLI package의 Swift Crypto 의존성 해석과 Glibc compile errors를 CI에서 확인한다
3. Ghostty Linux artifact 가능성을 submodule 초기화 환경에서 확인한다

## 8. 테스트 전략

프로젝트 정책상 로컬에서 E2E/UI 테스트를 직접 실행하지 않는다.
Linux 포팅 검증은 CI 또는 VM에서 수행한다.

초기 테스트는 다음 순서로 만든다.

1. core model unit tests
2. config path tests using XDG temp dirs
3. socket protocol compatibility tests
4. remote daemon contract tests
5. Linux app smoke test in VM
6. terminal input/resize integration tests
7. browser proxy integration tests

회귀 테스트를 추가할 때는 기존 정책에 따라 테스트 전용 커밋과 수정 커밋을 분리한다.

## 9. 위험 요소

| 위험 | 영향 | 완화 |
|---|---|---|
| libghostty Linux embedding 불확실 | Terminal MVP 지연 | VTE fallback으로 MVP를 유지 |
| SwiftUI/AppKit 상태 모델 누수 | core 추출 지연 | public API에 UI 타입 금지 |
| CLI가 Darwin에 묶임 | Linux CLI 빌드 실패 | SwiftPM CLI 빌드 경로에서 Darwin/Glibc 조건부 컴파일 오류를 CI로 조기 검출 |
| Browser parity | remote browser 기능 지연 | MVP 제외 후 WebKitGTK로 별도 milestone |
| 알림/포커스 정책 차이 | UX 불일치 | Linux desktop portal 규칙을 adapter에 격리 |
| packaging 다양성 | 배포 지연 | 초기에는 AppImage 또는 Flatpak 하나만 선택 |

## 10. 다음 작업

1. CI에서 `swiftpm-linux-packages`와 `linux-distribution-artifact` 결과를 확인하고 Linux-only 오류를 수정한다.
2. 실제 Ubuntu VM에서 `cmux-linux-x86_64.tar.gz`를 풀어 GTK4/VTE 런타임 의존성과 socket 응답을 확인한다.
3. Ghostty submodule을 초기화한 환경에서 Linux libghostty artifact 가능성을 검증한다.
4. VTE MVP의 split UI, session persistence, remote workspace 연결을 단계적으로 확장한다.
