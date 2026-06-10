# Document-Based Apps: `ReadableDocument` / `WritableDocument`
**SDK Version:** 27.0 and later
**Platforms:** iOS 27, macOS 27, visionOS 27. **Unavailable** on watchOS and tvOS.

If the user's deployment target is below iOS 27 / macOS 27 / visionOS 27, do not use these APIs unconditionally.

SDK 27.0 introduces two new protocols for document-based apps: `ReadableDocument` (read-only) and `WritableDocument` (adds saving). They give the document model **direct access to the file URL**, run reading and writing in the background, support progress reporting, and support coordinated disk access at any time. For new code, always prefer them over `ReferenceFileDocument` and `FileDocument`.

## Mental model

- A **document** is a reference type (`@Observable final class`) that conforms to `ReadableDocument` (read-only), `WritableDocument` (write-only, rare), or both (read-write, this is the most common default case). `DocumentGroup`'s read-write initializer requires `ReadableDocument & WritableDocument`. Because it's a reference type, SwiftUI doesn't recreate the document on every change; `@Observable` tracks individual property changes, so a `TextEditor` bound to a document property doesn't destroy the model on every keystroke.
- A **snapshot** is a value capturing the document's state. It connects the document to its reader and writer. It can be any type (including the document type itself, a `String`, or a custom struct). Reading and writing may use **different** snapshot types.
- A **`DocumentReader`** converts a file into a snapshot in the background; a **`DocumentWriter`** converts a snapshot back to disk in the background. These are independent types, usually nested in the document.
- SwiftUI coordinates file access and runs reading/writing off the main actor automatically.

### Save / open flow

When SwiftUI autosaves or the person presses Command-S:
1. SwiftUI calls `snapshot(contentType:)` **on the main actor** to capture state.
2. SwiftUI calls `writer(configuration:)` to get the `DocumentWriter`.
3. SwiftUI calls the writer's `write(content:to:previous:progress:)` **in the background** with coordinated file access.

Reading is the mirror: SwiftUI calls `reader(configuration:)`, then `read(from:progress:)` **in the background**, then delivers the snapshot via `apply(snapshot:previous:)` **on the main actor**.

> **Important:** `snapshot(contentType:)` and `apply(snapshot:previous:)` run on the **main actor**. Keep them lightweight. Do all serialization / deserialization inside the writer's `write(…)` and the reader's `read(…)`.

## Set up the app: `DocumentGroup`

```swift
@main
struct NotesApp: App {
    var body: some Scene {
        DocumentGroup { document in
            TextEditorView(document: document)
        } makeDocument: { configuration, context in
            TextDocument(configuration: configuration, context: context)
        }
    }
}
```

`DocumentGroup` takes two closures:

- **`editor`** (read-write, `ReadableDocument & WritableDocument`) or **`viewer`** (read-only, `ReadableDocument`): builds the UI for an open document.
- **`makeDocument`** / **`makeReadableDocument`**: creates the document instance. It receives:
  - `configuration: URLDocumentConfiguration`: file URL (`nil` for new documents), last modification date, and a file-coordinator factory.
  - `context: DocumentCreationContext`: exposes `creationSource: DocumentCreationSource?`, the source associated with the `NewDocumentButton` that triggered creation (iOS/visionOS).

`makeDocument` is `async` and may `throw`. Throw `CancellationError` to cancel, or `await` to present pre-creation UI (a template picker, import preview).

### Read-only documents

Conform only to `ReadableDocument` and use `viewer` / `makeReadableDocument`:

```swift
DocumentGroup { document in
    PDFViewer(document: document)
} makeReadableDocument: { configuration, context in
    PDFDocument(configuration: configuration, context: context)
}
```

Set `CFBundleTypeRole` to `Viewer` in Info.plist (`Editor` for read-write).

## `FileWrapperDocumentReader` / `FileWrapperDocumentWriter` (recommended)

These convenience types handle file reading and writing: you supply closures that convert between your snapshot and a `FileWrapper`. **This is the recommended path for both flat-file and package documents,** including incremental package writes. Reach for a custom `DocumentReader` / `DocumentWriter` only when you need streaming, direct URL access for another framework, or want to avoid `FileWrapper`'s per-file `Data` conversion in a very large package.

### Flat-file document

