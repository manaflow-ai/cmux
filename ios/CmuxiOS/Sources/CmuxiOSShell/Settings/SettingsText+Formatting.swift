import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import CmuxLink
import CmuxTerminalRenderCore
import Foundation

/// Titles and formatted values of the Settings model types.
extension SettingsText {
    // MARK: Account

    static func deletionTitle(_ failure: AccountDeletionFailure) -> String {
        failure == .serverCleanupIncomplete ? deletionCleanupTitle : deletionFailedTitle
    }

    static func deletionMessage(_ failure: AccountDeletionFailure) -> String {
        switch failure {
        case .generic: deletionGeneric
        case .connection: deletionConnection
        case .unauthorized: deletionUnauthorized
        case .stackDeleteIncomplete: deletionStackIncomplete
        case .serverCleanupIncomplete: deletionCleanupIncomplete
        case .timedOut: deletionTimedOut
        case .unknown: deletionUnknown
        }
    }

    // MARK: Devices

    static func title(of kind: DeviceSectionKind) -> String {
        switch kind {
        case .thisDevice: sectionThisDevice
        case .macs: sectionMacs
        case .otherDevices: sectionOther
        }
    }

    static func title(of platform: DevicePlatform) -> String {
        switch platform {
        case .mac: platformMac
        case .iPhone: platformIPhone
        case .iPad: platformIPad
        case .cloudVM: platformCloud
        }
    }

    static func symbol(of platform: DevicePlatform) -> String {
        switch platform {
        case .mac: "desktopcomputer"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .cloudVM: "cloud"
        }
    }

    static func trustTitle(_ device: DeviceRecord) -> String {
        if device.isThisDevice { return thisDevice }
        switch device.trust {
        case .trusted: return trusted
        case .discovered: return notPaired
        case .revoked: return revoked
        }
    }

    /// "Paired · seen 5 minutes ago"; this device and unseen devices show
    /// only their trust.
    static func status(of device: DeviceRecord, now: Date = Date()) -> String {
        let trust = trustTitle(device)
        guard !device.isThisDevice, let lastSeen = device.lastSeen else { return trust }
        let relative = lastSeen.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return String(format: seenFormat, trust, relative)
    }

    static func title(of kind: PathKind) -> String {
        switch kind {
        case .direct: pathDirect
        case .p2p: pathP2P
        case .turn: pathTurn
        case .relay: pathRelay
        }
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return unknownValue }
        return String(format: millisecondsFormat, Int64(value.rounded()))
    }

    /// "Direct · 12 ms".
    static func pathSummary(_ badge: PathBadge) -> String {
        guard badge.rttMilliseconds != nil else { return title(of: badge.path.kind) }
        return String(format: pathSummaryFormat, title(of: badge.path.kind), milliseconds(badge.rttMilliseconds))
    }

    /// "Direct path, 12 milliseconds" for VoiceOver.
    static func pathSpoken(_ badge: PathBadge) -> String {
        let rtt = badge.rttMilliseconds.map {
            Measurement(value: $0.rounded(), unit: UnitDuration.milliseconds)
                .formatted(.measurement(width: .wide, usage: .asProvided))
        } ?? unknownValue
        return String(format: pathSpokenFormat, title(of: badge.path.kind), rtt)
    }

    static func message(for error: DeviceActionError) -> String {
        switch error {
        case .offline: errorOffline
        case .refused(let reason): reason
        case .invalidName(.empty): errorEmptyName
        case .invalidName(.tooLong(let limit)): String(format: errorLongNameFormat, Int64(limit))
        case .invalidName(.controlCharacters): errorControlName
        case .cannotRemoveThisDevice: errorThisDevice
        case .notFound: errorNotFound
        }
    }

    static func removeDeviceConfirm(_ name: String) -> String {
        String(format: removeDeviceConfirmFormat, name)
    }

    // MARK: Terminal

    static func title(of choice: TerminalThemeChoice) -> String {
        switch choice {
        case .matchMac: themeMatchMac
        case .ghosttyDefault: themeGhostty
        case .monokai: themeMonokai
        case .paper: themePaper
        case .ink: themeInk
        }
    }

    static func title(of font: TerminalFontChoice) -> String {
        switch font {
        case .standard: fontStandard
        case .menlo: fontMenlo
        case .courierNew: fontCourier
        }
    }

    static func title(of style: TerminalCursorStyle) -> String {
        switch style {
        case .block: cursorBlock
        case .bar: cursorBar
        case .underline: cursorUnderline
        }
    }

    static func points(_ size: Double) -> String {
        String(format: pointsFormat, Int64(size.rounded()))
    }

    static func keyCount(_ count: Int) -> String {
        String(format: keyCountFormat, Int64(count))
    }

    static func previewValue(_ preferences: TerminalPreferences) -> String {
        String(format: previewValueFormat, title(of: preferences.theme), title(of: preferences.font),
               title(of: preferences.cursorStyle))
    }

    static func title(of key: KeyBarKeyID) -> String {
        switch key {
        case .escape: keyEscape
        case .tab: keyTab
        case .control: keyControl
        case .alternate: keyAlternate
        case .left: keyLeft
        case .down: keyDown
        case .up: keyUp
        case .right: keyRight
        case .tilde: keyTilde
        case .slash: keySlash
        case .pipe: keyPipe
        case .dash: keyDash
        case .paste: keyPaste
        case .hideKeyboard: keyHide
        }
    }

    static func symbol(of key: KeyBarKeyID) -> String {
        switch key {
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .control: "control"
        case .alternate: "option"
        case .left: "arrow.left"
        case .down: "arrow.down"
        case .up: "arrow.up"
        case .right: "arrow.right"
        case .tilde, .slash, .pipe, .dash: "character"
        case .paste: "doc.on.clipboard"
        case .hideKeyboard: "keyboard.chevron.compact.down"
        }
    }

    // MARK: Notifications

    static func title(of kind: NotificationKind) -> String {
        switch kind {
        case .permission: kindPermission
        case .question: kindQuestion
        case .planApproval: kindPlan
        case .finished: kindFinished
        case .terminalAlert: kindTerminal
        }
    }

    static func detail(of kind: NotificationKind) -> String {
        switch kind {
        case .permission: kindPermissionDetail
        case .question: kindQuestionDetail
        case .planApproval: kindPlanDetail
        case .finished: kindFinishedDetail
        case .terminalAlert: kindTerminalDetail
        }
    }

    static func syncFooter(_ state: NotificationSyncState) -> String {
        switch state {
        case .localOnly: syncLocal
        case .syncing: syncSyncing
        case .synced: syncSynced
        case .offline: syncOffline
        case .refused(let reason): String(format: syncRefusedFormat, reason)
        }
    }
}
