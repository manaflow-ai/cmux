from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_ended_listability_cache_does_not_call_the_filesystem_directly():
    source = (
        ROOT
        / "Sources/Mobile/AgentChat/AgentChatEndedTranscriptListabilityCache.swift"
    ).read_text()

    assert "resolver.boundedTranscriptPath" not in source


def test_bounded_transcript_resolution_uses_a_detached_utility_task():
    source = (
        ROOT / "Sources/Mobile/AgentChat/AgentChatTranscriptResolver.swift"
    ).read_text()
    start = source.index("func boundedTranscriptPath")
    end = source.index("private func recordedTranscriptPath", start)

    assert "Task.detached(priority: .utility)" in source[start:end]