```swift
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class TextDocument: ReadableDocument, WritableDocument {
    static let readableContentTypes = [UTType.utf8PlainText]

    var text: String
    var configuration: URLDocumentConfiguration

    init(configuration: URLDocumentConfiguration) {
        self.text = ""
        self.configuration = configuration
    }

    func reader(
        configuration: sending DocumentReadConfiguration
    ) -> sending FileWrapperDocumentReader<String> {
        FileWrapperDocumentReader(configuration) { fileWrapper in
            guard let data = fileWrapper.regularFileContents,
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return text
        }
    }

    @MainActor
    func apply(snapshot: String, previous: String?) async throws {
        self.text = snapshot
    }

    func writer(
        configuration: sending DocumentWriteConfiguration
    ) -> sending FileWrapperDocumentWriter<String> {
        FileWrapperDocumentWriter(configuration) { snapshot in
            FileWrapper(regularFileWithContents: Data(snapshot.utf8))
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> String { text }
}

struct TextEditorView: View {
    @Bindable var document: TextDocument
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        TextEditor(text: $document.text)
            .padding()
            .onChange(of: document.text) { old, new in
                document.registerTextUndo(from: old, undoManager: undoManager)
            }
    }
}

@main
struct MyTextApp: App {
    var body: some Scene {
        DocumentGroup { document in
            TextEditorView(document: document)
        } makeDocument: { configuration, context in
            TextDocument(configuration: configuration)
        }
    }
}
```

### Package documents (incremental read/write)

A package is a directory the system shows as a single item. Packages let you read and write **incrementally**: load only what's needed, write only what changed.

The `FileWrapperDocumentWriter` closure takes a **single argument**, the snapshot.  To write incrementally, **hold onto the `FileWrapper` from the last read or save** on the document and reuse its unchanged children. Carry an `isChanged` flag on each page so the writer can skip serialization entirely for pages whose bytes are still in sync with disk; the save touches only the pages the person actually edited.

For incremental read, perform on-demand read via a `FileCoordinator`, provided by `URLDocumentConfiguration`.

```swift
struct NotebookSnapshot {
    var metadata: NotebookMetadata
    var pages: [UUID: NotebookPage]
    /// The package's `FileWrapper` from the last read or save.
    /// Carry it so the writer can reuse its unchanged children.
    var previousFileWrapper: FileWrapper?
}

struct NotebookMetadata: Codable {
    var title: String
    var pageOrder: [UUID]   // authoritative on-disk page list
    var createdDate: Date
}

struct NotebookPage: Equatable {
    var text: String
    /// `true` when `text` is out of sync with the page on disk. Set when the
    /// person edits a page; cleared in `snapshot(contentType:)` once the
    /// snapshot capturing the edit has been handed to the writer.
    var isChanged: Bool = false
}

@Observable
final class NotebookDocument: ReadableDocument, WritableDocument {
    static let readableContentTypes: [UTType] = [.notebook]

    var metadata: NotebookMetadata
    var pages: [UUID: NotebookPage]
    var configuration: URLDocumentConfiguration
    @ObservationIgnored 
    private var previousFileWrapper: FileWrapper?

    init(configuration: URLDocumentConfiguration) {
        self.configuration = configuration
        self.metadata = NotebookMetadata(title: "Untitled", pageOrder: [], createdDate: .now)
        self.pages = [:]
    }
}

extension NotebookDocument {
    func reader(
        configuration: sending DocumentReadConfiguration
    ) -> sending FileWrapperDocumentReader<NotebookSnapshot> {
        FileWrapperDocumentReader(configuration) { directory in
            let childrenOnDisk = directory.fileWrappers ?? [:]
            guard let metadataOnDisk =
                childrenOnDisk["metadata.json"]?.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let metadata = try JSONDecoder()
                .decode(NotebookMetadata.self, from: metadataOnDisk)

            // Load only the first page now. The rest stay on disk until
            // the person opens them.
            let pageWrappersOnDisk = childrenOnDisk["pages"]?.fileWrappers ?? [:]
            var firstPage: [UUID: NotebookPage] = [:]
            if let id = metadata.pageOrder.first,
               let data = pageWrappersOnDisk["\(id.uuidString).txt"]?
                   .regularFileContents,
               let text = String(data: data, encoding: .utf8) {
                firstPage[id] = NotebookPage(text: text)
            }
            return NotebookSnapshot(
                metadata: metadata, pages: firstPage, fileWrapper: directory
            )
        }
    }

    @MainActor
    func apply(
        snapshot: sending NotebookSnapshot,
        previous: sending NotebookSnapshot?
    ) async throws {
        self.metadata = snapshot.metadata
        self.pages = snapshot.pages
        self.previousFileWrapper = snapshot.previousFileWrapper
    }

    func writer(
        configuration: sending DocumentWriteConfiguration
    ) -> sending FileWrapperDocumentWriter<NotebookSnapshot> {
        FileWrapperDocumentWriter(configuration) { snapshot in
            let directory = snapshot.fileWrapper
                ?? FileWrapper(directoryWithFileWrappers: [:])

            // Replace metadata in place unconditionally since it is small.
            if let existingMetadata = directory.fileWrappers?["metadata.json"] {
                directory.removeFileWrapper(existingMetadata)
            }
            let metadataData = try JSONEncoder().encode(snapshot.metadata)
            let metadataWrapper =
                FileWrapper(regularFileWithContents: metadataData)
            metadataWrapper.preferredFilename = "metadata.json"
            directory.addFileWrapper(metadataWrapper)

            // Reuse or create the "pages" subdirectory.
            let pagesDirectoryWrapper = directory.fileWrappers?["pages"] ?? {
                let created = FileWrapper(directoryWithFileWrappers: [:])
                created.preferredFilename = "pages"
                directory.addFileWrapper(created)
                return created
            }()

            // Touch only the pages whose content changed since the last save.
            // Unchanged pages are skipped entirely (no serialization, no
            // wrapper replace), so `FileWrapper` doesn't re-write them to disk.
            let existingPages = pagesDirectoryWrapper.fileWrappers ?? [:]
            for (pageID, pageContent) in snapshot.pages where pageContent.isChanged {
                let filename = "\(pageID.uuidString).txt"
                if let existing = existingPages[filename] {
                    pagesDirectoryWrapper.removeFileWrapper(existing)
                }
                let wrapper = FileWrapper(
                    regularFileWithContents: Data(pageContent.text.utf8)
                )
                wrapper.preferredFilename = filename
                pagesDirectoryWrapper.addFileWrapper(wrapper)
            }

            // Remove pages dropped from the document. `metadata.pageOrder` is
            // authoritative, not the in-memory `pages`, which only holds
            // pages the person opened.
            let liveFilenames = Set(
                snapshot.metadata.pageOrder.map { "\($0.uuidString).txt" }
            )
            for (filename, child) in existingPages where !liveFilenames.contains(filename) {
                pagesDirectoryWrapper.removeFileWrapper(child)
            }

            return directory
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending NotebookSnapshot {
        let result = NotebookSnapshot(
            metadata: metadata, pages: pages, fileWrapper: previousFileWrapper
        )
        // Clear the dirty flags on the document. The snapshot just captured
        // owns those edits now; the writer will persist them, and any further
        // edits start a fresh `isChanged` cycle.
        for id in pages.keys {
            pages[id]?.isChanged = false
        }
        return result
    }
}
```

