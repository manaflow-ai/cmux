import SwiftUI
import UIKit

struct DebugLogsView: View {
    @State private var logs: String = DebugLog.read()
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if logs.isEmpty {
                Text("No logs yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(logs)
                        .font(.caption2)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if didCopy {
                Text("Copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Debug Logs")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Clear") {
                    DebugLog.clear()
                    logs = DebugLog.read()
                    didCopy = false
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Reload") {
                    logs = DebugLog.read()
                    didCopy = false
                }
                Button("Copy") {
                    UIPasteboard.general.string = logs
                    didCopy = true
                }
                .disabled(logs.isEmpty)
            }
        }
        .onAppear {
            logs = DebugLog.read()
            didCopy = false
        }
    }
}

#Preview {
    NavigationStack {
        DebugLogsView()
    }
}
