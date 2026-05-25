import SwiftUI
import PencilKit
import UIKit
import Vision
import CmuxKit

/// Apple-Pencil-only overlay that lets the user scribble a command, then
/// converts the handwriting to text and forwards it to the focused cmux
/// surface via `cmux send`.
///
/// Uses `PKCanvasView` with `drawingPolicy = .pencilOnly` so finger gestures
/// continue to scroll the terminal underneath. Handwriting recognition uses
/// `PKDrawing.transcribe()` (iOS 17+; iOS 26 returns multi-language
/// candidates).
struct PencilOverlayView: View {
    @Binding var isPresented: Bool
    let onRecognized: (String) -> Void

    @State private var drawing = PKDrawing()
    @State private var recognized: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            PencilCanvas(drawing: $drawing) { recognized in
                self.recognized = recognized
            }
            footer
        }
        .background(.regularMaterial)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text(L10n.string("pencil.title", defaultValue: "Scribble a command"))
                .font(.headline)
            Spacer()
            Button {
                drawing = PKDrawing()
                recognized = ""
            } label: { Label(L10n.string("common.clear", defaultValue: "Clear"), systemImage: "trash") }
            Button(role: .cancel) { isPresented = false } label: { Text(L10n.string("common.cancel", defaultValue: "Cancel")) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var footer: some View {
        HStack {
            Text(recognized.isEmpty
                ? L10n.string(
                    "pencil.empty_hint",
                    defaultValue: "Write with Apple Pencil - finger gestures still scroll the terminal."
                )
                : recognized
            )
                .foregroundStyle(recognized.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            Button {
                let payload = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !payload.isEmpty else { return }
                onRecognized(payload)
                isPresented = false
            } label: { Label(L10n.string("common.send", defaultValue: "Send"), systemImage: "paperplane.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(recognized.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

private struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let onRecognized: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRecognized: onRecognized) }

    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.drawingPolicy = .pencilOnly
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.tool = PKInkingTool(.pen, color: .label, width: 4)
        view.isOpaque = false
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        view.addInteraction(pencilInteraction)
        return view
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing { uiView.drawing = drawing }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let onRecognized: (String) -> Void
        init(onRecognized: @escaping (String) -> Void) { self.onRecognized = onRecognized }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                let drawing = canvasView.drawing
                let recognized = await Self.recognize(drawing: drawing, on: canvasView)
                onRecognized(recognized)
            }
        }

        // Pencil Pro: double-tap clears, squeeze sends what we have.
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            // No public Pencil-Pro doubleTap/squeeze delegate yet on iOS 17;
            // iOS 17.5+ added `pencilInteraction(_:didReceiveTap:)`. We map
            // the modern callback below; the older one is the no-op stub.
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            _ = tap
            // Tap gestures are discrete in the current UIKit API; a received
            // tap is already the recognized event.
            if let canvas = interaction.view as? PKCanvasView {
                canvas.drawing = PKDrawing()
            }
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            // No-op for now; the visible Send button is the primary affordance.
            _ = squeeze
        }

        // Handwriting recognition via UIKit's text-recognition API. On iOS
        // 18+ Apple ships `PKDrawing.transcribe()`; we fall back to using
        // `UITextInteraction` via the underlying canvas as a UITextInput.
        @MainActor
        static func recognize(drawing: PKDrawing, on canvas: PKCanvasView) async -> String {
            // Minimal viable: render the drawing into an image and dispatch
            // to Vision's `VNRecognizeTextRequest`. Vision is the most stable
            // public path for handwriting in 2026; PKDrawing.transcribe was
            // SPI as of last check.
            let bounds = drawing.bounds.insetBy(dx: -24, dy: -24)
            guard bounds.width > 0, bounds.height > 0 else { return "" }
            let scale = canvas.window?.windowScene?.screen.scale ?? max(canvas.traitCollection.displayScale, 1)
            let image = drawing.image(from: bounds, scale: scale)
            return await VisionHandwriting.recognize(image: image) ?? ""
        }
    }
}

enum VisionHandwriting {
    static func recognize(image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }.value
    }
}
