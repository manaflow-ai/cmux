from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PRESENCE_HEARTBEAT_CLIENT = ROOT / "Sources" / "Cloud" / "PresenceHeartbeatClient.swift"


def test_presence_identity_capture_runs_beyond_the_main_actor_boundary() -> None:
    source = PRESENCE_HEARTBEAT_CLIENT.read_text(encoding="utf-8")
    send_heartbeat = source.split("private func sendHeartbeat(stopping: Bool) async {", 1)[1]
    send_heartbeat = send_heartbeat.split("\n    /// Build the heartbeat JSON body.", 1)[0]

    assert "encodedCurrentHeartbeatBody(" in send_heartbeat
    assert "MobileHostIdentity.deviceID()" not in send_heartbeat
    assert "MobileHostIdentity.instanceTag()" not in send_heartbeat
    assert "MobileHostIdentity.instanceDisplayName()" not in send_heartbeat

    detached_encoder = source.split("nonisolated static func encodedCurrentHeartbeatBody(", 1)[1]
    detached_encoder = detached_encoder.split("\n    }", 1)[0]
    detached_boundary = detached_encoder.index("Task.detached")

    assert detached_encoder.index("MobileHostIdentity.deviceID()") > detached_boundary
    assert detached_encoder.index("MobileHostIdentity.instanceTag()") > detached_boundary
    assert detached_encoder.index("MobileHostIdentity.instanceDisplayName()") > detached_boundary