> **Important:** `FileWrapper` loads file contents **on demand**. A child file may be gone or inaccessible by the time you call `regularFileContents`, even if it existed when you opened the package. Handle errors when reading children, not just when opening the wrapper.

## Register undo actions (required for autosave)

SwiftUI tracks unsaved changes **through undo actions**. Without registered undo actions, **SwiftUI won't autosave.** Read `\.undoManager` from the environment and route every mutation through a method that registers an undo action; calling the same method from the undo closure gives redo for free.

```swift
extension TextDocument {
    func registerTextUndo(from previousText: String, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { document in
            let current = document.text
            document.text = previousText
            document.registerTextUndo(from: current, undoManager: undoManager)
        }
        undoManager?.setActionName("Edit")
    }
}
```

## Custom readers and writers

Use a custom `DocumentReader` / `DocumentWriter` only when the `FileWrapper` convenience types can't do what you need:

- streaming reads or writes of a large media file in chunks,
- direct URL access for AVFoundation, PDFKit, Core Image, or any C library that takes file paths,
- a very large package where converting every child to `Data` to diff is too costly; a custom writer can compare snapshots directly via `previous`.

`read` and `write` are **`nonisolated`** and run in the background; `read` returns a `sending` snapshot, `write` consumes one.

```swift
import CoreImage

struct ImageSnapshot {
    var image: CIImage?
}

@Observable
final class ImageDocument: ReadableDocument, WritableDocument {
    static let readableContentTypes: [UTType] = [.jpeg]

    var displayImage: CGImage?
    var configuration: URLDocumentConfiguration
    private let context = CIContext()

    init(configuration: URLDocumentConfiguration) {
        self.configuration = configuration
    }

    struct Reader: DocumentReader {
        nonisolated func read(
            from source: URL, progress: consuming Subprogress
        ) async throws -> sending ImageSnapshot {
            guard let image = CIImage(contentsOf: source) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return ImageSnapshot(image: image)
        }
    }

    struct Writer: DocumentWriter {
        let context: CIContext
      
        nonisolated func write(
            content: sending ImageSnapshot, to destination: URL,
            previous: sending ImageSnapshot?, progress: consuming Subprogress
        ) async throws {
            guard let outputImage = content.image else { return }
            try context.writeJPEGRepresentation(
                of: outputImage, to: destination,
                colorSpace: outputImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            )
        }
    }

    func reader(
        configuration: sending DocumentReadConfiguration
    ) -> sending Reader { Reader() }

    func writer(
        configuration: sending DocumentWriteConfiguration
    ) -> sending Writer { Writer(context: context) }

    @MainActor
    func apply(snapshot: sending ImageSnapshot, previous: sending ImageSnapshot?) async throws {
        guard let ciImage = snapshot.image else { return }
        self.displayImage = context.createCGImage(ciImage, from: ciImage.extent)
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending ImageSnapshot {
        ImageSnapshot(image: displayImage.map { CIImage(cgImage: $0) })
    }
}
```

