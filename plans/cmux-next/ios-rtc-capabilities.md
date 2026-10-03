# cmux iOS: capability inventory for a from-scratch rewrite

Source: `origin/main` @ `d6005a3ec81d857744bcb586984195df997b5d10` (2026-10-02 20:59 -0700), extracted read-only with `git archive` to `/tmp/iosrtc/src`. Every path below is the path on origin/main.

Path shorthands:
- `SUI/` = `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/`
- `SH/` = `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/`
- `SM/` = `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/`
- `TERM/` = `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/`
- `TKIT/` = `Packages/iOS/CmuxMobileTerminalKit/Sources/CmuxMobileTerminalKit/`
- `CORE/` = `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/`
- `FEAT/` = `ios/cmuxPackage/Sources/cmuxFeature/`
- `WS/` = `Packages/iOS/CmuxMobileWorkspace/Sources/CmuxMobileWorkspace/`

Method: five parallel source-reading passes, one per package group, plus my own reads of the app target, extensions, plists, entitlements, xcconfigs, the App Store metadata, the CHANGELOG and the review notes. Conflicting claims were re-checked in source; the corrections are noted inline.

Gating convention: most Mac features are gated on capability strings the Mac returns in `mobile.host.status` `capabilities[]` (collected in `SH/MobileShellComposite.swift` lines ~117-156 and `SH/MobileShellComposite+Capabilities.swift`). These are shown as `[cap: x.v1]`. When a capability is missing, the UI shows an "Update cmux on your Mac" hint (`SH/MobileMacUpdateHint.swift`, `SUI/MacUpdateHintIndicatorButton.swift`).

## Confirmed absent on origin/main

Grep over all of `ios/` and `Packages/` found none of the following:
- **Voice mode** (OpenAI realtime, tools). PR 13504 is not merged. The only voice feature is on-device dictation (§5.7).
- **Local Linux (iSH / Alpine).** The only hits are comments crediting iSH's keyboard technique in `TERM/TerminalInputTextView.swift`.
- **Welcome Tour.** The 5-stage onboarding (§15) fills that role.
- **Agent-chat GUI.** `mobile.chat.send/interrupt/answer/history/session(s)` exist in `SH/MobileChatEventSource.swift` but have no UI caller other than the DEBUG release gate. `CmuxAgentChatUI` is used only as the artifact viewer and markdown renderer.
- **System integrations:** App Intents/Siri/Shortcuts, widgets, Live Activities, Handoff/`NSUserActivity`, `BGTaskScheduler`, universal links (no associated-domains entitlement), and a share extension.
- **Terminal features:** in-terminal find, in-grid text selection, and kitty/sixel image rendering.
- **App-level hardware-keyboard shortcuts** outside the terminal key map.
- **Toasts in shipping builds.** `Packages/iOS/CmuxMobileToast/.../ToastCenter.swift:64` sets `shippedEnabled = false`, so toasts are DEBUG-only.

## App shell facts

- **Extensions:** `ios/NotificationService` (NSE, 142 lines) and `ios/CloudVPN` (packet tunnel, 95 lines).
- **Background mode:** `remote-notification` only.
- **Multiple scenes:** `UIApplicationSupportsMultipleScenes = true`, single `WindowGroup`.
- **Orientations:** iPhone supports portrait and both landscapes. iPad adds upside-down.
- **Bonjour:** `_cmux-iroh._udp`.
- **Permission strings:** Camera (pairing QR), Local Network, Microphone and Speech (dictation), Photo Library (attachments). All in `ios/Config/Info.plist`.
- **Entitlements:**
  - Sign in with Apple, `aps-environment`, time-sensitive notifications, packet-tunnel-provider, and a Keychain group. Files: `ios/Config/cmux.entitlements`, `cmux-release.entitlements`.
  - App group `group.dev.cmux.ios` appears in `cmux.entitlements` and `NotificationService.entitlements`. It is **absent from `cmux-release.entitlements`**. Check whether a rewrite must add it.
- **URL scheme:** `CMUX_IOS_URL_SCHEME = cmux-ios-$(PRODUCT_BUNDLE_IDENTIFIER)`, set in `ios/Config/Shared.xcconfig`.
- **Bundle identifiers:**
  - Debug: `dev.cmux.ios`.
  - Release: `dev.cmux.app.beta`, display name "cmux BETA".
  - Other build types: `.internal` and `.demo`; prod is `com.cmux.app` (see `SM/MobileBuildType.swift`).
- **App Store copy** (`ios/fastlane/metadata/en-US/description.txt`): live terminal, agent push, reply on the go, voice to text, and secure pairing. Store listings exist in 14 locales.

---

## 1. Account and authentication

1. **Sign in with Apple, Google, or GitHub.** Uses the browser OAuth flow (`ASWebAuthenticationSession`) through Stack Auth.
   - Files: `SUI/SignInView.swift`, `SUI/OAuthSignInProvider.swift`, `Packages/Shared/CmuxAuthRuntime/.../BrowserSignIn/*`, `.../Coordinator/AuthCoordinator.swift`.
   - Backend: Stack Auth SDK (`vendor/stack-auth-swift-sdk-prerelease`, `api.stack-auth.com`).
2. **Sign in with an email one-time code.** Flow: "Email me a code", then a 6-character code (normalized to uppercase, auto-submitted when complete), then "Use a different email".
   - Files: `SUI/SignInView.swift`, `WS/SignInCodeInputPolicy.swift`, `SUI/SignInEmailCodeFailurePolicy.swift`.
   - Backend: Stack magic-link/OTP.
3. **Email-verification gate.** Screens: "Verify your email", resend, "I verified my email".
   - Files: `SUI/SignInView.swift`, `CmuxAuthRuntime/.../AuthCoordinator+EmailVerificationRecovery.swift`, `EmailVerificationRecoveryClient.swift`.
   - Backend: `POST /api/auth/email-verification`.
4. **"Already paid? Recover your account"** (billing recovery from the sign-in screen).
   - Files: `SUI/SignInBillingRecoveryActions.swift`.
   - Backend: `POST /api/billing/recover`.
5. **Session restore at launch.** Shows a status view with Retry. The token store treats unreadable storage as transient.
   - Files: `SUI/SignInAuthRestoreStatusView.swift`, `SUI/RestoringSessionView.swift`, `CmuxAuthRuntime/.../TokenStores/*`.
6. **Attach-ticket authentication without a Stack session.** A pairing deep link grants temporary auth. Files: `WS/MobileRootAuthGate.swift` (`attachTicketAuthenticated`, `shouldClearAttachTicketAuthentication`).
7. **Sign out.** Local-first and works offline. It also:
   - unregisters the push token;
   - clears the push account pin;
   - tears down Iroh;
   - clears the debug log;
   - resets the analytics identity;
   - drops the sync cache;
   - stops browser tunnels;
   - disables demo content.

   Files: `SH/MobileShellComposite.swift` `signOut()`, `ios/cmux/AppCompositionRoot.swift`, `SUI/MobileSignOutHook.swift`, `CmuxAuthRuntime/.../HostBrowserSignOutCoordinator.swift`. Backend: `DELETE /api/device-tokens`.
8. **Delete account.** Asks for confirmation and handles a cleanup that does not complete.
   - Files: `SUI/MobileSettingsAccountSection.swift`, `SUI/MobileSettingsDeleteAccountFailureKind.swift`, `CmuxAuthRuntime/.../AccountDeletionClient.swift`.
   - Backend: `/api/account` (DELETE).
9. **Team switcher.** Appears only when the user has more than one team. Switching re-scopes computers and presence and keeps the live terminal session.
   - Files: `SUI/MobileSettingsView.swift` (Team section), `SH/MobileShellComposite.swift` `currentTeamDidChange()`, `CmuxAuthRuntime/.../AuthCoordinator+TeamSelection.swift`.
10. **Account-mismatch recovery.** A banner offers "Sign Out & Switch Account". The setup state machine distinguishes not signed in, never paired, Mac unreachable, and mismatch.
    - Files: `SUI/MobileConnectionRecoveryBanner.swift`, `WS/MobileSetupGuidancePolicy.swift`, `WS/MobileSetupGuidanceState.swift`, `SH/MobilePairingAccountPreflight.swift`.
11. **Erase All Data on This Device.** Wipes the Keychain, UserDefaults and container. A marker re-runs the wipe on next launch. The server is never contacted.
    - Files: `SUI/MobileSettingsResetSection.swift`, `SUI/MobileLocalDataResetView.swift`, `SH/MobileLocalDataEraser.swift`, `ios/cmux/cmuxApp.swift`.
12. **App Review demonstration content.** When the server account flag `demonstrationContentEnabled` is set (`cmuxReviewDemoContent` in Stack metadata), the app adds a local "Demo Mac" with sample workspaces, notifications and interactive canned terminals.
    - Files: `SH/MobileShellComposite+DemoContent.swift`, `SH/MobileDemoContentSession.swift`, `SH/DemoContentPairedMacStore.swift`, `SM/MobileDemoContentCatalog.swift`, `SM/MobileDemoTerminalEngine.swift`, `ios/AppStoreReview/review-notes.md`.

## 2. Computers, discovery, pairing, and connection

1. **Zero-touch discovery of Macs on the same account.** Uses the V2 directory and dials candidates in parallel. A Mac is saved only after it authenticates.
   - Files: `SH/MobileShellComposite+ZeroTouchIroh.swift`, `SH/ZeroTouchDialRace.swift`, `FEAT/MobileIrxDiscoveryProvider.swift`, `FEAT/MobileIrxRuntimeComposition+Directory.swift`.
   - Backend: V2 control plane `directory.request.v1`. RPC: `mobile.host.status`.
2. **LAN advertisement** via `_cmux-iroh._udp`. Files: `Packages/Shared/CmuxIrohTransport/.../CmxIrohLANAdvertisement.swift`.
3. **Scan a pairing QR code.** Covers camera permission, an Open Settings link, and an "Enter Manually" fallback.
   - Files: `SUI/MobilePairingScannerSheet.swift`, `SUI/QRCodeScannerView.swift`, `Packages/iOS/CmuxMobileCamera/*`, `WS/MobilePairingScannerPolicy.swift`.
4. **Open a pairing or attach URL from another app** (`<scheme>://attach?...`). The URL is deferred until sign-in finishes. Files: `SUI/CMUXMobileRootView.swift:464` (`onOpenURL`), `CORE/CmxPairingURLScheme.swift`, `CORE/CmxPairingQRCode.swift`.
5. **Pairing version-mismatch warning** with "Continue anyway". Files: `SH/MobileShellComposite.swift` `acceptPairingVersionWarning`, `SUI/PairingView.swift`.
6. **Add Computer manually.** Enter a host or Tailscale IP and a port (default 58465). The form shows "Signed in as". The app then mints a one-hour Mac-scoped ticket.
   - Files: `SUI/PairingView.swift`, `SUI/PairingPresentation.swift`, `SH/MobileShellComposite+ManualAttachTicket.swift`.
   - RPC: `mobile.attach_ticket.create`.
7. **Team device registry**, sorted connected first, then by last seen. Files: `SH/DeviceRegistryService.swift`, `SH/MobileShellComposite+ConnectionRecovery.swift`. Backend: `GET /api/devices`.
8. **Live online/presence dots.** Files: `SH/PresenceClient.swift`, `SH/MobileShellComposite+PresenceRouteSync.swift`. Backend: WebSocket `{presence}/v1/presence/subscribe`.
9. **Computers screen (device tree).** Lists paired Macs (status: Connected, Online, Reconnecting, Last seen, Mac update required, Keeping awake), Cloud machines, SSH computers and hidden computers. Duplicate rows for one Mac coalesce, with build-channel labels.
   - Files: `SUI/DeviceTreeView.swift`, `SUI/MacComputerRow.swift`, `SUI/MacComputerListSection.swift`, `SUI/CloudComputerRow.swift`, `SUI/HiddenComputerRow.swift`, `SUI/SSHComputersSection.swift`, `SH/MobileShellComposite+PairedMacCoalescing.swift`, `SH/PairedMacAliasUnionFind.swift`.
10. **Show or hide a computer on this iPhone.** Local to the device and per app instance. Files: `SUI/ComputerVisibilityToggle.swift`, `SH/MobileShellComposite+HiddenMacs.swift`, `SH/UserDefaultsPairedMacHiddenStore.swift`.
11. **Forget a computer.** Revokes it from every device on the account. It reappears if it is still online.
    - Files: `SUI/MacComputerDetailView.swift`, `SH/MobileIrohMacForgetting.swift`, `FEAT/MobileIrxDiscoveryProvider.swift:148`.
    - Backend: V2 `device.revoke.v1` via `revokeBinding` in `FEAT/MobileIrxRuntimeComposition+Directory.swift:104`. Corrected in source; this does not use the legacy `/api/devices/iroh`.
12. **Customize a computer** (name, emoji/icon, color). Synced to a per-user backup when that flag is on.
    - Files: `SUI/MacComputerDetailView.swift`, `SH/MobileShellComposite.swift` `updateMacCustomization`, `SM/MachineAvatarPalette.swift`.
