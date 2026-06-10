@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyConfigTests: XCTestCase {
}

final class GhosttyMouseFocusTests: XCTestCase {
}

final class ZshShellIntegrationHandoffTests: XCTestCase {
}