The `previous` parameter on the **custom** `write(…)` and `apply(…)` is the last successfully written / read snapshot. For packages, compare it to the new snapshot to skip unchanged files.

## Report progress with `Subprogress`

`read` and `write` receive `consuming Subprogress`. Call `start(totalCount:)` **once** to consume it and get a `ProgressManager`; call `complete(count:)` as units finish. `Subprogress` is `~Copyable`, so the compiler enforces single use; if never consumed, the assigned units auto-complete.

Pick a coarse `totalCount` (chunks or files) to drive `fractionCompleted`. For display, set `totalByteCount` / `completedByteCount` (`UInt64`) or `totalFileCount` / `completedFileCount` (`Int`) on the `ProgressManager`. Don't drive `complete(count:)` byte-by-byte.

```swift
struct MediaSnapshot { var payload: Data }

extension MediaDocument {
    struct Writer: DocumentWriter {
        nonisolated func write(
            content: sending MediaSnapshot, to destination: URL,
            previous: sending MediaSnapshot?, progress: consuming Subprogress
        ) async throws {
            let payload = content.payload
            let totalBytes = payload.count
            let chunkSize = 1 << 20                              // 1 MB
            let chunkCount = (totalBytes + chunkSize - 1) / chunkSize

            let progressManager = progress.start(totalCount: chunkCount)
            progressManager.totalByteCount = UInt64(totalBytes)

            try Data().write(to: destination)
            let fileHandle = try FileHandle(forWritingTo: destination)
            defer { try? fileHandle.close() }

            var offset = 0
            while offset < totalBytes {
                let end = min(offset + chunkSize, totalBytes)
                try fileHandle.write(contentsOf: payload[offset..<end])
                progressManager.completedByteCount += UInt64(end - offset)
                progressManager.complete(count: 1)
                offset = end
            }
        }
    }
}
```

> **Note:** The `FileWrapperDocumentReader` / `FileWrapperDocumentWriter` closures don't take a `Subprogress`; only **custom** readers/writers report progress. This is `ProgressManager`, not the old `Progress`. Training data may reach for `Progress(totalUnitCount:)` or a `reporter(totalCount:)` factory; neither is correct here.

## Coordinated disk access outside read/write

SwiftUI coordinates file access for `read` and `write` automatically. To touch the file URL at any other time (e.g. reading one sub-file of a package on a tap), gate the access with the configuration's file coordinator so other processes coordinating on the same URL can synchronize. `URLDocumentConfiguration.fileURL` is readable from any thread (it's `nonisolated(unsafe)`); the coordinator provides the read/write synchronization.

```swift
let coordinator = document.configuration.makeFileCoordinator()
var error: NSError?
coordinator.coordinate(
    readingItemAt: packageURL.appending(path: "metadata.json"),
    options: [], error: &error
) { url in
    // read/decode here; handle errors
}
```

`makeFileCoordinator()` is a lightweight factory; call it for **each** read/write to get a fresh `NSFileCoordinator`.

## iOS launch scene and multiple creation sources

```swift
@main
struct NotesApp: App {
    var body: some Scene {
        DocumentGroupLaunchScene("My Notes and Lists") {
            NewDocumentButton("New Note", source: .note)
            NewDocumentButton("New List", source: .list)
        } background: {
            LinearGradient(
                colors: [.brandStart, .brandEnd],
                startPoint: .top, endPoint: .bottom
            )
        }

        DocumentGroup { document in
            TextEditorView(document: document)
        } makeDocument: { configuration, context in
            TextDocument(configuration: configuration, context: context)
        }
    }
}

extension DocumentCreationSource {
    static let note = DocumentCreationSource(id: "note")
    static let list = DocumentCreationSource(id: "list")
}
```

