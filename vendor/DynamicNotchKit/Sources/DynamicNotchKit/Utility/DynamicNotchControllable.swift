//
//  DynamicNotchControllable.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2025-04-20.
//

import AppKit

/// Protocol for controlling the dynamic notch behavior.
///
/// This protocol defines the methods that can be used to control the appearance of the dynamic notch.
/// Implemented in ``DynamicNotch`` and ``DynamicNotchInfo``, to ensure a unified interface.
///
@MainActor
public protocol DynamicNotchControllable {
    /// Sets the notch's appearance to be expanded, showing the expanded content.
    ///
    /// This method is asynchronous and waits for the animation to complete before returning.
    ///
    /// - Parameter screen: the screen on which to show the expanded notch.
    func expand(on screen: NSScreen) async

    /// Sets the notch's appearance to be compact, showing the leading and trailing contents.
    ///
    /// This method is asynchronous and waits for the animation to complete before returning.
    ///
    /// - Parameter screen: the screen on which to show the compact notch.
    func compact(on screen: NSScreen) async

    /// Sets the notch's appearance to be hidden, hiding all content and deinitializing the window.
    ///
    /// This method is asynchronous and waits for the animation to complete before returning.
    ///
    func hide() async
}