13. **Computer detail.** Shows the active role (and lets you switch the foreground Mac), device ID, paired-since date, workspace count and build badge. File: `SUI/MacComputerDetailView.swift`.
14. **Connection method per computer.**
    - Options: Iroh (Auto), Tailscale Only, or Direct with editable `ip:port` candidates (add, edit, enable, disable). Private addresses can carry labels.
    - Routes can be removed; the Iroh route cannot. A change redials immediately.
    - Files: `SH/MobileShellComposite+ConnectionMethod.swift`, `SM/MobileConnectionMethodStore.swift`, `SH/MobileShellComposite+RouteRemoval.swift`, `SH/MobileShellComposite+ReconnectRoutes.swift`, `SUI/MobileIrohCustomPrivatePathEditor.swift`.
15. **Route reachability ping** (TCP probe). File: `SH/MobileShellComposite.swift` `pingRoute`.
16. **Auto-reconnect.** Triggers on launch, foreground, network change, presence change and stream failure. A single recovery owner runs with capped backoff, and manual Retry/Reconnect is available.
    - Files: `SH/MobileShellComposite+ConnectionRecovery.swift`, `+WorkspaceListRecovery.swift`, `+StoredMacDial.swift`, `SH/MobileAutomaticReconnectBackoffOwner.swift`, `SUI/MobileStartupConnectionCoordinator.swift`, `ios/cmux/cmuxApp.swift` (network to Iroh).
    - RPC: `mobile.events.probe`.
17. **Several Macs at once.** One aggregated workspace list fed by a foreground connection plus secondary subscriptions to the other Macs. Opening a workspace switches the foreground Mac.
    - Files: `SH/MultiMacAggregationFlag.swift`, `SH/MobileMacConnectionRegistry*.swift`, `SH/Secondary*.swift`, `SH/MobileShellComposite+SecondaryPromotion.swift`.
18. **Connection and offline indicators.** Per-Mac status rows with Retry; a "Still loading" timeout; a cached last-known workspace snapshot so the list renders offline.
    - Files: `SUI/MobileMacConnectionStatusRow.swift`, `SUI/WorkspaceListConnectionChrome.swift`, `SM/MobileMacConnectionStatus.swift`, `SH/MobileWorkspaceSnapshotStore.swift`.
19. **Disconnected shell ("Your Computers").** Tap to reconnect, toggle per-computer visibility, Add Computer, Scan Pairing Code, "Trouble connecting?", and a hint to use the Cloud tab when no Mac is paired. File: `SUI/DisconnectedWorkspaceShellView.swift`.
20. **Mac minimum-version gate.**
    - Tiers are baked into the app and can be replaced remotely; an empty list acts as a kill switch.
    - Rejected Macs show "Requires %@ on your Mac". Onboarding names the minimum version.
    - Files: `SH/MobileMacCompatPolicy*.swift`, `SH/MobileShellComposite+BuildCompatibility.swift`, `SUI/MobileMacCompatCenter.swift`, `SH/MobileMacCompatRemoteList.swift`.
    - Backend: `GET /api/mobile-mac-compat`.
21. **"Mac update adds features" hint.** Lists which features updating the Mac would unlock and can be dismissed for good. Files: `SH/MobileMacUpdateHint.swift`, `SH/MobileMacUpdateFeature.swift`, `SH/MobileMacUpdateHintDismissalStore.swift`, `SUI/MacUpdateHintIndicatorButton.swift`.
22. **Build and channel isolation.** A build pairs only with its own Mac tag plus any tags granted live.
    - Files: `SH/MobileMacTagAllowlist.swift`, `SH/MobileShellComposite+CompatibleMacTags.swift`, `SH/MobileMacBuildCompatibilityPolicy.swift`.
    - Event: `mobile.compatible_tags.changed`.
23. **Auto-Connect (Iroh) migration sheet.** Choices: "Use Auto-Connect" or "Set Up Tailscale". Files: `SUI/MobileAutoConnectMigration*.swift`, `SM/MobileAutoConnectMigrationStore.swift`.
24. **Set Up Computer help and Tailscale detection.** Explains how connection works, marks "You are here", links to Tailscale, and shows a setup prompt when Tailscale is off. Files: `SUI/SetupHelpView.swift`, `SUI/SetupHelpGateContent.swift`, `SUI/TailscaleStatus*.swift`, `SUI/MobileTailscaleSetupPromptState.swift`, `SUI/MobilePairingCopy.swift`.
25. **Paired-Mac list on its own SQLite store**, scoped to user and team, with a one-time import of legacy data. Files: `Packages/iOS/CmuxMobilePairedMac/Sources/CmuxMobilePairedMac/*`.
26. **Paired-Mac backup and restore across devices.** Flagged (see the flags section). Files: `SH/PairedMacBackupClient.swift`, `SH/BackingUpPairedMacStore*.swift`. Backend: `GET/POST {presence}/v1/sync/paired-macs`.

## 3. Workspaces

1. **Aggregated workspace list.** A title menu offers All Computers, a single computer, or Add Computer, and the choice persists. Files: `SUI/WorkspaceMacTitlePickerMenuButton.swift`, `SUI/WorkspaceListView+MacSelection.swift`, `SM/MobileWorkspaceAggregation.swift`. RPCs: `workspace.list`, `mobile.workspace.list`, `mobile.sync.fetch`; events `workspace.updated`, `mobile.sync.delta`.
2. **View options.**
   - Show All or Unread; multi-select machine filter.
   - Sort computers by Last Opened, Custom Order, or Recent Activity, with an "Edit Computer Order" drag sheet.
   - Files: `SUI/WorkspaceListViewOptionsPopover.swift`, `SUI/WorkspaceListFilterControls.swift`, `SUI/WorkspaceComputerOrderSheet.swift`, `SM/MobileWorkspaceSortMode.swift`, `SM/MobileWorkspaceListFilter.swift`, `SM/MobileWorkspaceReadStateFilter.swift`.
3. **Search workspaces** (tab-scoped search). Files: `SUI/MobilePrimarySearchCoordinator.swift`, `SUI/WorkspaceListSearchHost.swift`.
4. **Pull to refresh.** File: `SUI/View+WorkspaceListRefreshable.swift`.
5. **Row content.**
   - Title (wrap optional), description, and a 1-2 line live preview.
   - Unread dot, pinned marker and timestamp.
   - Changes chip (+/−), Mac avatar, and agent icons (Claude, Codex, OpenCode).
   - Files: `SUI/WorkspaceRow.swift`, `SUI/WorkspaceListRowModel.swift`, `SUI/WorkspaceChangesChipLabel.swift`, `SUI/Resources/AgentIcons/`.
6. **New workspace.** Per computer, inside a group, or (for SSH) cmux-tui, tmux or shell.
   - Optional fields: title, cwd, command, env, `operation_id`.
   - Files: `SUI/WorkspaceListNewWorkspaceMenu*.swift`, `SH/MobileShellComposite+WorkspaceCreateRequest.swift`, `SH/MobileWorkspaceCreateSpec.swift`.
   - RPC: `workspace.create` `[cap: workspace.create_in_group.v1]`.
7. **Rename, pin/unpin, set/clear description (4 KB cap with a conflict guard), set/clear color, mark read/unread.** Available from the context menu, swipe actions, Customize sheet, and title menu.
   - Files: `SUI/WorkspaceNavigationRow.swift`, `SUI/WorkspaceListTableCoordinator+Actions.swift`, `SUI/WorkspaceCustomizationSheet.swift`, `SUI/WorkspaceCustomizationDraft.swift`, `SUI/WorkspaceRenameSheet.swift`, `SUI/WorkspaceTitleMenuContent.swift`, `SH/MobileShellComposite+WorkspaceActions.swift`.
   - RPC: `workspace.action` `[cap: workspace.actions.v1, .metadata.v1, .read_state.v1]`.
8. **Close a workspace** (with confirmation). Files: `SUI/CloseWorkspaceConfirmation.swift`, `SH/MobileWorkspaceCloseConfirmation.swift`. RPC: `workspace.close` `[cap: workspace.close.v1]`.
9. **Drag to reorder and move between groups**, plus Move to Group and Remove from Group. Files: `SUI/WorkspaceListView+DragDrop.swift`, `SUI/WorkspaceListDropProposalPolicy.swift`, `SM/MobileWorkspaceMovePolicy.swift`. RPC: `workspace.move` `[cap: workspace.move.v1]`.
10. **Workspace groups.**
    - Create a group; pin/unpin, rename, "Ungroup (keep workspaces)", or "Delete group (close workspaces)".
    - Collapse and expand are local only.
    - Files: `SUI/WorkspaceGroupHeaderRow.swift`, `SUI/WorkspaceGroupRenameDialog.swift`, `SM/MobileWorkspaceGroupCollapseStore.swift`.
    - RPCs: `workspace.group.create` `[cap: workspace.group_create.v1]`, `workspace.group.action` `[cap: workspace.group_actions.v1]`.
11. **Each workspace reopens on its last tab** (terminal, Mac surface, browser stream, simulator stream, or local browser). File: `SM/MobileWorkspaceLastTabStore.swift`.
12. **Back button showing the unread-workspace count.** File: `SUI/WorkspaceBackButton.swift`.
13. **Workspace presence.** Announces which workspace you are viewing to other devices. Files: `SH/MobileShellComposite+WorkspacePresence.swift`, `SH/MobileWorkspacePresenceAnnouncer.swift`, `Packages/Shared/CmuxWorkspacePresence`. Backend: WebSocket `{presence}/v1/workspace-presence`.
14. **Native rendering of Mac surfaces.**
    - Checklist (todo): add, edit, set state, reorder, delete, open on the Mac. Workspace status: Automatic, None, or chosen.
    - Markdown and file panels.
    - A fallback card with "Open on Mac" and Retry for anything else.
    - Files: `SUI/TodoSurfaceView.swift`, `SUI/TodoSurfaceRowView.swift`, `SUI/TodoStatusMenu.swift`, `SUI/MarkdownSurfaceView.swift`, `SUI/PanelFileSurfaceView.swift`, `SUI/SurfaceFallbackCardView.swift`, `SM/MacSurfaceRenderer.swift`, `SH/MobileShellComposite+Todo.swift`, `Packages/iOS/CmuxMobileRPC/.../MobileCoreRPCClient+Todo.swift`.
    - RPCs: `mobile.todo.add/set_state/edit/move/remove/open`, `mobile.status.set/cycle` `[cap: todo.v1]`, `mobile.panel.artifact.stat/fetch/thumbnail` `[cap: panel.artifact.v1]`.
15. **Focus a surface on the Mac.** Picking a terminal also focuses it there. File: `SH/MobileShellComposite+SurfaceFocus.swift`. RPC: `mobile.surface.focus` `[cap: surface.focus.v1]`.
16. **Workspace title menu.** Reconnect, Browse Files (SSH), Connected Devices, Customize, Rename, Mark Read/Unread, Close. File: `SUI/WorkspaceTitleMenuContent.swift`.
17. **Terminal/surface picker.**
    - Lists terminals, Mac Surfaces, Mac Simulators and Mac Browsers.
    - Actions: New Workspace, New Terminal, New Browser, View as Text, Send Feedback.
    - For SSH: Split Right/Down (tmux) and New Tab (cmux-tui).
    - Files: `SUI/TerminalPickerMenuContent.swift`, `SUI/TerminalPickerMenuActions.swift`, `SUI/WorkspaceDetailView.swift`.
    - RPCs: `terminal.create`/`mobile.terminal.create`, `mobile.browser.create`.
18. **iPad / regular width.** `NavigationSplitView` with the list in the sidebar and a "No Workspace" placeholder; the sidebar can be toggled. Files: `SUI/WorkspaceShellView.swift`, `SUI/WorkspaceDetailContainer.swift`, `SUI/WorkspaceDetailView+OwnedTopBar.swift`.

## 4. Terminal: output, rendering, sizing

1. **Live mirror of a Mac terminal.**
   - The phone runs its own libghostty and receives render-grid replays (verified, screen-anchored) or raw PTY bytes. Transport modes are hybrid, renderGrid and rawBytes.
   - Files: `TERM/GhosttySurfaceView.swift`, `TERM/GhosttyRuntime.swift`, `SUI/GhosttySurfaceRepresentable.swift`, `SH/MobileShellComposite+TerminalOutputDelivery*.swift`, `+TerminalReplay*.swift`, `+TerminalLane.swift`, `SH/TerminalOutputTransportSelection.swift`.
   - RPCs: `mobile.terminal.replay`/`terminal.replay`. Events: `terminal.render_grid`, `terminal.bytes`. Lane: irx `terminal`.
   - Caps: `terminal.render_grid.v1`, `.screen_anchor.v1`, `.verified_replay.v1`, `terminal.bytes.v1`, `terminal.replay.v1`.
2. **Theme follows the Mac.** Host theme, per-surface themes and live OSC palette changes apply, including the chrome. Monokai is the fallback. There is no in-app theme or font picker.
   - Files: `SH/MobileShellComposite+TerminalTheme.swift`, `CORE/TerminalTheme.swift`, `TERM/GhosttySurfaceView+ThemeOutput.swift`, `SUI/TerminalThemeApplicationScheduler.swift`.
