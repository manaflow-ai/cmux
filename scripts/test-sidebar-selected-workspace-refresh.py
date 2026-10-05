#!/usr/bin/env python3
"""Execute the production Combine seam against willSet-style native publication."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="cmux-selected-workspace-") as directory:
    temporary = Path(directory)
    main = temporary / "main.swift"
    main.write_text('''import Combine
import Foundation
let first = UUID(), second = UUID(), third = UUID()
let publisher = CurrentValueSubject<UUID?, Never>(first)
var committed: UUID? = first
var observed: [UUID?] = []
let subscription = SidebarSelectedWorkspaceRefresh.events(from: publisher).sink { _ in
    observed.append(committed)
}
// TabManager intentionally preserves the legacy @Published willSet contract.
publisher.send(second)
committed = second
publisher.send(second)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
guard observed == [second] else {
    print("FAIL refresh read uncommitted native selection")
    exit(1)
}
observed = []
publisher.send(first)
committed = first
publisher.send(third)
committed = third
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
guard !observed.isEmpty, observed.allSatisfy({ $0 == third }) else {
    print("FAIL rapid changes restored an older highlight")
    exit(1)
}
print("PASS committed selection, duplicate suppression and latest native state")
withExtendedLifetime(subscription) {}
''')
    executable = temporary / "selection"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6",
                    str(root / "Sources/SidebarSelectedWorkspaceRefresh.swift"), str(main), "-o", str(executable)],
                   check=True, timeout=120)
    raise SystemExit(subprocess.run([str(executable)], timeout=180).returncode)
