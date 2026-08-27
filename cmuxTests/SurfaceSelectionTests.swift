import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Surface selection", .serialized)
struct SurfaceSelectionTests {
    @Test func selectionValueTypesRejectInvalidPayloadStates() {
        #expect(SurfaceSelectionLineRange(start: 0, end: 1) == nil)
        #expect(SurfaceSelectionLineRange(start: 3, end: 2) == nil)
        #expect(SurfaceSelectionLineRange(start: 1, end: 1) != nil)

        let snapshot = SurfaceSelectionSnapshot.none(
            kind: .filePreview,
            filePath: "/tmp/example.swift"
        )
        #expect(!snapshot.hasSelection)
        #expect(snapshot.text.isEmpty)
        #expect(snapshot.lineRange == nil)

        let oversizedText = SurfaceSelectionSnapshot.boundedText(
            String(repeating: "x", count: SurfaceSelectionSnapshot.maximumTextBytes + 32)
        )
        #expect(oversizedText.utf8.count <= SurfaceSelectionSnapshot.maximumTextBytes)
        #expect(oversizedText.hasSuffix("…"))

        let oversizedUnicode = SurfaceSelectionSnapshot.boundedText(
            String(repeating: "😀", count: SurfaceSelectionSnapshot.maximumTextBytes / 4 + 32)
        )
        #expect(oversizedUnicode.utf8.count <= SurfaceSelectionSnapshot.maximumTextBytes)
        #expect(!oversizedUnicode.contains("\u{FFFD}"))
    }