3. **Fixed terminal defaults:** Menlo font, blinking bar cursor, scroll to bottom on keystroke. File: `TERM/GhosttyRuntime.swift:461-535`.
4. **Pinch to zoom the font** (8-28 pt, default 10), plus Zoom In/Out buttons. A HUD offers Reset, Set as default (persisted) and Restore built-in. Files: `TERM/MobileTerminalZoomControlOverlay.swift`, `TERM/MobileTerminalZoomPreference.swift`, `TERM/MobileTerminalFontPreference.swift`, `TKIT/TerminalFontZoomDirection.swift`.
5. **The Mac can push the phone's font size** (`cmux mobile set-font`). Event: `terminal.set_font`. File: `SH/MobileShellComposite.swift` (`terminalLiveFontStream`).
6. **Scrolling.**
   - Native, pixel-precise local scrollback on the primary screen.
   - Mouse-wheel input to the Mac in alt-screen or mouse-mode programs.
   - Files: `TERM/GhosttySurfaceView+LocalPixelScroll.swift`, `+LocalScrollbackScroll.swift`, `SH/MobileShellComposite+TerminalScrollDelivery.swift`.
   - RPC: `mobile.terminal.scroll`/`terminal.scroll`.
7. **Scrollback depth setting:** 1k, 4k (default), 10k or 20k rows loaded on connect. Files: `SUI/MobileDisplaySettings.swift`, `SUI/MobileSettingsView.swift`.
8. **Shared sizing when several devices view one terminal.**
   - A size chip shows grid, owner and "scaled". When the shared grid is larger than the phone, it is drawn scaled with pinch and pan.
   - The size sheet offers: modes Follow latest, Fit everyone, Largest window, Priority (reorderable), Fixed (cols×rows); a participant list; a "counts toward size" toggle; disconnect one participant or "Disconnect Others".
   - Files: `SUI/TerminalSizeSheet.swift`, `SUI/TerminalSharedSizingOverlay.swift`, `SUI/TerminalSizingText.swift`, `TERM/GhosttySurfaceView+SharedSizing.swift`, `+ScaledGrid.swift`, `SH/MobileShellComposite+TerminalSizing.swift`, `+TerminalViewport.swift`.
   - RPCs: `mobile.terminal.viewport`, `mobile.terminal.size_policy.set`, `mobile.terminal.participant.disconnect`. Event: `mobile.terminal.size_state`.
9. **Detached terminal card.** Shown when the phone was kicked, the Mac stopped sharing, or another connection superseded it. Offers Reattach or Reattach as viewer. File: `SUI/TerminalSizingText.swift:132-179`. RPC: `mobile.terminal.reattach`. Event: `mobile.terminal.detached`.
10. **"Use Full Terminal Height"** (alt-screen apps extend under the keyboard), plus a "Full-Screen Sizing Notice" with "Don't Show Again". Files: `SUI/MobileDisplaySettings.swift`, `SUI/AltScreenNoticeButton.swift`, `SH/MobileShellComposite+AltScreenNotice.swift`.
11. **Bell** plays a warning haptic. File: `TERM/GhosttySurfaceView+Artifacts.swift:249`.
12. **URLs opened via Ghostty OSC/OPEN_URL** open externally. File: `TERM/GhosttyRuntime.swift:244`.
13. **OSC 52:** programs can write the phone clipboard. File: `TERM/GhosttyRuntime.swift:152-164`.
14. **View as Text.** Visible screen plus recent scrollback in a selectable sheet with Copy All. Works offline. Files: `SUI/TerminalTextSheetView.swift`, `SUI/SelectableTextView.swift`, `TERM/GhosttySurfaceRegistry.swift` (`copyableTerminalText`).
15. **Retry terminal creation** from an error banner. File: `SUI/WorkspaceDetailView.swift`. RPC: `terminal.create`.
16. **New terminal (tab) in a workspace.** File: `SH/MobileShellComposite.swift` `createTerminal`. RPC: `terminal.create`/`mobile.terminal.create`.

## 5. Terminal: input methods

1. **Type into the Mac terminal.**
   - Exactly-once, ordered delivery bound to the terminal it was typed into. Render-grid sessions use the `terminal_input` lane.
   - Files: `TERM/TerminalInputTextView.swift`, `SUI/GhosttySurfaceCoordinator+Artifacts.swift`, `SH/MobileShellComposite+ExactlyOnceInput.swift`, `SH/MobileTerminalInputRPCPipeline.swift`.
   - RPC: `terminal.input`/`mobile.terminal.input` `[cap: terminal.input.ordered.v1, terminal.input.exactly_once.v1]`.
2. **Tap a cell to focus input and send a left click** (for mouse-mode TUIs). File: `SH/MobileShellComposite.swift` `clickTerminal`. RPC: `mobile.terminal.mouse`/`terminal.mouse`.
3. **Soft-keyboard ⌘+letter maps to readline shortcuts** (⌘A, ⌘E, ⌘K...). File: `TERM/TerminalInputTextView+CommittedTextSequences.swift`.
4. **Hardware keyboard key map** (not customizable):
   - Arrows and ⌥arrows; Home, End, PgUp, PgDn; forward-delete and ⌥Delete.
   - Esc, Tab, ⇧Tab.
   - Ctrl+a-z and `[ ] \ space 2-7 /`; Ctrl+Shift `@ ^ _ ?`.
   - ⌘V pastes.
   - Files: `TERM/TerminalHardwareKeyResolver.swift`, `TKIT/TerminalKeyEncoder.swift`.
5. **Keyboard accessory bar.**
   - Default order:
     - Modifiers and paste: ⌃ ⌥ ⌘ ⇧, Paste.
     - Common keys: Tab, Esc, Return, ^C, ^D.
     - Launchers: Claude (`claude --dangerously-skip-permissions⏎`), Codex (`codex --yolo -c model_reasoning_effort=xhigh --search⏎`), Ollama (`ollama run `).
     - Arrows, Clear (^L), `~ $ / @ |`, ^Z.
     - Home, End, PgUp, PgDn.
     - Files (hidden by default), Zoom −/+.
   - Fixed controls: composer toggle, show/hide keyboard, hide toolbar, Customize.
   - Modifiers are sticky: tap arms the next key, double-tap locks.
   - An arrow nub works as a joystick with repeat and haptics.
   - Files: `TERM/TerminalInputAccessoryAction.swift`, `TERM/TerminalAccessoryConfiguration.swift`, `TKIT/TerminalInputModifierState.swift`, `TERM/TerminalArrowNubView.swift`, `TKIT/TerminalArrowRepeatService.swift`.
6. **Terminal Shortcuts editor.**
   - Show, hide and reorder built-ins.
   - Add, edit and delete custom actions (label, text, "Run after typing").
   - Reset to Defaults keeps custom actions.
   - The model also supports key-combo payloads, but the editor UI exposes only text.
   - Opened from the bar's Customize button or from Settings.
   - Files: `SUI/TerminalShortcutsSettingsView.swift`, `SUI/CustomToolbarActionEditorView.swift`, `TKIT/CustomToolbarAction.swift`, `TKIT/ToolbarActionPayload.swift`, `TKIT/ToolbarLayoutMigration.swift`.
7. **On-device voice dictation in the composer.** `SFSpeechRecognizer`, on-device preferred, partial results appended; stops on send, blur or switch.
   - Files: `SUI/TerminalComposerView.swift`, `Packages/iOS/CmuxMobileSupport/.../ComposerDictationController.swift`, `ComposerDictationAudioEngine.swift`.
   - No RPC.
8. **iMessage-style composer.**
   - 1-14 lines, open by default per terminal.
   - Send uses bracketed paste plus a single Return. Text is kept if the send fails, with a status pill.
   - Files: `SUI/TerminalComposerView.swift`, `SUI/TerminalComposerPromptEditor.swift`, `SUI/TerminalSendStatusPill.swift`, `SH/MobileShellComposite.swift` (`submitComposer`).
   - RPC: `terminal.paste`/`mobile.terminal.paste` (`submit_key:"return"`).
9. **Per-terminal composer drafts.** Files: `SH/MobileShellComposite.swift` (`terminalInputText`), `SH/InMemoryTerminalDraftStore.swift`.
10. **Attachments into the terminal**: Photo Library, Files (needs Mac upload support), or Paste.
    - Limits: 10 items and 32 MB per terminal; images ≤8 MB; files ≤32 MB; global 20 items and 64 MB.
    - Images are sent as `terminal.paste_image`. Files go through chunked `mobile.task.attachment.upload` and their quoted Mac paths are prepended to the message.
    - Chips show a thumbnail with Quick Look preview and remove.
    - Files: `SUI/TerminalComposerView.swift`, `SUI/TerminalComposerAttachmentPreviewSheet.swift`, `SUI/MobileAttachmentQuickLookView.swift`, `SH/MobileShellComposite+ComposerFileAttachments.swift`, `SM/MobileImageAttachmentPreparer.swift`.
    - Caps: `[task.attachments.v1]`.
11. **Paste interception.** Images and files on the pasteboard become attachments; text pastes normally. Files: `SUI/MobilePasteInterceptingTextView.swift`, `SUI/MobilePasteboardAttachments.swift`.
12. **Paste a clipboard image straight into the terminal** with the Paste key. File: `SUI/GhosttySurfaceCoordinator+Artifacts.swift` (`didPasteImage`). RPC: `terminal.paste_image`/`mobile.terminal.paste_image`.
13. **Haptic Feedback toggle.** File: `SUI/MobileDisplaySettings.swift` (`hapticFeedbackEnabled`).

## 6. Files referenced in the terminal, and the artifact viewer

1. **Tap a file path in terminal output** to open it in the viewer. Tapping a folder opens a folder browser; the "Open Folders on Tap" setting controls this.
   - Files: `SUI/GhosttySurfaceCoordinator+Artifacts.swift:462-565`, `SUI/TerminalFolderTapPolicy.swift`, `TERM/GhosttySurfaceView+Artifacts.swift`.
   - RPC: `mobile.terminal.artifact.stat`.
2. **Files chip and Files sheet.**
   - Scope: In View or Session.
   - Kind filters: All, Code, Docs, Folders, Images, Logs, Icons.
   - Provenance: Created, Referenced, Attached.
   - Sort by Name, Recent or Size; grid or list; search; "new files" indicator.
   - Actions: Copy Path, Share, Browse Folder.
   - Files: `SUI/TerminalArtifactChip*.swift`, `SUI/TerminalArtifactFilesSheet*.swift`, `SUI/TerminalArtifactGallery*.swift`, `SH/MobileChatEventSource+TerminalArtifacts.swift`.
   - RPCs: `mobile.terminal.artifact.scan/list/stat/fetch/thumbnail`, `mobile.chat.artifact.gallery/list/stat/fetch/thumbnail`.
   - Caps: `[terminal.artifact.v1, terminal.artifact.list.v1, chat.artifact.*.v1, iroh.artifact_lane.v1]`. Gated by a remote flag (see the flags section).
3. **Artifact viewer** (package `CmuxAgentChatUI`).
   - Previews: folder browser, zoomable image, PDF, audio/video, markdown (rendered or raw), text/code, Quick Look, binary fallback. Swipe between files.
   - Text tools: syntax highlighting (highlight.js), line numbers, wrap, per-kind font size, find, go to line, live tail of growing files.
   - Markdown: rendered in a WKWebView (marked.js, highlight.js, GitHub CSS, lazy Mermaid/Vega). Remote images require consent.
   - Actions: Share, Save to Files, Copy Image, Copy Contents, Copy Path.
   - Errors: too large, unreachable, reconnecting, session missing, each with Retry.
   - Files: `Packages/iOS/CmuxAgentChatUI/Sources/CmuxAgentChatUI/` (`ChatArtifactPreviewRoute.swift`, `ChatArtifactViewerPager.swift`, `ChatArtifactSyntaxHighlighter.swift`, `ChatArtifactSearchBar.swift`, `ChatArtifactGoToLineBar.swift`, `ChatArtifactAction.swift`, `Markdown/*`).
   - Bytes travel over the irx `artifact` lane, resumable at an offset, or as chunked RPC.
4. **Show Missing Files** setting. File: `SUI/MobileDisplaySettings.swift`.

## 7. Workspace git changes (read-only)

1. **Changes chip, toolbar button, and a one-time hint banner** ("Review this workspace's changes"). Files: `SUI/WorkspaceChangesToolbarButton.swift`, `SUI/WorkspaceChangesHintBanner.swift`, `SH/MobileWorkspaceChangesChip.swift`, `SH/MobileWorkspaceChangesHint*.swift`. RPC: `mobile.workspace.changes.summary` `[cap: workspace.changes.v1]`.
2. **Changed-file tree.** Shows status (added, modified, deleted, renamed, untracked), +/−, binary flag and size. Handles truncation, not-a-repo and empty states, with pull to refresh. Files: `Packages/iOS/CmuxMobileChanges/.../ChangedFilesTree.swift`, `UI/WorkspaceChangesListView.swift`, `SUI/WorkspaceChangesSheet.swift`. RPC: `mobile.workspace.changes.files`.
3. **Per-file unified diff pager.**
   - Intra-line word highlighting; no syntax highlighting.
   - Pinch to set font size (9-22 pt, persisted); Show more.
   - Copy Line and Copy Hunk.
   - Files: `CmuxMobileChanges/.../UnifiedDiffParser.swift`, `IntraLineDiff.swift`, `UI/FileDiffPageView.swift`, `UI/DiffLineRow.swift`, `DiffFontPreference.swift`.
   - RPC: `mobile.workspace.changes.file_diff`.
