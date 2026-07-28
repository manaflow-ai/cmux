//
//  NSScreen+Extensions.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2024-04-06.
//

import SwiftUI

@MainActor
extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screenWithMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) })

        return screenWithMouse
    }

    var hasNotch: Bool {
        defaultDynamicNotchGeometry.hasHardwareNotch
    }

    var notchSize: NSSize? {
        guard hasNotch else { return nil }
        return defaultDynamicNotchGeometry.notchFrame.size
    }

    var notchFrame: NSRect? {
        guard let notchSize else { return nil }
        return .init(
            x: frame.midX - (notchSize.width / 2),
            y: frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    var menubarHeight: CGFloat {
        defaultDynamicNotchGeometry.menuBarHeight
    }

    var notchFrameWithMenubarAsBackup: NSRect {
        defaultDynamicNotchGeometry.notchFrame
    }

    func dynamicNotchGeometry(
        syntheticNotchWidth: CGFloat = 164
    ) -> DynamicNotchScreenGeometry {
        DynamicNotchScreenGeometry(
            screen: self,
            syntheticNotchWidth: syntheticNotchWidth
        )
    }

    private var defaultDynamicNotchGeometry: DynamicNotchScreenGeometry {
        dynamicNotchGeometry()
    }
}
