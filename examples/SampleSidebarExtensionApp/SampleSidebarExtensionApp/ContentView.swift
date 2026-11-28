//
//  ContentView.swift
//  SampleSidebarExtensionApp
//
//  Created by Abdulaziz Albahar on 5/29/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(String(localized: "sampleSidebarApp.title", defaultValue: "CMUX Sample Sidebar Extension"))
                .font(.title2.weight(.semibold))
            Text(String(
                localized: "sampleSidebarApp.detail",
                defaultValue: "Keep this app installed. In cmux, open Sidebar Extensions, enable CMUX Sample Sidebar Extension, choose it from the sidebar picker, and confirm Workspace Signals shows your real workspaces."
            ))
            .foregroundStyle(.secondary)
            Text(String(
                localized: "sampleSidebarApp.identifier",
                defaultValue: "Extension ID: co.manaflow.CMUXExtKitSampleSidebarApp.Extension"
            ))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            Text(String(
                localized: "sampleSidebarApp.scopes",
                defaultValue: "Requests workspace and surface metadata, plus navigation, selection, and create-surface actions for the sidebar controls."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