4. **Expand hidden context** above or below a hunk. Files: `CmuxMobileChanges/.../DiffExpansion*.swift`. RPCs: `mobile.workspace.changes.file_stat`, `mobile.workspace.changes.file_fetch`.
5. **Binary and image preview** with a base/current toggle. File: `CmuxMobileChanges/.../UI/FileDiffBinaryView.swift`.

## 8. Browser

1. **"Streamed" mode: a Mac browser tab rendered on the phone.**
   - List or create tabs.
   - JPEG/PNG frames, acked; tap-to-click with multi-click counts; batched scroll; key and text input with the keyboard auto-opening on editable focus; pinch zoom.
   - Back, forward, reload, navigate.
   - Files: `Packages/iOS/CmuxMobileBrowserStream/*`, `SUI/BrowserStreamPickerRow.swift`, `SH/MobileShellComposite+BrowserStream.swift`, `SH/MobileBrowserStreamLifecycleCoordinator.swift`, `Packages/iOS/CmuxMobileRPC/.../MobileCoreRPCClient+BrowserStream.swift`.
   - RPCs: `mobile.browser.list/create/stream.start/stream.stop/viewport/navigate/back/forward/reload/input.pointer/input.scroll/input.key/input.text/frame.ack`.
   - Events: `browser.frame`, `browser.state`, `browser.closed`.
   - Caps: `[browser.stream.v1, .create.v1, .viewport.v1]`.
2. **Page dialogs from the streamed browser** (insecure-HTTP warning, JS alert, confirm, prompt) shown as native cards. File: `CmuxMobileBrowserStream/.../BrowserStreamDialogCard.swift`. RPC: `mobile.browser.dialog.respond`. Events: `browser.dialog`, `browser.dialog.resolved`. Cap: `[browser.stream.dialog.v1]`.
3. **Reconnect overlay; the selected tab is kept across recovery.** File: `CmuxMobileBrowserStream/.../BrowserStreamRecoveryPolicy.swift`.
4. **"On iPhone" mode: a local WKWebView that browses through the computer.**
   - One pane per workspace, DuckDuckGo by default.
   - The address bar accepts a URL, a bare host or a search.
   - Back, forward, reload, stop, and an error card with Retry.
   - Per-computer, non-persistent cookies.
   - Files: `Packages/iOS/CmuxMobileBrowser/*` (`BrowserSurfaceStore.swift`, `MobileBrowserView.swift`, `BrowserURLResolver.swift`, `MobileBrowserPane.swift`, `BrowserServerRoute.swift`).
5. **The computer's `localhost` ports work from the phone.** A SOCKS5 proxy on phone loopback plus mirrored listening ports. A Mac uses irx `tcp_connect` and `listening_ports` lanes; an SSH host uses `ssh -D`. Not available over the Tailscale TCP fallback.
   - Files: `SH/MobileShellComposite+MacBrowserTunnel.swift`, `SH/MobileMacBrowserNetwork.swift`, `Packages/iOS/CmuxMobileTunnel/*`.
   - Cap: `[browser.tunnel.v1]`.
6. **Streamed / On iPhone mode picker**, remembered per tab. Files: `Packages/iOS/CmuxMobileSupport/.../MobileBrowserModePicker.swift`, `MobileBrowserChromeBar.swift`.

## 9. iOS Simulator streaming from the Mac

1. **Watch and control a Mac's iOS Simulator.**
   - v2: HEVC/H.264 on a dedicated `simulator_stream` lane, used only on an Iroh route.
   - v1 fallback: images in `simulator.frame` events.
   - Files: `SUI/SimulatorStreamV2Pane.swift`, `SUI/SimulatorStreamPane.swift`, `Packages/iOS/CmuxMobileSimulatorStream/*`, `Packages/Shared/CmuxSimulatorStreamKit/*`, `SH/MobileShellComposite+SimulatorStream.swift`, `+SimulatorStreamV2.swift`.
   - RPCs: `mobile.simulator.list/stream.start/stream.stop`.
   - Caps: `[simulator.stream.v1, simulator.stream.v2]`.
2. **Touch, text and hardware buttons.**
   - Touch input, or view only.
   - Send Text.
   - Buttons: Home, Lock, Siri, Side, App Switcher, Volume ±, Power, Swipe Home.
   - RPCs: `mobile.simulator.input.pointer/text/button` (v1), or the lane input batch (v2).
   - Cap: `[simulator.input.v1]`.
3. **Switch the simulator device.** RPCs: `mobile.simulator.devices.list`, `mobile.simulator.device.select`. Cap: `[simulator.devices.v1]`.
4. **Recover a crashed simulator worker; refresh after a stall.** The stream rebuilds automatically after 8 s with no frame. RPC: `mobile.simulator.recover`. Cap: `[simulator.recover.v1]`.
5. **Stream quality:** High, Balanced or Data Saver, applied live. Files: `CmuxMobileSimulatorStream/.../SimStreamQualityPreset.swift`, `SimulatorStreamV2Store.swift`.
6. **"Another device took over" state;** detach in background and reattach in foreground.

## 10. Agent Feed, notifications, and push

1. **Agent Feed tab.**
   - Cross-Mac agent activity. Filters: All Activity, or Needs Input (n), which also drives the tab badge.
   - Read/unread tracking and a full-text view.
   - Open Terminal jumps to the source.
   - Files: `SUI/AgentFeedView.swift`, `SUI/AgentFeedRow.swift`, `SUI/AgentFeedFullTextView.swift`, `SH/MobileShellComposite+AgentFeed.swift`, `SM/MobileAgentFeedItem.swift`.
   - RPCs: `feed.list`, `feed.text`. Event: `feed.changed`. Cap: `[feed.v1]`.
2. **Answer agent permission prompts:** Allow, Allow All This Session, Always, Deny, Bypass Permissions. RPC: `feed.permission.reply`.
3. **Answer agent questions:** single or multi-select, "Other…" free text, multi-question paging. RPC: `feed.question.reply`.
4. **Approve or revise an agent plan:** approve; approve with auto-accept edits, bypass permissions, or manual edits; approve as ultraplan; or revise with feedback. RPC: `feed.exit_plan.reply`.
5. **Free-text reply to an agent from the Feed.** Quoted, with a failed state and Try Again. Files: `SUI/AgentFeedReplyComposer.swift`, `SM/MobileAgentFeedFailedReply.swift`. RPC: `mobile.terminal.paste` (`submit_key=return`, `feed_event_id`).
6. **Notifications history (legacy tab, hidden by default).**
   - Grouped by Today and Yesterday, paged. Filter All or Unread.
   - Mark read or unread; Mark All Read (confirmed). Open navigates to the workspace and pane.
   - Files: `SUI/NotificationFeedView.swift`, `SUI/NotificationFeedRow.swift`, `SH/MobileShellComposite+NotificationFeed.swift`, `SM/MobileNotificationFeed*.swift`.
   - RPCs: `notification.feed.list/mark_read/mark_unread/mark_all_read`. Event: `notification.feed.changed`. Cap: `[notification.feed.v1]`.
7. **Search inside the Feed and Notifications.** Files: `SUI/MobilePrimarySearchScope.swift`, `SUI/NotificationFeedSearchProjectionSync.swift`.
8. **Push opt-in.** "Allow Push Alerts on This iPhone"; the token is uploaded only after the user opts in.
   - Files: `SUI/MobilePushCoordinator.swift`, `SUI/MobilePushSettingsContent.swift`, `ios/cmux/CmuxAppDelegate.swift`, `Packages/Shared/CmuxAuthRuntime/.../Push/PushRegistrationService.swift`.
   - Backend: `POST/DELETE /api/device-tokens`.
9. **End-to-end encrypted push contents.**
   - The NSE picks this install's envelope, checks the account and the pinned Mac key, decrypts with HPKE, checks expiry, and rewrites title, subtitle, body and category. It suppresses the notification on any failure.
   - Files: `ios/NotificationService/NotificationService.swift`, `Packages/macOS/CmuxPhonePush/Sources/CmuxPhonePush/PhonePushCrypto.swift`, `SH/MobileShellComposite+PhonePushKeyExchange.swift`.
   - RPC: `phone_push.keys.exchange` `[cap: phone_push.keys.exchange.v1]`, with a retry UI in `SUI/MobileSettingsView.swift`.
10. **Tap a notification** to deep-link to the workspace or terminal, which also marks it read on the Mac. Delivery is parked until the target is navigable. Alerts appear for "Tab unavailable" and "Connection unavailable".
    - Files: `ios/cmux/CmuxAppDelegate.swift`, `SUI/MobilePushCoordinator.swift` (`handleTap`), `SUI/MobilePushAlertPresentation.swift`, `SH/MobileShellComposite+DeeplinkNavigation.swift`.
11. **Inline reply from the notification.**
    - Category `cmux.terminal.reply`, action `cmux.reply`.
    - Pastes the text plus Return into the target terminal. When the app is backgrounded, it is relayed end-to-end through the presence worker. A local "Reply not sent" notification appears on failure.
    - Files: `ios/cmux/CmuxAppDelegate.swift`, `SUI/ReplyRelayClient.swift`, `SUI/BackgroundReplyRuntime.swift`, `SUI/ReplyFailureNotifier.swift`.
    - Backend: `POST {presence}/v1/replies/e2e`. RPC: `terminal.paste`.
12. **Dismiss sync between phone and Mac.**
    - Swipe-clearing on the phone dismisses on the Mac (category `cmux.terminal`, custom dismiss action).
    - Mac-side dismissals clear the phone's banners, via a live event or a silent push.
    - A foreground reconcile pass runs.
    - Files: `ios/cmux/CmuxAppDelegate.swift`, `SH/MobileShellComposite+NotificationDismissSync.swift`, `SH/PendingNotificationDismissQueue.swift`, `SH/SystemDeliveredNotificationClearer.swift`.
    - RPCs: `notification.dismiss`, `notification.reconcile`. Event: `notification.dismissed`.
13. **Authoritative app-icon badge** (unread total). Sources: the `notification.badge` event, `aps.badge`, or reconcile. Files: `SH/MobileShellComposite+NotificationDismissSync.swift`, `SM/MobileWorkspaceUnreadState.swift`.
14. **Foreground suppression:** no banner for the workspace or surface already on screen. File: `SUI/MobilePushCoordinator.swift` (`shouldPresentInForeground`).
15. **Time-sensitive interruption level** for agent pushes (entitlement).

## 11. Task composer ("New Task")

1. **Start an agent task in a new workspace on a chosen Mac.**
   - Inputs: prompt, optional name, group, agent template, model, effort, directory.
   - The prompt reaches the command as `$CMUX_TASK_PROMPT` and attachment paths as `CMUX_TASK_ATTACHMENTS`.
   - Files: `SUI/TaskComposer/TaskComposerSheet.swift`, `SUI/TaskComposer/TaskComposerButton.swift`, `SH/MobileShellComposite+TaskComposer.swift`, `SM/MobileTaskCommandComposer.swift`.
   - RPC: `workspace.create` (with `initial_command`/env) `[cap: workspace.task_create.v1]`.
2. **Agent templates:** Claude, Codex, OpenCode, Shell, and custom ones (name, command, icon preset or emoji). Add, edit and delete via "Edit Agents"; the last-used choice is remembered. Files: `SUI/TaskComposer/TaskTemplateEditorView.swift`, `TaskTemplateFormView.swift`, `TaskTemplateIconPicker.swift`, `SH/MobileTaskTemplateStore.swift`, `SM/MobileTaskTemplate.swift`.
3. **Model list per Mac and provider.** Fallback is an over-the-air catalog; models are prefetched. Files: `SH/MobileShellComposite+TaskModels.swift`, `+TaskModelPrefetch.swift`, `SH/MobileTaskModelCatalogClient.swift`. RPC: `mobile.task.models.list` `[cap: task.models.v1]`. Backend: `GET https://cmux.com/api/agent-models`.
4. **Directory picker.**
   - Suggestions: focused terminal, workspace, last used, recent, template default, home.
   - Live search of the Mac's index and home folder; browse folders; "Folder Access Needed" error.
   - File: `SH/MobileShellComposite+TaskDirectoryList.swift`.
   - RPCs: `mobile.directory.search`, `mobile.directory.list`.
5. **Attachments** from Photos, Files or Paste. Limits: 10 items, 8 MB per image, 32 MB per file, 64 MB total. Files: `SUI/TaskComposer/TaskComposerSheet+Attachments.swift`, `TaskComposerAttachmentStager.swift`. RPC: `mobile.task.attachment.upload`.
6. **Drafts:** save or delete on exit, a drafts list, New Draft. Files: `SUI/TaskComposer/TaskComposerDraftsSheet.swift`, `SM/MobileTaskComposerDraft.swift`.
7. **Failure and uncertain-result recovery:** "Task already accepted", "status unconfirmed", Refresh Workspaces, or Start Again with a duplicate warning; a banner when no Mac is connected. Files: `SUI/TaskComposer/TaskComposerFailure*.swift`, `TaskComposerCompletedOperationRecovery*.swift`, `TaskComposerConnectionWarningBanner.swift`.

