# VNC Remote Desktop — Architecture

## Why agents need GUI access

Terminal-only access covers most coding workflows, but AI agents increasingly need to interact with graphical interfaces. Computer-use agents (Claude, GPT-4o with tools, Manus) need to click UI elements, fill web forms, verify rendered output, and test applications visually. Legacy enterprise apps often have no CLI — the GUI is the only interface. Running these tasks inside a sandboxed VM with VNC access gives agents a disposable visual workspace while keeping the host machine safe.

cmux's VNC panel brings this capability directly into the terminal multiplexer. An agent running in a terminal pane can programmatically screenshot an adjacent VNC pane (`cmux vnc screenshot`), analyze the visual output, and send mouse/keyboard input — all without leaving cmux. This eliminates the need for separate VNC clients, screen-sharing apps, or complex RDP setups.

The combination of terminal + VNC + scriptable API makes cmux a complete agent host: code in the terminal, interact with GUIs through VNC, orchestrate both via the socket API.

## System Overview

```mermaid
graph TB
    subgraph "cmux (macOS)"
        TP[Terminal Panes<br/>Ghostty/libghostty]
        VP[VNC Panel<br/>RoyalVNCKit]
        BP[Browser Panel<br/>WebKit]
        SA[Socket API<br/>Unix Domain Socket]
        CLI[cmux CLI]
    end

    subgraph "Remote Machine"
        TV[TigerVNC Server]
        DE[Desktop Env<br/>XFCE/LXDE]
        SSH[SSH Server]
    end

    subgraph "Agent"
        AI[AI Agent<br/>Claude/GPT/Codex]
    end

    subgraph "AVM Daemon (Rust)"
        REG[Registry]
        GOV[Governor]
        PRX[Egress Proxy]
        DET[Detector]
        SHL[Shell Guard]
    end

    AI -->|commands| CLI
    CLI -->|socket| SA
    SA --> TP
    SA --> VP
    SA --> BP
    VP <-->|RFB Protocol| TV
    TV --> DE
    TP <-->|SSH| SSH
    AI -->|monitored by| AVM
    AVM -->|policy| GOV
    AVM -->|filter| PRX
```

## VNC Data Flow

```mermaid
sequenceDiagram
    participant User as User/Agent
    participant cmux as cmux App
    participant VP as VNCPanel
    participant RVK as RoyalVNCKit
    participant FBV as VNCCAFramebufferView
    participant RC as RenderLayer (CALayer)
    participant TV as TigerVNC Server

    User->>cmux: cmux vnc open host:port
    cmux->>VP: create VNCPanel(host, port)
    VP->>RVK: VNCConnection.connect()
    RVK->>TV: TCP + RFB Handshake
    TV->>RVK: VncAuth challenge
    RVK->>VP: credentialFor(.vnc)
    VP->>RVK: VNCPasswordCredential
    RVK->>TV: Auth response
    TV->>RVK: Auth OK + Framebuffer init
    RVK->>VP: didCreateFramebuffer(fb)
    VP->>FBV: create VNCCAFramebufferView

    loop Every 33ms (30 FPS)
        TV->>RVK: Framebuffer update (Tight/ZRLE/Hextile)
        RVK->>FBV: didUpdateFramebuffer
        Note over RC: Timer fires
        RC->>FBV: framebuffer.cgImage
        RC->>RC: layer.contents = cgImage
    end

    User->>FBV: Mouse click / Key press
    FBV->>RVK: mouseButtonDown / keyDown
    RVK->>TV: RFB pointer/key event
```

## AVM Daemon Architecture

```mermaid
graph LR
    subgraph "AVM Daemon (Rust)"
        SRV[JSON-RPC Server<br/>Unix Socket]
        REG[Registry<br/>VM/Agent tracking]
        GOV[Governor<br/>Resource limits]
        DET[Detector<br/>Anomaly detection]
        PRX[Egress Proxy<br/>Network filtering]
        SHL[Shell Guard<br/>Command approval]
        POL[Policy Engine<br/>Rules + overrides]
    end

    Agent -->|register/heartbeat| SRV
    SRV --> REG
    REG --> GOV
    GOV --> POL
    Agent -->|command.check| SRV
    SRV --> SHL
    SHL --> POL
    Agent -->|network request| PRX
    PRX --> POL
    DET -->|monitors| REG
    DET -->|alerts| SRV

    style SRV fill:#4a9eff
    style POL fill:#ff6b6b
```

## Agent Interaction Model

```mermaid
sequenceDiagram
    participant Agent as AI Agent
    participant CLI as cmux CLI
    participant Sock as Socket API
    participant VNC as VNC Panel
    participant Term as Terminal Pane

    Note over Agent: Agent workflow: visual task

    Agent->>CLI: cmux vnc screenshot main
    CLI->>Sock: vnc.screenshot {surface: "main"}
    Sock->>VNC: captureScreenshot()
    VNC-->>Sock: PNG base64
    Sock-->>CLI: {image: "base64...", width, height}
    CLI-->>Agent: screenshot.png

    Agent->>Agent: Analyze screenshot (vision model)

    Agent->>CLI: cmux vnc click 450 320
    CLI->>Sock: vnc.input.mouse {x: 450, y: 320, button: "left"}
    Sock->>VNC: connection.mouseButtonDown(x, y)

    Agent->>CLI: cmux vnc type "hello world"
    CLI->>Sock: vnc.input.key {text: "hello world"}
    Sock->>VNC: connection.enqueueKeyEvent(...)

    Agent->>CLI: cmux vnc screenshot main
    Agent->>Agent: Verify action completed
```

## Component Files

| Component | File | Purpose |
|-----------|------|---------|
| VNC Panel Model | `Sources/Panels/VNCPanel.swift` | Connection lifecycle, auth, screenshot capture |
| VNC Panel View | `Sources/Panels/VNCPanelView.swift` | SwiftUI form + NSViewRepresentable framebuffer |
| Keychain Store | `Sources/Panels/VNCKeychainStore.swift` | Secure credential storage via macOS Keychain |
| SSH Reconnect | `Sources/SSHReconnectionController.swift` | Auto-reconnect with exponential backoff |
| Terminal Controller | `Sources/TerminalController.swift` | Programmatic terminal session management |
| AVM Server | `avm/src/server.rs` | JSON-RPC server for agent management |
| AVM Registry | `avm/src/registry.rs` | VM/agent registration and tracking |
| AVM Governor | `avm/src/governor.rs` | Resource limits and quota enforcement |
| AVM Proxy | `avm/src/proxy.rs` | Egress network filtering |
| AVM Shell Guard | `avm/src/shell.rs` | Dangerous command detection and approval |
| VNC Installer | `scripts/setup-vnc-server.sh` | One-line TigerVNC setup for remote hosts |
