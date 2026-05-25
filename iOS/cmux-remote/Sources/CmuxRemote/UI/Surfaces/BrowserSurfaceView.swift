import SwiftUI
import CmuxKit

/// Control panel for a remote browser surface.
///
/// The webview itself lives in cmux on the Mac; this view exposes the
/// `cmux browser` automation primitives — navigate, back/forward/reload,
/// screenshot capture, current URL, evaluate JavaScript — and surfaces them
/// as a remote dashboard.
struct BrowserSurfaceView: View {
    let surface: CmuxSurface
    let workspace: CmuxWorkspace?

    @EnvironmentObject var connection: ConnectionManager
    @State private var urlInput = ""
    @State private var currentURL: URL?
    @State private var screenshot: UIImage?
    @State private var lastError: String?

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider()
            if let screenshot {
                Image(uiImage: screenshot)
                    .resizable()
                    .scaledToFit()
                    .background(.regularMaterial)
            } else {
                ContentUnavailableView(
                    L10n.string("browser.screenshot.empty.title", defaultValue: "No screenshot yet"),
                    systemImage: "camera",
                    description: Text(L10n.string(
                        "browser.screenshot.empty.description",
                        defaultValue: "Tap the camera button to capture the current page."
                    ))
                )
                .frame(maxHeight: .infinity)
            }
            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        .task { await refreshURL() }
    }

    private var navBar: some View {
        HStack(spacing: 8) {
            Button { Task { await goBack() } } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(L10n.string("browser.action.back", defaultValue: "Back"))
            Button { Task { await goForward() } } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(L10n.string("browser.action.forward", defaultValue: "Forward"))
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(L10n.string("browser.action.reload", defaultValue: "Reload"))
            TextField(L10n.string("browser.url.placeholder", defaultValue: "URL"), text: $urlInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { Task { await navigate() } }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(.regularMaterial, in: Capsule())
            Button { Task { await captureScreenshot() } } label: { Image(systemName: "camera") }
                .accessibilityLabel(L10n.string("browser.action.capture_screenshot", defaultValue: "Capture screenshot"))
        }
        .padding(8)
    }

    private func refreshURL() async {
        guard let client = await connection.client(for: "browser.url") else { return }
        if let url = try? await client.browserURL(surfaceID: surface.id) {
            await MainActor.run {
                self.currentURL = url
                self.urlInput = url.absoluteString
                self.lastError = nil
            }
        }
    }

    private func navigate() async {
        guard let url = URL(string: urlInput) else {
            lastError = L10n.string("browser.error.invalid_url", defaultValue: "Invalid URL")
            return
        }
        guard let client = await connection.client(for: "browser.goto") else { return }
        do {
            _ = try await client.browserGoto(url, surfaceID: surface.id)
            lastError = nil
            await refreshURL()
        } catch { showBrowserActionError() }
    }

    private func goBack() async {
        guard let client = await connection.client(for: "browser.back") else { return }
        do { _ = try await client.browserBack(surfaceID: surface.id); lastError = nil; await refreshURL() }
        catch { showBrowserActionError() }
    }

    private func goForward() async {
        guard let client = await connection.client(for: "browser.forward") else { return }
        do { _ = try await client.browserForward(surfaceID: surface.id); lastError = nil; await refreshURL() }
        catch { showBrowserActionError() }
    }

    private func reload() async {
        guard let client = await connection.client(for: "browser.reload") else { return }
        do { _ = try await client.browserReload(surfaceID: surface.id); lastError = nil; await refreshURL() }
        catch { showBrowserActionError() }
    }

    private func captureScreenshot() async {
        guard let client = await connection.client(for: "browser.screenshot") else { return }
        do {
            let data = try await client.browserScreenshot(surfaceID: surface.id)
            await MainActor.run {
                self.screenshot = UIImage(data: data)
                self.lastError = nil
            }
        } catch { showBrowserActionError() }
    }

    private func showBrowserActionError() {
        lastError = L10n.string(
            "browser.error.action_failed",
            defaultValue: "Browser action failed."
        )
    }
}

struct MarkdownSurfaceView: View {
    let surface: CmuxSurface
    let workspace: CmuxWorkspace?

    var body: some View {
        VStack {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(surface.title ?? L10n.string("surface.markdown.default_title", defaultValue: "Markdown"))
                .font(.headline)
            Text(L10n.string(
                "surface.markdown.remote_only",
                defaultValue: "Markdown/file-preview surfaces render on the Mac. Open on the desktop to interact."
            ))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
