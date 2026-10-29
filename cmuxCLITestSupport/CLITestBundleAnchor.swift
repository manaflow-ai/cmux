import Foundation

/// A class whose only job is to name the test bundle it was compiled into.
///
/// `Bundle(for:)` needs a class from the bundle being located, and the helpers
/// in this directory compile into both `cmuxTests` and `cmuxCLITests`. Naming a
/// suite from either bundle would tie them to one of the two, so they name this
/// instead and resolve whichever bundle is running them.
final class CLITestBundleAnchor: NSObject {}
