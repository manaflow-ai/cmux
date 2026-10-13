import CmuxWireGuardPairing
import SwiftUI
import UIKit

/// "Pair manually": the code the Mac shows under its QR code, typed into
/// 4 + 4 boxes. Works when the phone is on the Mac's network.
struct CodeEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var symbols: [Character] {
        Array(text.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
            }
            Text("Pair manually")
                .font(.title2.weight(.semibold))
                .padding(.top, 14)
            Text("Enter the code shown on your Mac, under the QR code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            ZStack {
                TextField("", text: $text)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($focused)
                    .opacity(0.02)
                    .onChange(of: text) { _, new in
                        let cleaned = String(new.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                        if cleaned != new { text = cleaned }
                    }
                HStack(spacing: 8) {
                    ForEach(0..<8, id: \.self) { index in
                        if index == 4 {
                            Text("-").foregroundStyle(.secondary)
                        }
                        CodeBox(symbol: index < symbols.count ? symbols[index] : nil,
                                active: focused && index == min(symbols.count, 7))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            }
            .padding(.top, 22)

            Button {
                guard let code = PairingCode(text) else { return }
                dismiss()
                model.pair(code: code)
            } label: {
                Text("Pair")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(PairingCode(text) == nil ? Color.white.opacity(0.35) : .white))
            }
            .buttonStyle(.plain)
            .disabled(PairingCode(text) == nil)
            .padding(.top, 22)

            Button("Paste a pairing link instead") {
                guard let link = UIPasteboard.general.string else { return }
                dismiss()
                model.pair(link: link)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            Spacer()
        }
        .padding(24)
        .onAppear { focused = true }
    }
}

private struct CodeBox: View {
    let symbol: Character?
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(active ? 0.7 : 0), lineWidth: 1.5)
            )
            .overlay(Text(symbol.map(String.init) ?? "").font(.system(size: 22, weight: .semibold, design: .monospaced)))
            .frame(height: 52)
            .frame(maxWidth: .infinity)
    }
}