## 12. Direct SSH to any computer (no Mac or cmux account needed)

1. **Add or edit an SSH computer.** Name, host, port, user, key, jump host (`-J`), and "Close idle sessions after" 1h, 24h, 7d or Never. Delete.
   - Files: `SUI/SSHComputerEditorView.swift`, `Packages/iOS/CmuxMobileSSH/Sources/CmuxMobileSSH/SSHHostStore.swift`, `SSHConnection.swift`.
2. **SSH keys.**
   - Generate a Secure Enclave P-256 key, non-exportable, with optional Face ID per use. Corrected in source: there is no Ed25519 generation (`SSHKeyStore.swift:58` `generateSecureEnclaveKey`).
   - Import OpenSSH Ed25519 or ECDSA, including encrypted keys, from a file or paste. RSA and DSA are rejected.
   - Copy or Share the public key; delete a key.
   - Files: `SUI/SSHKeysView.swift`, `CmuxMobileSSH/.../SSHKeyStore.swift`, `SSHPrivateKeyParser.swift`, `SSHPrivateKeyDecryption.swift`.
3. **Install a key with a one-time password** that is never stored (ssh-copy-id style). Files: `CmuxMobileSSH/.../SSHKeyInstaller.swift`, `SSHAuthDelegates.swift`.
4. **Host-key trust on first use**, with a changed-key prompt ("I Reinstalled It, Trust New Key"). Files: `SUI/SSHPromptPresenter.swift`, `CmuxMobileSSH/.../SSHHostKey.swift`.
5. **Workspace kinds on an SSH host.**
   - Plain shell.
   - tmux in control mode: one tab per pane, New Terminal opens a window, Split Right/Down.
   - cmux-tui: workspaces, screens, tabs, browser tabs.
   - The phone emulates the terminal locally and learns the cwd from OSC 7.
   - Files: `SH/MobileSSH*.swift`, `SH/MobileShellComposite+SSH*.swift`, `SH/MobileSSHTmuxControlClient.swift`, `CmuxMobileSSH/.../CmuxTUI/*`, `TKIT/TerminalLocalEmulation.swift`.
6. **Auto-install cmux-tui** v0.13.4 from npm (sha512-verified) to `~/.local/bin`. File: `SH/MobileSSHCmuxTUIProvider.swift`. Backend: `registry.npmjs.org`.
7. **SFTP file browser.**
   - Browse, new folder, rename, delete.
   - Upload from Files or Photos; download, preview (16 MB cap), Save to Files, Share.
   - Copy Path, Insert Path in Terminal.
   - Files: `SUI/SSHFiles/*`, `CmuxMobileSSH/.../SFTP/SFTPClient.swift`.
8. **Paste an image over SSH.** It is uploaded via SFTP to `~/.cmux/uploads/`. File: `SH/MobileShellComposite+SSH*.swift`.
9. **Browser through SSH:** SOCKS (`-D`), local forward (`-L`), or cmux-tui streamed tabs. Files: `SH/MobileSSHComputers+Browser.swift`, `CmuxMobileSSH/.../SSHSocksProxy.swift`, `SSHLocalPortForward.swift`.
10. **Auto-reconnect,** paused when trust is declined.

## 13. Cloud VMs, billing, system VPN

1. **Cloud tab and onboarding** (3 pages). Files: `Packages/iOS/CmuxMobileCloudUI/.../CloudOnboardingView.swift`, `CloudSectionView.swift`, `SUI/MobileCloudTabContent.swift`, `FEAT/MobileCloudComposition.swift`.
2. **List machines, with usage** ("%d of %d machines in use"). Backend: `GET /api/vm`. File: `Packages/iOS/CmuxMobileCloud/.../CloudAPIRequestBuilder.swift`.
3. **Create a machine.**
   - Kind: base or desktop.
   - RAM 4, 8 (default), 16, 24, 32 or 64 GB; locked sizes show an upsell.
   - Backend: `POST /api/vm`, idempotent.
4. **Pause, resume and delete a machine.** Backend: `POST /api/vm/{id}/pause|resume`, `DELETE /api/vm/{id}`.
5. **Open a terminal on a Cloud machine.**
   - Attach plus first-contact approval, then an in-app WireGuard tunnel to the cmux daemon.
   - Daemon operations: list/create workspaces and terminals, attach, send, resize.
   - Files: `CmuxMobileCloud/.../CloudMachineConnection.swift`, `CloudTunnelEnrollment.swift`, `CmuxMobileCloudUI/.../CmuxTerminalClientCloudAdapter.swift`, `CloudSessionController.swift`, `Packages/Shared/CmuxTerminalClient`.
   - Backend: `POST /api/vm/{id}/attach-endpoint`, `POST /api/vm/{id}/cmux-remote/approve`, `POST/DELETE /api/vm/tunnel`.
6. **Cloud machines appear in the Workspaces list and on the Computers screen** (show or hide, new workspace). Files: `Packages/iOS/CmuxMobileCloudBridge/.../CloudWorkspaceBridge.swift`, `CloudWorkspaceProjector.swift`, `SH/MobileShellComposite+ExternalHosts.swift`.
7. **System VPN toggle.** A WireGuard packet tunnel carrying only Cloud private ranges, so Safari and other apps can reach VM ports. It persists until sign-out.
   - Files: `ios/CloudVPN/PacketTunnelProvider.swift`, `CmuxMobileCloud/.../CloudVPNRoutePolicy.swift`, `CloudSystemVPNController.swift`, `CloudSystemVPNSection.swift`.
   - Backend: `POST /api/vm/tunnel` (`tunnelPurpose=browser`).
8. **Subscriptions via StoreKit 2.**
   - Plans: Free, Go, Pro, Max.
   - Subscribe, switch plan, Restore Purchases, Manage Subscription.
   - Accounts that already pay on the web (or have team billing) see a note and no purchase buttons.
   - Entry points: Settings > Plan and Cloud > Upgrade.
   - Files: `Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBilling/*` (`BillingModel.swift`, `BillingTransactionDeliverer.swift`, `HTTPBillingAPI.swift`, `BillingIneligibilityReason.swift`), `Sources/CmuxMobileBillingUI/*`, `FEAT/MobileBillingComposition.swift`.
   - Backend: `POST /api/billing/apple/account-token`, `POST /api/billing/apple/transactions`.

## 14. Keep-awake (caffeinate)

1. **Keep a Mac awake from the phone.** Available as a toggle in computer detail, as Keep Awake / Let Sleep on hidden rows, and on an onboarding card. A status indicator appears on rows.
   - Files: `SUI/MobileCaffeineSettingsContent.swift`, `SUI/HiddenComputerRow.swift`, `SH/MobileShellComposite+Caffeine.swift`.
   - RPCs: `caffeine.status`, `caffeine.set`. Event: `caffeine.status.changed`. Cap: `[caffeine.control.v1]`.

## 15. Onboarding and What's New

1. **Five-stage onboarding:** agents, notifications, push, pairing, connect.
   - Controls: Skip, Back, Not Now, Enable Notifications, "I've enabled iOS pairing", Check for My Mac, Scan Pairing Code, Open Workspaces.
   - Includes a connection-method picker and a Keep Mac Awake card.
   - Replayable from Settings ("View Introduction Again").
   - Files: `SUI/OnboardingFlowView.swift`, `SUI/Onboarding*.swift`, `SM/MobileOnboardingProgress.swift`, `SM/MobileOnboardingStore.swift`, `WS/MobileOnboardingGate.swift`.
2. **What's New.**
   - A launch sheet of unseen pages and an archive in Settings.
   - Remote catalog, gated by channel: dev, beta and internal see it; prod/App Store sees none by default.
   - Web pages open with a native-to-web session handoff.
   - Files: `SUI/MobileWhatsNewCenter.swift`, `MobileWhatsNewCatalog.swift`, `MobileWhatsNewSheet.swift`, `MobileWhatsNewListView.swift`, `MobileWhatsNewWebView.swift`, `MobileWhatsNewRemote.swift`, `SUI/WebSession/MobileWebAppSessionBroker.swift`, `SM/MobileWhatsNewChannelPolicy.swift`.
   - Backend: `GET /api/whats-new`, `POST /handler/app-session-handoff`.

## 16. Settings (every user-changeable item)

Main file: `SUI/MobileSettingsView.swift`; display keys are in `SUI/MobileDisplaySettings.swift`. Everything in this table is Release-visible.

| Section | Item | Key / default |
|---|---|---|
| Account | Name and email; Sign Out; Delete Account; "Sign In to cmux" when signed out | n/a |
| Plan | Current plan, Plans sheet, Subscribe/Switch, Restore, Manage | signed in only |
| What's New | Archive list | hidden if empty |
| Team | Team picker | only when >1 team |
| Connection | One row per Mac with its transport, linking to computer detail (§2.13-14); All Computers; Set Up Computer; View Introduction Again | n/a |
| SSH | SSH Keys | n/a |
| Networking | Relay Preference: Automatic / Selected cmux Relays / Custom Relays. Server-synced through V2 `preferences.update.v1` (`Packages/Shared/CmuxIrxTransport/.../V2/V2ControlService+Operations.swift:219`) | Automatic |
| Networking | Never Use Relays | `cmux.iroh.pathPreference` auto |
| Networking | Custom relays: add, edit, remove, test (URL, provider, region, auth, Keychain secret); Refresh Relay Policy; Reset | n/a |
| Networking | Connection Check (route, relay reachability, secure session); Share Connection Report; Share IT Allowlist (`SUI/MobileIrohConnectionCheckSection.swift`, `SUI/MobileIrohSettingsView.swift`, `FEAT/MobileIrxSettingsController.swift`) | n/a |
| Terminal | Full-Screen Sizing Notice | `cmux.mobile.showAltScreenNotice` true |
| Terminal | Open Folders on Tap | `cmux.mobile.terminalFolderTapEnabled` true |
| Terminal | Use Full Terminal Height | `cmux.mobile.useLegacyTerminalSizing` false |
| Terminal | Terminal Shortcuts editor | `cmux.terminal.toolbar.*` |
| Haptics | Haptic Feedback | `cmux.mobile.hapticFeedbackEnabled` true |
| Display | Show Missing Files | `cmux.mobile.showMissingFiles` false |
| Display | Wrap Workspace Titles | `cmux.mobile.wrapWorkspaceTitles` false |
| Display | Legacy Notifications Tab (inverse of the key) | `cmux.mobile.debug.feedReplacesNotifications.v1` true, so the tab is hidden |
| Display | Show Tab in Feed | `cmux.mobile.feedShowsTab` false |
| Display | Preview Lines (1/2) | `cmux.mobile.workspacePreviewLineCount` 2 |
| Display | Terminal Scrollback (1k/4k/10k/20k) | `cmux.mobile.terminalScrollbackRows` 4000 |
| Push Alerts | Allow Push Alerts; secure-setup retry | `cmux.notifications.pushEnabled` |
| Privacy | Share Analytics and Crash Reports | `sendAnonymousTelemetry` true |
| Diagnostics | Export Logs, Clear Logs, Verbose Connection Log | `cmux.diagnostics.verbose-log-enabled` false |
| Legal & Support | Privacy Policy, Terms, Support mailto (`SUI/MobileSettingsLegalSupportSection.swift`) | n/a |
| Reset | Erase All Data on This Device | n/a |
| About | Version; Copy Support Information (`Packages/iOS/CmuxMobileSupport/.../MobileDebugInformation`) | n/a |
| (in stream) | Simulator stream quality | `cmux.simulatorStream.quality` |
| (in viewer) | Diff font size; artifact wrap, line numbers and font | persisted per feature |

## 17. Feedback, diagnostics, telemetry

1. **Send Feedback** (from the picker menu or Settings). It is emailed to the team with a build and device stamp; no logs are sent. Files: `SH/MobileFeedbackEmailClient.swift`, `SUI/WorkspaceDetailView.swift` (`feedbackComposer`), `FEAT/MobileFeedbackStamp+Current.swift`. Backend: `POST /api/feedback`.
2. **Privileged feedback to the Mac agent.** For `@manaflow.ai` accounts, also in Release. Sends the diagnostic log, debug log and visible terminal text. Files: `SH/MobileShellComposite+DogfoodFeedback.swift`, `SM/MobileFeedbackRoute.swift`. RPC: `dogfood.feedback.submit` `[cap: dogfood.v1]`.
3. **Export and Clear debug logs.** A 4000-line ring buffer plus a rotating file; persisted in Release only when "Verbose Connection Log" is on. Files: `Packages/iOS/CmuxMobileDiagnostics/.../MobileDebugLog.swift`, `MobileDebugLogSink.swift`.
4. **Analytics** (PostHog via a first-party proxy) and network telemetry. Opt-out is shared with crash reporting. Files: `Packages/iOS/CmuxMobileAnalytics/*`, `FEAT/MobileAnalyticsComposition.swift`. Backend: `POST /api/analytics/events`, `POST /api/observability/mobile-network`.
5. **Crash reporting** (Sentry + MetricKit). Masked session replay; the terminal, browser-stream, simulator and camera views are always masked. Opting out purges the cache. Files: `Packages/iOS/CmuxMobileCrashReporting/.../MobileCrashReporter.swift`, `MobileCrashRevocationWatcher.swift`, `ios/cmux/AppCompositionRoot.swift`.