Read `context.creationSource` in your initializer to set the document up accordingly.

## Export to a new location or format

Use `fileExporter` with a `WritableDocument`:

```swift
.fileExporter(
    isPresented: $isExporting, document: document,
    contentType: .utf8PlainText, defaultFilename: "Text"
) { result in
    switch result {
    case .success(let url): print("Exported to \(url)")
    case .failure(let error): print("Export failed: \(error)")
    }
}
```

## Concurrency contract (common agent pitfalls)

- **`reader(configuration:)` / `writer(configuration:)`** are synchronous factories. They return `sending` reader/writer values and run on the caller.
- **`read(from:progress:)` / `write(content:to:previous:progress:)`** are `nonisolated` and run **in the background**. Mark them `nonisolated` exactly as shown. Do all heavy I/O and serialization here.
- **`snapshot(contentType:)` / `apply(snapshot:previous:)`** are **`@MainActor`** and `async`. Keep them cheap.
- **`URLDocumentConfiguration` is `@MainActor @Observable` but `Sendable`,** with `fileURL` / `lastContentModificationDate` exposed as `nonisolated(unsafe)`. Inside `read` / `write`, prefer the `source: URL` / `destination: URL` parameter the framework hands you; that's the URL for *this* operation, while `configuration.fileURL` reflects current state and may have moved (Save As, rename) by the time you read it.
- Snapshots cross actor boundaries, hence the `sending` annotations. Either make the snapshot `Sendable`, or construct it fresh inside `snapshot(contentType:)` and don't retain it elsewhere.
- Keep snapshot types, reader types, and writer types at **internal** access (the default). Protocol-required methods expose these types in their signatures, so marking them `private` or `fileprivate` causes "must be declared fileprivate because its type uses a private type" compile errors.
- The `makeDocument` / `makeReadableDocument` closures are `async` and run on the main actor; `await` inside them to do off-main setup.

## Quick API reference

| Symbol | Role |
| --- | --- |
| `ReadableDocument` | Read-only document. `AnyObject`. Requires `readableContentTypes`, `reader(configuration:)`, `apply(snapshot:previous:)`. |
| `WritableDocument` | Adds saving (independent of `ReadableDocument`). Requires `writableContentTypes`, `writer(configuration:)`, `snapshot(contentType:)`. `AnyObject`. `DocumentGroup`'s read-write init requires `Document: ReadableDocument & WritableDocument`. |
| `DocumentReader` | `nonisolated func read(from:progress:) async throws -> sending Snapshot`. |
| `DocumentWriter` | `nonisolated func write(content:to:previous:progress:) async throws`. |
| `FileWrapperDocumentReader<Snapshot>` | Convenience reader (recommended); closure `(FileWrapper) async throws -> sending Snapshot`. |
| `FileWrapperDocumentWriter<Snapshot>` | Convenience writer (recommended); **single-argument** closure `(Snapshot) async throws -> FileWrapper`. No `previous` parameter; retain the prior `FileWrapper` yourself for incremental package writes. |
| `URLDocumentConfiguration` | `@MainActor @Observable`, `Sendable`. `fileURL: URL?` / `lastContentModificationDate: Date?` (both `nonisolated(unsafe)`); `makeFileCoordinator() -> NSFileCoordinator`; `creationSource: DocumentCreationSource?` (iOS/visionOS only). |
| `DocumentReadConfiguration` / `DocumentWriteConfiguration` | Value configs exposing `contentType: UTType`. |
| `DocumentCreationContext` | `creationSource: DocumentCreationSource?`: which `NewDocumentButton` created the document. |
| `Subprogress` (Foundation) | `~Copyable` progress currency for custom `read`/`write`. Consume once: `start(totalCount:) -> ProgressManager`. |
| `ProgressManager` (Foundation) | `complete(count:)` drives `fractionCompleted`. Auxiliary `totalByteCount`/`completedByteCount` (`UInt64`), `totalFileCount`/`completedFileCount` (`Int`). |
| `DocumentGroup` | Scene. `init(editor:makeDocument:)` (read-write) / `init(viewer:makeReadableDocument:)` (read-only). |
| `DocumentGroupLaunchScene` | iOS branded launch scene hosting `NewDocumentButton`s. |
| `View.fileExporter(isPresented:document:contentType:defaultFilename:onCompletion:)` | Export a `WritableDocument`. |
