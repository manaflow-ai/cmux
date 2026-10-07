import Foundation

/// An owner event that does not fit the mirror (for example a tab upsert
/// into an unknown workspace): treated as a gap, repaired by a snapshot.
struct MirrorInconsistency: Error {}