    @Test func paneRoutingSelectsItsSurfaceAndFailsClosed() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: panelID)?.id)

        let resolved = try #require(workspace.controlRequestedSurfaceTarget(
            explicitSurfaceID: nil,
            routedPaneID: paneID
        ))
        #expect(resolved.requestedSurfaceID == panelID)
        #expect(resolved.target?.surfaceID == panelID)
        #expect(workspace.controlRequestedSurfaceTarget(
            explicitSurfaceID: nil,
            routedPaneID: UUID()
        ) == nil)
    }

    @Test func nativeSelectionMapsUTF16RangesToOneBasedSourceLines() async throws {
        let cases: [(source: String, selected: String, start: Int, end: Int)] = [
            ("alpha\nbeta\ngamma", "beta", 2, 2),
            ("alpha\r\nbeta\r\ngamma", "beta\r\ngamma", 2, 3),
            ("alpha\rbeta", "beta", 2, 2),
            ("alpha\u{0085}beta", "beta", 2, 2),
            ("alpha\u{2028}beta", "beta", 2, 2),
            ("zero\n😀 emoji\nlast\n", "😀 emoji\nlast\n", 2, 3),
        ]

        for testCase in cases {
            let textView = NSTextView(frame: .zero)
            textView.string = testCase.source
            let selectedRange = (testCase.source as NSString).range(of: testCase.selected)
            textView.setSelectedRange(selectedRange)

            let snapshot = await NativeTextSurfaceSelectionReader().read(
                textView: textView,
                kind: .filePreview,
                filePath: "/tmp/../tmp/example.swift"
            )

            #expect(snapshot.hasSelection)
            #expect(snapshot.text == testCase.selected)
            #expect(snapshot.filePath == "/tmp/example.swift")
            #expect(snapshot.lineRange?.start == testCase.start)
            #expect(snapshot.lineRange?.end == testCase.end)
        }
    }

    @Test func nativePanelsExposeTheSameSelectionShape() async throws {
        let source = "first\nselected 😀 text\nlast"
        let selectedRange = (source as NSString).range(of: "selected 😀 text")

        let fileTextView = NSTextView(frame: .zero)
        fileTextView.string = source
        fileTextView.setSelectedRange(selectedRange)
        let filePanel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: "/tmp/example.swift",
            startFileWatcher: false
        )
        filePanel.textView = fileTextView
        defer { filePanel.close() }

        let fileSnapshot = try snapshot(from: await filePanel.readSurfaceSelection())
        #expect(fileSnapshot.kind == .filePreview)
        #expect(fileSnapshot.text == "selected 😀 text")
        #expect(fileSnapshot.filePath == "/tmp/example.swift")
        #expect(fileSnapshot.lineRange == SurfaceSelectionLineRange(start: 2, end: 2))

        let markdownTextView = NSTextView(frame: .zero)
        markdownTextView.string = source
        markdownTextView.setSelectedRange(selectedRange)
        let markdownPanel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: "/tmp/example.md"
        )
        markdownPanel.setDisplayMode(.text)
        markdownPanel.attachTextView(markdownTextView)
        defer { markdownPanel.close() }

        let markdownSnapshot = try snapshot(from: await markdownPanel.readSurfaceSelection())
        #expect(markdownSnapshot.kind == .markdown)
        #expect(markdownSnapshot.text == "selected 😀 text")
        #expect(markdownSnapshot.filePath == "/tmp/example.md")
        #expect(markdownSnapshot.lineRange == SurfaceSelectionLineRange(start: 2, end: 2))
    }

    @Test func browserAndMarkdownPreviewReadLiveDOMSelection() async throws {
        let unloadedPanel = BrowserPanel(workspaceId: UUID())
        defer { unloadedPanel.close() }
        let unloadedSnapshot = try snapshot(from: await unloadedPanel.readSurfaceSelection())
        #expect(!unloadedSnapshot.hasSelection)
        #expect(unloadedSnapshot.kind == .browser)
        #expect(unloadedSnapshot.url == nil)

        let panel = BrowserPanel(workspaceId: UUID())
        let contentRect = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hostView = NSView(frame: contentRect)
        panel.webView.frame = hostView.bounds
        panel.webView.autoresizingMask = [.width, .height]
        hostView.addSubview(panel.webView)
        window.contentView = hostView
        window.orderFrontRegardless()
        window.displayIfNeeded()
        #expect(window.makeFirstResponder(panel.webView))
        defer {
            panel.close()
            window.orderOut(nil)
            window.close()
        }
        let baseURL = URL(fileURLWithPath: "/tmp/cmux-selection-test/document.html")
        let loader = SurfaceSelectionNavigationLoader()
        try await loader.load(
            """
            <!doctype html>
            <html><body>
              <p id="passage">before selected browser words after</p>
              <iframe id="same-origin-frame" srcdoc="<p id='frame-passage'>before selected frame words after</p>"></iframe>
              <textarea id="editor">before selected editable words after</textarea>
              <input id="password" type="password" value="top-secret">
            </body></html>
            """,
            baseURL: baseURL,
            in: panel.webView
        )

        let preparedBrowserSelection = try await panel.webView.callAsyncJavaScript(
            """
            return await new Promise((resolve) => {
              const node = document.getElementById('passage').firstChild;
              const start = node.textContent.indexOf('selected browser words');
              const range = document.createRange();
              range.setStart(node, start);
              range.setEnd(node, start + 'selected browser words'.length);
              const selection = window.getSelection();
              selection.removeAllRanges();
              document.addEventListener(
                'selectionchange',
                () => resolve(selection.toString()),
                { once: true, capture: true }
              );
              selection.addRange(range);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(preparedBrowserSelection as? String == "selected browser words")

        let browserFirstResponder = window.firstResponder
        let browserSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(browserSnapshot.kind == .browser)
        #expect(browserSnapshot.text == "selected browser words")
        #expect(browserSnapshot.url == baseURL.absoluteString)
        #expect(browserSnapshot.filePath == nil)
        #expect(browserSnapshot.lineRange == nil)
        #expect(window.firstResponder === browserFirstResponder)

        let markdownSnapshot = try snapshot(from: await WebSurfaceSelectionReader().read(
            webView: panel.webView,
            kind: .markdown,
            filePath: "/tmp/guide.md"
        ))
        #expect(markdownSnapshot.kind == .markdown)
        #expect(markdownSnapshot.text == "selected browser words")
        #expect(markdownSnapshot.filePath == "/tmp/guide.md")

        let neighboringSurface = SurfaceSelectionFirstResponderView(frame: .zero)
        hostView.addSubview(neighboringSurface)
        #expect(window.makeFirstResponder(neighboringSurface))
        let neighboringFirstResponder = window.firstResponder
        let retainedBrowserSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(retainedBrowserSnapshot.text == "selected browser words")
        #expect(window.firstResponder === neighboringFirstResponder)
        #expect(window.makeFirstResponder(panel.webView))

        let clearedBrowserSelection = try await panel.evaluateJavaScript(
            """
            (() => {
              document.getElementById('passage').dispatchEvent(
                new Event('pointerdown', { bubbles: true })
              );
              window.getSelection().removeAllRanges();
              document.dispatchEvent(new Event('selectionchange'));
              return window.getSelection().isCollapsed;
            })()
            """
        )
        #expect(clearedBrowserSelection as? Bool == true)
        let clearedBrowserSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(!clearedBrowserSnapshot.hasSelection)
        #expect(clearedBrowserSnapshot.text.isEmpty)

        let preparedFrameSelection = try await panel.webView.callAsyncJavaScript(
            """
            return await new Promise((resolve) => {
              window.getSelection().removeAllRanges();
              const frame = document.getElementById('same-origin-frame');
              const childWindow = frame.contentWindow;
              const node = childWindow.document.getElementById('frame-passage').firstChild;
              const start = node.textContent.indexOf('selected frame words');
              const range = childWindow.document.createRange();
              range.setStart(node, start);
              range.setEnd(node, start + 'selected frame words'.length);
              const selection = childWindow.getSelection();
              selection.removeAllRanges();
              childWindow.document.addEventListener(
                'selectionchange',
                () => {
                  childWindow.focus();
                  resolve(`${document.activeElement === frame}|${selection.toString()}`);
                },
                { once: true, capture: true }
              );
              selection.addRange(range);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(preparedFrameSelection as? String == "true|selected frame words")
        let frameSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(frameSnapshot.text == "selected frame words")

        let preparedEditableSelection = try await panel.webView.callAsyncJavaScript(
            """
            return await new Promise((resolve) => {
              const editor = document.getElementById('editor');
              const start = editor.value.indexOf('selected editable words');
              editor.focus();
              editor.addEventListener(
                'select',
                () => {
                  const selected = editor.value.slice(
                    editor.selectionStart,
                    editor.selectionEnd
                  );
                  resolve(`${document.activeElement === editor}|${selected}`);
                },
                { once: true, capture: true }
              );
              editor.setSelectionRange(start, start + 'selected editable words'.length);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(preparedEditableSelection as? String == "true|selected editable words")
        let editableSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(editableSnapshot.hasSelection)
        #expect(editableSnapshot.text == "selected editable words")

        _ = try await panel.evaluateJavaScript(
            """
            (() => {
              window.getSelection().removeAllRanges();
              const password = document.getElementById('password');
              password.focus();
              password.setSelectionRange(0, password.value.length);
              password.dispatchEvent(new Event('select', { bubbles: true }));
              return true;
            })()
            """
        )
        let bridgeRemainsImmutable = try await panel.evaluateJavaScript(
            """
            (() => {
              const runtime = globalThis.__cmuxSurfaceSelectionRuntime;
              const read = runtime?.read;
              try { runtime.read = () => ({ has_selection: true, text: 'leaked' }); } catch (_) {}
              try { globalThis.__cmuxSurfaceSelectionRuntime = { read }; } catch (_) {}
              return runtime?.read === read && globalThis.__cmuxSurfaceSelectionRuntime === runtime;
            })()
            """
        )
        #expect(bridgeRemainsImmutable as? Bool == true)
        let passwordSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(!passwordSnapshot.hasSelection)
        #expect(passwordSnapshot.text.isEmpty)
        #expect(passwordSnapshot.url == baseURL.absoluteString)

        let preparedNavigationSelection = try await panel.webView.callAsyncJavaScript(
            """
            return await new Promise((resolve) => {
              const node = document.getElementById('passage').firstChild;
              const selectedText = 'before selected browser words';
              const start = node.textContent.indexOf(selectedText);
              const range = document.createRange();
              range.setStart(node, start);
              range.setEnd(node, start + selectedText.length);
              const selection = window.getSelection();
              selection.removeAllRanges();
              document.addEventListener(
                'selectionchange',
                () => resolve(selection.toString()),
                { once: true, capture: true }
              );
              selection.addRange(range);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(preparedNavigationSelection as? String == "before selected browser words")

        _ = try await panel.evaluateJavaScript(
            """
            (() => {
              history.pushState({ cmuxSelectionTest: true }, '', '#selection-route');
              return location.href;
            })()
            """
        )
        let navigationSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(!navigationSnapshot.hasSelection)
        #expect(navigationSnapshot.text.isEmpty)

        _ = try await panel.evaluateJavaScript(
            "history.replaceState({}, '', '\(baseURL.absoluteString)')"
        )
        let preparedMutationSelection = try await panel.webView.callAsyncJavaScript(
            """
            return await new Promise((resolve) => {
              const node = document.getElementById('passage').firstChild;
              const selectedText = 'before selected browser words';
              const start = node.textContent.indexOf(selectedText);
              const range = document.createRange();
              range.setStart(node, start);
              range.setEnd(node, start + selectedText.length);
              const selection = window.getSelection();
              selection.removeAllRanges();
              document.addEventListener(
                'selectionchange',
                () => resolve(selection.toString()),
                { once: true, capture: true }
              );
              selection.addRange(range);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(preparedMutationSelection as? String == "before selected browser words")

        let unrelatedMutationObserved = try await panel.webView.callAsyncJavaScript(
            """
            return await new Promise((resolve) => {
              const observer = new MutationObserver(() => {
                observer.disconnect();
                resolve(true);
              });
              observer.observe(document.body, { childList: true, subtree: true });
              const status = document.createElement('span');
              status.textContent = 'unrelated page status';
              document.body.appendChild(status);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(unrelatedMutationObserved as? Bool == true)
        let retainedAfterUnrelatedMutation = try snapshot(from: await panel.readSurfaceSelection())
        #expect(retainedAfterUnrelatedMutation.hasSelection)
        #expect(retainedAfterUnrelatedMutation.text == "before selected browser words")

        let mutationObserved = try await panel.webView.callAsyncJavaScript(
            """
            return await new Promise((resolve) => {
              const passage = document.getElementById('passage');
              const observer = new MutationObserver(() => {
                observer.disconnect();
                resolve(true);
              });
              observer.observe(passage, { childList: true, characterData: true, subtree: true });
              passage.firstChild.nodeValue = 'after the document content changed';
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(mutationObserved as? Bool == true)
        let mutationSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(!mutationSnapshot.hasSelection)
        #expect(mutationSnapshot.text.isEmpty)

        let preparedProgrammaticClear = try await panel.webView.callAsyncJavaScript(
            """
            return await new Promise((resolve) => {
              const node = document.getElementById('passage').firstChild;
              node.nodeValue = 'before selected browser words';
              const selectedText = 'selected browser words';
              const start = node.textContent.indexOf(selectedText);
              const range = document.createRange();
              range.setStart(node, start);
              range.setEnd(node, start + selectedText.length);
              const selection = window.getSelection();
              selection.removeAllRanges();
              document.addEventListener(
                'selectionchange',
                () => resolve(selection.toString()),
                { once: true, capture: true }
              );
              selection.addRange(range);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(preparedProgrammaticClear as? String == "selected browser words")
        _ = try await panel.evaluateJavaScript(
            """
            (() => {
              window.getSelection().removeAllRanges();
              document.dispatchEvent(new Event('selectionchange'));
              return true;
            })()
            """
        )
        let programmaticClearSnapshot = try snapshot(from: await panel.readSurfaceSelection())
        #expect(!programmaticClearSnapshot.hasSelection)
        #expect(programmaticClearSnapshot.text.isEmpty)

        _ = try await panel.evaluateJavaScript("(() => { const nodes = Array.from({ length: 4100 }, () => document.createTextNode('x')); document.body.replaceChildren(...nodes); const range = document.createRange(); range.setStart(nodes[0], 0); range.setEnd(nodes[nodes.length - 1], 1); const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range); return true; })()")
        #expect(await panel.readSurfaceSelection() == .unavailable)
    }

    private func snapshot(
        from result: SurfaceSelectionReadResult
    ) throws -> SurfaceSelectionSnapshot {
        guard case .snapshot(let snapshot) = result else {
            throw SurfaceSelectionTestError.expectedSnapshot
        }
        return snapshot
    }
}

private final class SurfaceSelectionFirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