## 18. Localization and accessibility

1. **UI localized in en, ar, de, es, fr, ja, ko, zh-Hans and zh-Hant.**
   - App catalog: 1891 keys. ShellUI: 381 keys. Changes, AgentChatUI and Core have their own catalogs.
   - Files: `ios/cmux/Resources/Localizable.xcstrings`, `InfoPlist.xcstrings`, `SUI/Resources/Localizable.xcstrings`, `Packages/iOS/CmuxMobileChanges/.../Resources/Localizable.xcstrings`, `Packages/iOS/CmuxAgentChatUI/.../Resources/Localizable.xcstrings`, `CORE/Resources/Localizable.xcstrings`.
   - App Store metadata covers 14 locales: `ios/fastlane/metadata/*`.
2. **Accessibility.** Reduce-motion handling in root transitions (`SUI/CMUXMobileRootView.swift`), accessibility labels and identifiers throughout, and longer toast dwell under VoiceOver or Switch Control (`CmuxMobileToast/.../ToastCenter.swift`; toasts are DEBUG-only).

---

## DEBUG / dev-only / feature-flagged (listed separately)

**DEBUG builds only (`#if DEBUG`)**

- **Settings > Developer:**
  - Replay What's New.
  - Toast Gallery and Toast Demo (delay `cmux.debug.toastDemoDelaySeconds`).
  - Unread Indicator Leftness (`cmux.mobile.debug.unreadIndicatorLeftShift.v2`).
  - Rebuilt Keyboard Pinning (`cmux.mobile.debug.forceRebuildKeyboardDock.v1`).
  - Source: `SUI/MobileSettingsView.swift:338-413`.
- **Settings > CMUX Labs:**
  - Task Composer Liquid Glass (`cmux.mobile.debug.taskComposerFullLiquidGlass.v1`).
  - Feed Bubble Quotes (`cmux.mobile.debug.feedBubbleQuotes.v1`).
  - Shell Icon Lab (`SUI/TaskComposer/TaskComposerShellIconLabView.swift`).
  - Unread Indicator Lab (`SUI/UnreadIndicatorLabView.swift`, `cmux.mobile.debug.unreadBadgeDiameter.v1`).
  - Source: `SUI/MobileSettingsView.swift:415-479`.
- **Full push diagnostics** (Release shows only the toggle). Source: `SUI/MobilePushSettingsContent.swift`.
  - Delivery Status readiness list.
  - Forward Alerts from This Mac, Forwarding Mode (Always / Only When Away), Hide Notification Content: `phone_push.settings.update`.
  - Send Test Alert: `phone_push.test`.
  - `phone_push.status.get`.
  - Retry Registration, Open iOS Notification Settings, Test Inline Reply (Local).
  - Caps: `phone_push.settings.v1`, `phone_push.test.v1`. The Mac-side push settings are therefore not reachable from a Release phone UI. Confirm whether the rewrite should expose them.
- **Networking "Debug Verification" transport mode** (Automatic / Relay Only / No Relay, `cmux.iroh.debug.transport-mode`). Source: `SUI/MobileIrohSettingsView.swift`.
- **"Copy Debug Logs"** in the terminal picker. Sources: `SUI/TerminalPickerMenuContent.swift:113`, `SUI/WorkspaceDetailView.swift:990-1002`.
- **Iroh release gate and soak runner.**
  - Sources: `ios/cmuxPackage/Sources/CmuxIrohReleaseGateSupport/*`, `MobileIrohReleaseGateScene` in `ios/cmux/cmuxApp.swift`, `SH/../CmuxMobileShellReleaseGateSupport/*` (including `MobileIrohReleaseGateRPCMethodInventory.swift`, the canonical method list).
  - Uses `mobile.rpc.methods`. Env `CMUX_IROH_SOAK_PROFILE`.
- **Probes and harnesses:**
  - Latency probe (`SH/MobileLatencyProbe.swift`, `CMUX_LATENCY_PROBE`).
  - Hide-computers verifier (`CMUX_HIDE_COMPUTERS_VERIFIER`).
  - Mac-compat override (`SH/MobileMacCompatDebugOverride.swift`, `CMUX_DEBUG_FORCE_MAC_COMPAT`).
  - Theme parity preview.
  - Terminal stress harnesses (`TERM/MobileRecoveryStress*`, `MobileZoomStressView` `CMUX_ZOOM_STRESS`, `MobileBottomScrollStressView` `CMUX_BOTTOM_SCROLL_STRESS`, `TERM/Debug/*`).
  - Keyboard-toggle notify trigger.
  - Latency trace.
- **UI-test previews and fixtures:** `SUI/Debug/*`, `SUI/HideComputersVerifierView.swift`, `SUI/MacSurfaceGalleryPreviewView.swift`, `SUI/TerminalLayoutPreviewView.swift`, `SUI/ChangesPreviewView.swift`, `SUI/ScreenshotNotificationPresenter.swift` (App Store screenshots), `FEAT/Debug/*`, `UITestConfig`, and auto-open-first-workspace.
- **Transport and environment overrides:** the `debug_loopback` transport (simulator/DEBUG), `CMUX_DEV_AUTH` compile flag, presence URL override from env, crash-capture signals, `CMUX_REPLAY_FORCE_SESSION`, `--cmux-test-crash`.
- **All toasts:** `shippedEnabled = false`; enabled only with `CMUX_TOAST_GALLERY=1`.

**Remote flags (PostHog via `GET /api/client-config`; `FEAT/MobileFeatureFlags.swift`, `Packages/Shared/CmuxClientConfig/.../ClientConfigFlag.swift`)**

- `ios-artifact-chip-enabled-release` (default true): kill switch for the terminal Files chip.
- `ios-keyboard-dock-rebuild-revert` (default false): reverts keyboard pinning on iOS 26 and earlier.
- `ios-terminal-latency-enabled` (default true): terminal latency telemetry.
- Declared but not consumed by iOS UI: `pro-upgrade-ui-enabled-release`, `mobile-connect-button-enabled-release`, `cmux-for-windows`, `cmux-for-linux`, `cmux-for-android`.

**Local / env flags**

- Multi-Mac aggregation: `CMUX_MULTI_MAC_AGGREGATION` / defaults `multiMacAggregation`. On by default.
- Paired-Mac backup: `CMUX_MOBILE_PAIRED_MAC_BACKUP` / defaults `mobilePairedMacBackup`. On in DEBUG, off in Release.
- Force relay: plist `CMUX_IROH_V2_FORCE_RELAY`.
- V2 environment and base URL: `CMUX_IROH_V2_ENVIRONMENT`, `CMUX_IROH_V2_BASE_URL`.
- Agent models URL: `CMUX_AGENT_MODELS_URL`.

**Server and account gated**

- Demo content (`demonstrationContentEnabled`).
- Privileged feedback (`@manaflow.ai` plus `dogfood.v1`).
- Remote Mac-compat list (empty list is the kill switch).
- What's New channel gate (dev, beta and internal only).
- Dev build kind admits only dev-tag Macs, plus tag grants (`mobile.compatible_tags.changed`).

**Present but unused by UI:** `mobile.chat.*` session methods and the `chat.message` topic; `workspace.group.collapse/expand` (inventory only); legacy `cmux/mobile/1` Iroh protocol, V1 control socket, and trust-broker `/api/devices/iroh/*` (in shared packages, not wired into the app); `websocket` route kind (enum only, no factory).

---

## Login screen (preserve whole)

**What the screen does:**
- Apple, Google and GitHub buttons (browser OAuth through Stack).
- "or continue with email", leading to "Email me a code", then a 6-character code ("Check your email", "Verify code", "Use a different email").
- Email-verification gate: "Verify your email", resend, "I verified my email".
- Billing recovery: "Already paid? Recover your account".
- Session-restore status with Retry.
- Analytics events `ios_sign_in_started/cancelled/completed/failed`.

**Hosted by** `SUI/CMUXMobileRootView.swift:615` (`SignInView()`), selected by `MobileRootAuthGate.shouldShowSignIn`.

| File | Lines | Role |
|---|---|---|
| `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/SignInView.swift` | 587 | The screen (methods, email, code and verification modes) |
| `.../CmuxMobileShellUI/SignInAuthRestoreStatusView.swift` | 87 | Restore status and Retry |
| `.../CmuxMobileShellUI/SignInBillingRecoveryActions.swift` | 68 | "Already paid?" recovery |
| `.../CmuxMobileShellUI/SignInErrorPresentation.swift` | 119 | Error copy mapping |
| `.../CmuxMobileShellUI/SignInEmailCodeFailurePolicy.swift` | 23 | Code failure, then verification fallback |
| `.../CmuxMobileShellUI/OAuthSignInProvider.swift` | 70 | apple / google / github button model |
| `.../CmuxMobileShellUI/DividerLabel.swift` | 25 | "or continue with email" divider |
| `.../CmuxMobileShellUI/View+MobileButtonLoading.swift` | 28 | Button spinner modifier |
| `.../CmuxMobileShellUI/RestoringSessionView.swift` | 30 | Restoring-session screen |
| `.../CmuxMobileShellUI/MobileRootAuthGate+ShellSync.swift` | 28 | Gate to shell sync |
| `.../CmuxMobileShellUI/MobileSignOutHook.swift` | 31 | Sign-out hook |
| `.../CmuxMobileShellUI/MobileAuthenticatedShellPresentation.swift` | 25 | Post-auth surface choice |
| `.../CmuxMobileShellUI/MobileStartupConnectionCoordinator.swift` | 237 | Post-sign-in connect |
| `.../CmuxMobileShellUI/CMUXMobileRootView.swift` | 1705 | Host: auth gate switch, `onOpenURL`, auth-change bootstrap |
| `.../CmuxMobileShellUI/MobileSettingsAccountSection.swift` | 195 | Account, sign out, delete (adjacent) |
| `.../CmuxMobileShellUI/MobileSettingsDeleteAccountFailureKind.swift` | 93 | Delete failure kinds (adjacent) |
| `Packages/iOS/CmuxMobileWorkspace/Sources/CmuxMobileWorkspace/MobileRootAuthGate.swift` | 234 | `shouldShowSignIn`, `isAttachURL`, shell surface |
| `Packages/iOS/CmuxMobileWorkspace/Sources/CmuxMobileWorkspace/SignInCodeInputPolicy.swift` | 53 | Code normalization and auto-submit |
| `Packages/iOS/CmuxMobileSupport/Sources/CmuxMobileSupport/View+MobileGlass.swift` | 172 | `mobileGlassButton` / `mobileGlassProminentButton` styles |
| `ios/cmuxPackage/Sources/cmuxFeature/MobileAuthComposition.swift` | 585 | Builds `AuthCoordinator`, Stack config, APNs environment, token stores |
| `ios/cmuxPackage/Sources/cmuxFeature/MobileAuthBuildPolicy.swift` | 25 | Per-build auth policy |
| `ios/cmuxPackage/Sources/cmuxFeature/DeferredSignInHook.swift` | 22 | Deferred sign-in hook |
| `ios/cmuxPackage/Sources/cmuxFeature/AuthCoordinatorIdentityProvider.swift` | 39 | Identity bridge |
| `ios/cmuxPackage/Sources/cmuxFeature/MobileIrohAuthObserver.swift` | 41 | Auth to Iroh scope |
| `ios/cmux/Assets.xcassets/{GoogleLogo,GitHubLogo,CmuxLogo}.imageset` | n/a | Button and brand art |
| `Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/**` (65 files) | 8115 total | `AuthCoordinator` (875) and its extensions; `BrowserSignIn/HostBrowserSignInFlow.swift` (581); `Client/StackAuthClient.swift` (244); `TokenStores/*` (Keychain 273, File 129, Fallback 130); `Coordinator/AccountDeletionClient.swift` (132); `EmailVerificationRecoveryClient.swift` (70); `Push/PushRegistrationService.swift` (1500) |
| `Packages/Shared/CMUXAuthCore/Sources/CMUXAuthCore/**` (13 files) | ~518 | Auth models, identity store, session cache, team selection |
| `vendor/stack-auth-swift-sdk-prerelease` | vendored | Stack Auth SDK |

Shell-UI screen code alone (the first 13 rows) is about 1,358 lines, excluding the root view.

---

## Wire protocol

### Transports

| Kind | Status in the app |
|---|---|
| `iroh` (irx) | Primary. iroh QUIC via iroh-ffi, ALPN `cmux/irx/1`. Path modes: automatic (relay plus NAT traversal), relay-only, direct-only (≤16 user `addr:port`). Mac UDP port 58470. Iroh relays use EdDSA JWTs (30-minute lifetime) from the V2 Worker. |
| `tailscale` | Legacy plain TCP, default port 58465. Used for user-entered or migrated host:port. |
| `debug_loopback` | DEBUG/simulator only. |
| `websocket` | Enum only; throws `unsupportedRouteKind`. |

