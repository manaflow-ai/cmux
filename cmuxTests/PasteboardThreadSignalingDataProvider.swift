import AppKit
import Foundation

/// Supplies distinct bytes based on the thread that resolves a lazy pasteboard item.
final class PasteboardThreadSignalingDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let mainThreadData: Data
    private let backgroundThreadData: Data

    init(mainThreadData: Data, backgroundThreadData: Data) {
        self.mainThreadData = mainThreadData
        self.backgroundThreadData = backgroundThreadData
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setData(
            Thread.isMainThread ? mainThreadData : backgroundThreadData,
            forType: type
        )
    }
}
