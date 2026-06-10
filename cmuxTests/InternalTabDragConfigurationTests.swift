import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@available(macOS 26.0, *)
private struct DragConfigurationOperationsSnapshot: Equatable {
    let allowCopy: Bool
    let allowMove: Bool
    let allowDelete: Bool
    let allowAlias: Bool
}

@available(macOS 26.0, *)
private enum DragConfigurationSnapshotError: Error {
    case missingBoolField(primary: String, fallback: String?)
}

@available(macOS 26.0, *)
private func dragConfigurationOperationsSnapshot<T>(from operations: T) throws -> DragConfigurationOperationsSnapshot {
    let mirror = Mirror(reflecting: operations)

    func readBool(_ primary: String, fallback: String? = nil) throws -> Bool {
        if let value = mirror.descendant(primary) as? Bool {
            return value
        }
        if let fallback, let value = mirror.descendant(fallback) as? Bool {
            return value
        }
        throw DragConfigurationSnapshotError.missingBoolField(primary: primary, fallback: fallback)
    }

    return try DragConfigurationOperationsSnapshot(
        allowCopy: readBool("allowCopy", fallback: "_allowCopy"),
        allowMove: readBool("allowMove", fallback: "_allowMove"),
        allowDelete: readBool("allowDelete", fallback: "_allowDelete"),
        allowAlias: readBool("allowAlias", fallback: "_allowAlias")
    )
}

#if compiler(>=6.2)
@MainActor
final class InternalTabDragConfigurationTests: XCTestCase {
    func testDisablesExternalOperationsForInternalTabDrags() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Requires macOS 26 drag configuration APIs")
        }

        let configuration = InternalTabDragConfigurationProvider.value
        let withinApp = try dragConfigurationOperationsSnapshot(from: configuration.operationsWithinApp)
        let outsideApp = try dragConfigurationOperationsSnapshot(from: configuration.operationsOutsideApp)

        XCTAssertEqual(
            withinApp,
            DragConfigurationOperationsSnapshot(
                allowCopy: false,
                allowMove: true,
                allowDelete: false,
                allowAlias: false
            )
        )

        XCTAssertEqual(
            outsideApp,
            DragConfigurationOperationsSnapshot(
                allowCopy: false,
                allowMove: false,
                allowDelete: false,
                allowAlias: false
            )
        )
    }
}


@MainActor
final class InternalTabDragBundleDeclarationTests: XCTestCase {
    private func exportedTypeIdentifiers(bundle: Bundle) -> Set<String> {
        let declarations = (bundle.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]) ?? []
        return Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
    }

    func testAppBundleExportsInternalDragTypes() {
        let exported = exportedTypeIdentifiers(bundle: Bundle(for: AppDelegate.self))

        XCTAssertTrue(
            exported.contains("com.splittabbar.tabtransfer"),
            "Expected app bundle to export bonsplit tab-transfer type, got \(exported)"
        )
        XCTAssertTrue(
            exported.contains("com.cmux.sidebar-tab-reorder"),
            "Expected app bundle to export sidebar tab-reorder type, got \(exported)"
        )
    }
}
#endif