Sources: `Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/` (`IrxProtocol.swift`, `IrxAdmission.swift`, `IrxEndpoint.swift`, `IrxPeerEngine.swift`, `V2/*`), `Packages/Shared/CmuxIrohTransport/*`, `CORE/CmxTransport.swift`, `FEAT/MobileIrx*.swift`, `FEAT/MobileIroh*.swift`.

There is no DO-relay byte transport; Durable Objects appear only as the V2 control plane.

**Backoff**
- Peer redial: 400 ms doubling to 5 s, with a server `retryAfter` floor.
- No redial on: superseded, user-requested, invalid/expired grant, revoked, identity mismatch, malformed hello, protocol mismatch.
- V2 socket: `min(60, 2^n)` s with jitter 0.8-1.2.

### Control plane (phone to backend, not to the Mac)

- **Endpoint:** `wss://cmux-v2[-staging|-development].debussy.workers.dev/v2/control/socket`. HTTP fallback is `POST /v2/control/session` and `POST /v2/requests`.
- **Identity:** one Ed25519 key per install; the seed is the iroh secret key.
- **Auth:** `Authorization: IrohTicket <t>` or `Bearer <stack>`.
- **Setup:** `session.open.v1` with a signed proof over canonical JSON, then `session.ready.v1 {sessionId, teamRevision, ticket?, challenge?}`, then, if challenged, `device.register.v1` to `device.registered.v1`.
- **Requests:** `ticket.request.v1`, `relay.request.v1`, `directory.request.v1`, `device.metadata.v1`, `device.revoke.v1` (Forget Computer), `permission.update.v1`, `preferences.update.v1` (relay preference), `session.goodbye.v1`, `session.ack.v1`.
- **Responses:** `relay.result.v1`, `directory.changed.v1`, `operation.completed.v1`, `device.revoked.v1`, `error.v1{code, retryable, retryAfterMS}`.
- **Dial policy:** the phone dials only Mac records that are not revoked, have `pairingEnabled`, have `platform=mac`, and whose device ID matches. Directory routes `iroh-v2-<id>` get priority -10000.
- **Admission:** the Mac admits the phone by comparing its TLS EndpointID with its own directory snapshot, without calling the backend.

### Pairing payloads

Sources: `CORE/CmxPairingQRCode.swift`, `CORE/CmxPairingURLScheme.swift`, `CORE/CompactAttach*.swift`, `Packages/iOS/CmuxMobileRPC/.../CmxAttachTicketInput.swift`.

- **Scheme:** `cmux-ios-<bundleId>`. `cmux-ios` and `cmux-ios-dev` are parsed only.
- **v3:** `…://attach?v=3&i=<endpoint-id-hex>[&d=<mac-device-id>]`.
- **v2:** `…://attach?v=2&ub=<stack-user-id>&pc=<compat>&r=host:port` (≤8 routes, loopback rejected).
- **v1:** `…://attach?v=1&payload=<b64url compact JSON {v,w,t,d,u,pc,av,ab,r[]}>`.
- QR codes never carry tokens.

### irx framing and lanes

- **Lanes:** each QUIC stream is one lane. The first frame is `IrxLaneDescriptor{v:1, lane, resource?, cursor?, offset?, host?, port?}`.
- **Control frames:** u32 big-endian length plus JSON, ≤256 KiB.
- **Admission:**
  1. Phone sends `IrxHello{v:1, proto:"cmux/irx/1", grant:null, natBarrier?}`.
  2. Mac replies `IrxAdmit{session, keepaliveIntervalMs:5000, keepaliveDeadlineMs:2000}` within 5 s. A denial is a QUIC close with reason `irx:<code>`.
  3. Phone authorizes direct paths, then sends `IrxClientReady{v:1}`.
- **Stream credit:** bidirectional 64, unidirectional 40.

| Lane | Direction | Carries |
|---|---|---|
| `control` | bidi, phone-opened | JSON RPC requests and replies (below) |
| `control_repair` | bidi | Control-lane repair (`IrxControlLaneRepairAck`); only read-only methods are resent (`MobileRPCControlFrameResendPolicy.swift`) |
| `keepalive` | bidi | `IrxPing{seq, pong}` |
| `events` | uni, Mac-opened | Shared event stream |
| `events` + `resource:"terminal:<uuid>"` | uni, Mac-opened | Per-surface event lanes (≤32), opted in with `surface_event_lanes:"v1"` |
| `terminal` + `resource`, `cursor?` | phone-opened | Terminal output in `CMXT` envelopes, resumable from a byte cursor |
| `terminal_input` + `resource` | phone-opened | Terminal input frames for render-grid sessions |
| `artifact` + `resource`, `offset` | Mac to phone | Raw file bytes, resumable at an offset (`transport:"iroh_artifact_v1"` in fetch params; `FEAT/IrxArtifactLane.swift`) |
| `tcp_connect` + `host`, `port` | bidi | `IrxTunnelOpenReply{status}`, then raw TCP (On iPhone browser; ≤32 concurrent) |
| `listening_ports` | reply | `{ports[{port,address}], allowsNonLoopbackHosts}` (≤256 mirrored) |
| `simulator_stream` + `resource:"simstream:<uuid>"` | bidi | Simulator video and input (binary, below) |

**Lane errors:** `IrxLaneError{2 unsupportedResource, 3 quota, 4 cursorGap, 5 invalidInput, 6 streamFailure}`.

**`CMXT` terminal output envelope** (`CmxIrohTerminalOutputEnvelopeCodec.swift`)
- 36-byte header: `"CMXT"`, ver u8 = 1, kind u8 (1 replay, 2 chunk, 3 inputAck), reserved u16, `retainedBaseSequence` u64, `sequence` u64, `currentSequence` u64, payloadLen u32.
- Payload ≤256 KiB. The first envelope is always a replay.

**Terminal input frame** (`CORE/MobileTerminalInputFrame.swift`, `MobileTerminalInputDelivery.swift`)
- u32 header: bit 31 = 8-byte latency marker present, bit 30 = 40-byte delivery identity (surface UUID + stream UUID + seq u64) present, low bits = length.
- Ack statuses: applied, duplicate, gap (resend from `expected`), surface_mismatch, terminal_unavailable, busy, rejected.

**Simulator video** (`Packages/Shared/CmuxSimulatorStreamKit/.../SimStreamProtocol.swift`, `SimStreamWireCodec.swift`): u32 BE length plus a type byte.

| Type | Message | Fields |
|---|---|---|
| `0x01` | start | ver, epoch, maxLongSide, codecs (HEVC 0, H.264 1) |
| `0x02` | config | codec, w, h, scale, orientation, nalLen, parameter sets |
| `0x03` | frame | seq, keyframe, pts µs, AVCC/HVCC |
| `0x04` | ack | seq, receipt µs; credit window 2 |
| `0x05` | input | touch / text / HID key / button |
| `0x06` | keyframeRequest | |
| `0x07` | stop | |
| `0x08` | state | preparing, streaming, deviceUnavailable, workerCrashed, failed, closed |

Bitrate ranges 0.6 to 20 Mbps.

**Browser stream:** no lane. Frames arrive as `browser.frame` events (JPEG/PNG, base64) and are acked with `mobile.browser.frame.ack`. Pacing: ≤3 unacked, 33 ms minimum interval, 3 s stall (`CORE/MobileBrowserStreamPacing.swift`).

### RPC envelope

The same framing runs on the irx control lane and on Tailscale TCP (`Packages/iOS/CmuxMobileRPC/.../MobileCoreRPCSession.swift`, `CORE/MobileSyncProtocol.swift`): u32 BE length plus JSON, ≤8 MiB.

- **Request:** `{"id":"<uuid>","method","params":{},"auth"?:{stack_access_token, attach_token}}`.
- **Success:** `{"id","ok":true,"result"}`. **Error:** `{"id","ok":false,"error":{code,message}}`. Notable codes: `unauthorized`, `account_mismatch`, `method_not_found`.
- **Event:** `{"kind":"event","topic","payload","stream_id"?}`.

**Auth** (`MobileCoreRPCClient.swift` ~575-733)
- On irx, `auth` is stripped; transport admission authorizes the session.
- On Stack-bearer routes, every method except `mobile.host.status` carries `stack_access_token`. An `attach_token` is added when the ticket covers the target.
- On `unauthorized`, the client force-refreshes the token and retries once. `account_mismatch` is never retried.

**Common params:** `workspace_id`, `surface_id`, `client_id`. Terminal verbs have `mobile.terminal.*` aliases of `terminal.*`.

The canonical method list is `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShellReleaseGateSupport/MobileIrohReleaseGateRPCMethodInventory.swift`. The method tables below also include call-site-only methods that the inventory omits: `feed.text`, `caffeine.*`, `phone_push.keys.exchange`, `mobile.todo.*`, `mobile.status.*`, `mobile.panel.artifact.*`, `mobile.surface.focus`, `mobile.terminal.size_policy.set/participant.disconnect/reattach`, `mobile.simulator.devices.list/device.select/recover`.

### Methods: host, session, events

| Method | Request | Response |
|---|---|---|
| `mobile.host.status` | `{}` (unauthenticated probe) | `capabilities[]`, `terminal_fidelity`, `mac_display_name`, `mac_device_id`, `mac_instance_tag`, `mac_client_namespace`, `mac_compatible_mac_tags`, `mac_app_version/build`, `theme`, `terminal_theme_revision_epoch`, `phone_push` |
| `mobile.rpc.methods` | `{}` | `{schema_version, methods[]}` (DEBUG gate) |
| `mobile.attach_ticket.create` | `{ttl_seconds:3600, scope:"mac", target:"ticket_only"}` | `{ticket}` |
| `mobile.events.subscribe` | `{client_id, stream_id, topics[], render_grid_anchor?:"screen", event_transport?:"iroh_server_events_v1", surface_event_lanes?:"v1"}` | `{stream_id, already_subscribed?, event_transport?, surface_event_lanes?}` |
| `mobile.events.unsubscribe` | `{stream_id}` | `{stream_id, removed}` |
| `mobile.events.probe` | `{client_id, stream_id}` | `{stream_id, subscribed}` |
| `mobile.sync.fetch` | `{collections[{id, epoch?, rev?}]}` | `{epoch, workspaces?, groups?}`, each `{mode: snapshot\|delta, rev, from_rev?, records[], removed_ids[]}` |

### Methods: workspaces and surfaces

| Method | Request | Response / capability |
|---|---|---|
| `workspace.list` / `mobile.workspace.list` | `{include_host_status?, workspace_id?, terminal_id?}` | `workspaces[{id, window_id, title, description(_truncated), custom_color, current_directory, is_selected, is_pinned, group_id, preview, preview_at, last_activity_at, has_unread, unread_count, terminals[], surfaces[{surface_id, kind, title, is_focused, file_path, todo}], simulators[]}]`, `groups[{is_collapsed, is_pinned, icon_symbol, anchor_workspace_id}]`, `render_epoch`, `render_revision_floor`, `host_status?` |
| `workspace.create` | `{group_id?, title?, working_directory?, initial_command?, initial_env?, operation_id?}` | `{created_workspace_id, created_terminal_id}` |
| `workspace.action` | `{workspace_id, client_id, window_id?, action: rename{title}\|pin\|unpin\|set_description\|clear_description\|set_color\|clear_color\|mark_read\|mark_unread}` | caps `workspace.actions.v1`, `.metadata.v1`, `.read_state.v1` |
| `workspace.close` | `{workspace_id, client_id, window_id?}` | `workspace.close.v1` |
| `workspace.move` | `{workspace_id, group_id?, before_workspace_id?, move_group?}` | `workspace.move.v1` |
| `workspace.group.create` | `{title?, …}` | `workspace.group_create.v1` |
| `workspace.group.action` | `{group_id, action: pin\|unpin\|rename\|ungroup\|delete, title?}` | `workspace.group_actions.v1` |
| `workspace.group.collapse` / `.expand` | n/a | Inventory only; the phone collapses groups locally |
| `mobile.surface.focus` | `{workspace_id, surface_id}` | `surface.focus.v1` |
| `mobile.todo.add/set_state/edit/move/remove/open` | `{workspace_id, text\|id, state\|to_index\|focus}` | `todo.v1` |
| `mobile.status.set` / `.cycle` | `{workspace_id, status\|"auto"}` | `todo.v1` |
| `mobile.workspace.changes.summary` | `{workspace_ids[], force?}` | per workspace `{is_repo, repo_root, base_ref, files_changed, additions, deletions}` |
| `mobile.workspace.changes.files` | `{workspace_id}` | file list (status, +/−, binary, size, old path); error `not_a_repo` |
| `mobile.workspace.changes.file_diff` | `{workspace_id, path, max_lines?}` | unified diff |
| `mobile.workspace.changes.file_stat` / `.file_fetch` | `{workspace_id, path, revision: current\|base, offset?, length?}` | stat / bytes |

