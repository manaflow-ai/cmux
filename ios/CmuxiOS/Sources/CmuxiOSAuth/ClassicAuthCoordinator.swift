public import CmuxAuthRuntimeClassic

/// The classic app's auth coordinator: its frozen copy (``CmuxAuthRuntimeClassic``), not the shared
/// thin client of the Rust reducer, which this app does not link.
public typealias AuthCoordinator = CmuxAuthRuntimeClassic.AuthCoordinator
