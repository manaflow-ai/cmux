#!/usr/bin/env python3
"""Run the real hook-delivery process with a child that records its auth scope."""
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="cmux-hook-capability-") as temporary:
        root = Path(temporary)
        # Only the event's input data is stubbed; the production process owns
        # environment construction, child launch and completion in this test.
        harness = root / "Probe.swift"
        harness.write_text('''
import Foundation

struct AgentHookDeliveryEvent: Sendable {
    let payload = "{}"
    let socketPath = "/tmp/fixture.sock"
    let deliveryArguments: [String] = []
    let isBestEffortTelemetry = false
    let queueAdmissionInstant: ContinuousClock.Instant? = nil
    let environment: [String: String] = [:]
    let relayBacked: Bool
}

@main struct Probe {
    static func main() async {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let process = AgentHookDeliveryProcess(
            executableURLProvider: { executable },
            socketClientCapability: "fixture-local-capability"
        )
        await process.deliver(AgentHookDeliveryEvent(
            relayBacked: CommandLine.arguments[2] == "relay"
        ))
    }
}
''')
        child = root / "capture-auth"
        child.write_text(
            "#!/usr/bin/python3\n"
            "import json, os, pathlib, sys\n"
            "sys.stdin.read()\n"
            "pathlib.Path(__file__ + '.json').write_text(json.dumps({\n"
            "    'capability': os.environ.get('CMUX_SOCKET_CAPABILITY'),\n"
            "    'relay_origin': os.environ.get('CMUX_AGENT_HOOK_RELAY_ORIGIN')\n"
            "}))\n"
        )
        child.chmod(0o755)
        binary = root / "probe"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            str(ROOT / "Sources/AgentHookDeliveryProcess.swift"), str(harness),
            "-module-cache-path", str(root / "modules"), "-o", str(binary)
        ], check=True, timeout=120)
        for mode in ("local", "relay"):
            subprocess.run([str(binary), str(child), mode], check=True, timeout=10)
            observed = json.loads(Path(str(child) + ".json").read_text())
            expected = "fixture-local-capability" if mode == "local" else None
            assert observed["capability"] == expected, (
                f"{mode} hook worker has the wrong socket authorization: {observed}"
            )
            assert observed["relay_origin"] == ("1" if mode == "relay" else None), observed
            print(f"PASS {mode} hook worker socket authorization")


if __name__ == "__main__":
    main()