### Methods: terminal

| Method | Request | Notes |
|---|---|---|
| `terminal.create` / `mobile.terminal.create` | `{workspace_id}` | Returns the workspace list |
| `terminal.input` / `mobile.terminal.input` | `{…, text, input_sequence?, input_stream_id, input_stream_seq, viewport_columns, viewport_rows, viewport_generation?}` | Reply `input_ack{status, stream_id, sequence, expected}` |
| `terminal.paste` / `mobile.terminal.paste` | `{…, text, submit_key?:"return", feed_event_id?}` | Composer, Feed reply, inline reply |
| `terminal.paste_image` / `mobile.terminal.paste_image` | `{…, image_base64, image_format}` | |
| `mobile.terminal.replay` / `terminal.replay` | `{…, anchor?:"screen", max_scrollback_rows?, trace_id?, viewport_*?}` | `{surface_id, data_base64?, snapshot_base64?, render_grid?, seq, columns, rows, host_elapsed_ms, size_state, self_participant_id}` |
| `mobile.terminal.viewport` / `terminal.viewport` | `{…, viewport_columns, viewport_rows, viewport_generation, device_kind/name/id, counts_override?, clear?}` | Effective size and size state |
| `mobile.terminal.scroll` / `terminal.scroll` | `{…, delta_lines, col, row, max_scrollback_rows?}` | |
| `mobile.terminal.mouse` / `terminal.mouse` | `{…, col, row}` | Left click |
| `mobile.terminal.size_policy.set` | `{…, policy{mode: fixed\|largest\|latest\|priority\|smallest, …}}` | |
| `mobile.terminal.participant.disconnect` | `{…, participant_id}` | |
| `mobile.terminal.reattach` | `{…, as_viewer, device_kind, device_name, device_id?, viewport_*}` | |

### Methods: artifacts

| Method | Request | Notes |
|---|---|---|
| `mobile.terminal.artifact.scan` | `{workspace_id, surface_id, include_missing, trace_id, visible_only?, count_only?, include_directories?}` | `terminal.artifact.v1` |
| `mobile.terminal.artifact.list` | `{…, path, trace_id}` | `terminal.artifact.list.v1` |
| `mobile.terminal.artifact.stat/fetch/thumbnail` | `{…, path, offset?, length?, max_dimension?, transport?:"iroh_artifact_v1"}` | Bytes inline or on the `artifact` lane |
| `mobile.panel.artifact.stat/fetch/thumbnail` | `{workspace_id, surface_id, path, …}` | `panel.artifact.v1` |
| `mobile.chat.artifact.stat/fetch/thumbnail/list/gallery` | `{session_id, path, page_size, cursor, query, include_directories}` | `chat.artifact.v1`, `.gallery.v1`, `.folders.v1` |
| `mobile.chat.sessions/session/history/send{text,attachments}/interrupt{hard}/answer{optionIndex}` | `{session_id, …}` | No UI caller |

### Methods: task composer

| Method | Request |
|---|---|
| `mobile.directory.list` | `{path, offset, limit}` |
| `mobile.directory.search` | `{query}` |
| `mobile.task.models.list` | `{provider}` (`task.models.v1`) |
| `mobile.task.attachment.upload` | `{operation_id, upload_id, file_name, total_bytes, offset, data, last}` (chunked; `task.attachments.v1`) |

### Methods: browser and simulator

| Method | Request |
|---|---|
| `mobile.browser.list` / `.create` | `{workspace_id}`; list returns `[{panel_id, workspace_id, url, title, page_width, page_height, can_go_back, can_go_forward, is_loading, pending_dialog}]` |
| `mobile.browser.stream.start` | `{panel_id, viewport_width, viewport_height, viewport_scale}` |
| `mobile.browser.stream.stop` / `.reload` / `.back` / `.forward` | `{panel_id}` |
| `mobile.browser.viewport` | `{panel_id, viewport}` |
| `mobile.browser.navigate` | `{panel_id, url}` |
| `mobile.browser.frame.ack` | `{panel_id, sequence}` |
| `mobile.browser.dialog.respond` | `{panel_id, dialog_id, button_id, text?}` |
| `mobile.browser.input.pointer` | `{panel_id, kind: click\|down\|up, x, y, click_count, button: left\|right}` |
| `mobile.browser.input.scroll` / `.key{key, modifiers[]}` / `.text` | `{panel_id, …}` |
| `mobile.simulator.list` | `{workspace_id}` |
| `mobile.simulator.stream.start` / `.stop` | `{panel_id, workspace_id}` (v2 video on the lane) |
| `mobile.simulator.input.pointer` | `{panel_id, workspace_id, phase: began\|moved\|ended\|tap, x, y}` |
| `mobile.simulator.input.text` | `{…, text}` |
| `mobile.simulator.input.button` | `{…, button: home\|swipeHome\|appSwitcher\|lock\|siri\|sideButton\|power\|volumeUp\|volumeDown\|action\|watchSideButton}` |
| `mobile.simulator.devices.list` | returns `devices[{udid, name, runtime_name, family, state, is_selected}]` |
| `mobile.simulator.device.select` | `{…, udid}` |
| `mobile.simulator.recover` | `{panel_id, workspace_id}` |

### Methods: feeds, notifications, push, misc

| Method | Request | Response |
|---|---|---|
| `feed.list` | `{}` | `{revision, items[{id, workstream_id, source, kind, status, created_at, updated_at, title, cwd, request_id, tool_name, tool_input, tool_result, plan, plan_summary, default_mode, questions[], text, decision, workspace_id, surface_id}]}` (`feed.v1`) |
| `feed.text` | `{item_id, offset, version?}` | Full text page |
| `feed.permission.reply` | `{request_id, mode}` | |
| `feed.question.reply` | `{request_id, selections}` | |
| `feed.exit_plan.reply` | `{request_id, mode, feedback?}` | |
| `notification.feed.list` | paging (not fully traced) | items `{workspace_id, surface_id, created_at, is_read, retargets_to_live_surface_owner, workspace_title, surface_title}` |
| `notification.feed.mark_read` / `.mark_unread` | `{notification_ids[]}` | |
| `notification.feed.mark_all_read` | `{}` | |
| `notification.dismiss` | `{notification_ids[], client_id}` | |
| `notification.reconcile` | `{delivered_ids[], client_id}` | |
| `phone_push.keys.exchange` | `{version, hpke_envelope_version, client_id, ios_build_id, descriptor{version, algorithm, installationID, keyID, publicKey}}` | Mac descriptor plus `account_id, team_id?, mac_device_id, mac_instance_tag, mac_build_id` (pinned by the phone) |
| `phone_push.status.get` | `{}` | `{verified_same_account, forwarding_disabled, suppressed_mac_active, forwarding_enabled, queue_persistence, hide_content, …}` |
| `phone_push.settings.update` | `{forwarding_enabled?, mode?, hide_content?}` | |
| `phone_push.test` | `{}` | stage: queued, disabled, Mac active, queue full, auth unavailable |
| `caffeine.status` / `caffeine.set` | `{}` / `{enabled}` | `{enabled}` |
| `dogfood.feedback.submit` | `{text, terminal_text, build_stamp, client_id, logs…}` | |

### Server-pushed event topics

Delivered on the `events` lane, or the TCP event stream. The primary Mac gets all topics. Secondary Macs get only `workspace.updated`, `notification.feed.changed`, `feed.changed` and `caffeine.status.changed` (`SH/SecondaryMacSubscription.swift`).

| Topic | Payload |
|---|---|
| `workspace.updated` | Triggers a refetch |
| `mobile.sync.delta` | `{epoch, collection, from_rev, to_rev, records, removed_ids}` |
| `terminal.bytes` | `{surface_id, data_b64, seq?}` |
| `terminal.render_grid` | `{render_grid}`, see below |
| `terminal.set_font` | `{font_size, surface_id?, workspace_id?}` |
| `mobile.terminal.size_state` | `{surface_id, state, self_participant_id?}` |
| `mobile.terminal.detached` | `{surface_id, reason, by?, at?}` |
| `notification.badge` | `{unread_count?}` |
| `notification.dismissed` | `{ids[], unread_count?}` |
| `notification.feed.changed`, `feed.changed` | `{revision}` |
| `phone_push.status.changed` | Triggers `phone_push.status.get` |
| `caffeine.status.changed` | Caffeine state |
| `mobile.compatible_tags.changed` | `{tags[]}` |
| `browser.frame` | `{panel_id, seq, format, page_width, page_height, pixel_width, pixel_height, data_b64}` |
| `browser.state` | `{panel_id, url, title, can_go_back, can_go_forward, is_loading, progress, editable_focused}` |
| `browser.closed` | `{panel_id}` |
| `browser.dialog` | `{panel_id, dialog_id, kind, title, message, host, buttons[], text_field?, informational}` |
| `browser.dialog.resolved` | `{panel_id, dialog_id}` |
| `simulator.frame` | (v1) `{panel_id, seq, format, pixel_width, pixel_height, display_scale, data_base64}` |
| `simulator.state` / `simulator.closed` | Panel state |
| `chat.message` | Unused |

**Render-grid frame** (`CORE/MobileTerminalRenderGrid*.swift`)
- Header and positioning: `format:"cmux.render-grid.v1"`, `surface_id`, `state_seq`, `applied_input_sequence`, `render_epoch`, `render_revision`, `columns`, `rows`, `full`, `cleared_rows`, `active_screen`, `anchor`, `scrolled_rows`, `history_rows`, `delta_base_*`, `row_space_revision`.
- Cursor: `{row, column, visible, style, blinking}`.
- Content: `styles[]`, `row_spans[{row, column, style_id, text, cell_width?}]`, `scrollback_rows`, `scrollback_spans`, `modes[]`.
- Theme: `terminal_foreground/background/cursor_color`, `terminal_theme*`.
- Timing: `host_timing`.

### Encrypted push

Sources: `Packages/iOS/CmuxMobileRPC/.../MobilePhonePushKeyExchange.swift`, `Packages/macOS/CmuxPhonePush/.../PhonePushCrypto.swift`, `ios/NotificationService/NotificationService.swift`.

- **Algorithm:** HPKE auth mode, `x25519-hpke-sha256-chacha20poly1305-v2`.
- **info and aad:** `cmux-phone-push-v2|keyID|senderKeyID|` followed by the sorted JSON tuple `{accountID, teamID, iosBuildID, iosInstallationID, macDeviceID, macInstanceTag, macBuildID}`.
- **APNs carrier:** `userInfo.cmux.encryptedPayloads[]` (≤200 entries).
- **Plaintext fields:** `kind` (notify or dismiss), title ≤120, subtitle, body ≤500, `badgeCount`, `replyShape`, `category`, workspace/surface/notification IDs, `retargetsToLiveSurfaceOwner`, `expirationEpochSeconds`.
- **Silent dismiss push:** `content-available` with the dismissed IDs and `aps.badge`.

### Backend HTTP and WebSocket endpoints the phone uses

Calls carry the Stack bearer token plus `X-Stack-Refresh-Token` (and `X-Cmux-Team-Id` for devices) unless noted.

- **Auth and account:**
  - Stack Auth SDK (OAuth and OTP).
  - `POST /api/auth/email-verification`, `POST /api/billing/recover`.
  - `/api/account` (delete).
  - `api/subrouter/teams`.
- **Push:** `POST/DELETE /api/device-tokens`.
- **Devices and compatibility:** `GET /api/devices`, `GET /api/mobile-mac-compat`.
- **Config and content:**
  - `GET /api/client-config` (flags).
  - `GET /api/whats-new`, `POST /handler/app-session-handoff`.
  - `GET https://cmux.com/api/agent-models`.
- **Feedback and telemetry:** `POST /api/feedback`, `POST /api/analytics/events`, `POST /api/observability/mobile-network`.
- **Cloud:**
  - `GET/POST /api/vm`, `POST /api/vm/{id}/pause|resume`, `DELETE /api/vm/{id}`.
  - `POST /api/vm/{id}/attach-endpoint`, `POST /api/vm/{id}/cmux-remote/approve`.
  - `POST/DELETE /api/vm/tunnel`.
- **Billing:** `POST /api/billing/apple/account-token`, `POST /api/billing/apple/transactions`.
- **V2 control plane:** `wss://cmux-v2*.debussy.workers.dev/v2/control/socket`, `POST /v2/control/session`, `POST /v2/requests`.
- **Presence** (`https://presence.cmux.dev`):
  - `WS /v1/presence/subscribe`.
  - `POST /v1/replies/e2e` (inline-reply relay).
  - `GET/POST /v1/sync/paired-macs` (backup).
  - `WS /v1/workspace-presence` (`view`/`workspace.presence`, plus `sync/v1` `sync.hello/snapshot/delta/tick`).
- **SSH:** `registry.npmjs.org/<pkg>/<ver>` (cmux-tui install).

### Not traced (gaps)

- Full params for `notification.feed.list`, `mobile.terminal.mouse` beyond `col`/`row`, `workspace.group.create` beyond `title`, and the `mobile.browser.input.scroll/key/text` field names.
- Payloads of `caffeine.status.changed`, `simulator.state` and `simulator.closed`.
