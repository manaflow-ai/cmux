import AppKit

// One variant per launch. Accessory policy, never activates, never takes
// key; see AppDelegate.
let arguments: LaunchArguments
switch LaunchArguments.parse(CommandLine.arguments) {
case .success(let parsed):
    arguments = parsed
case .failure(let error):
    FileHandle.standardError.write(Data("\(error.message)\n\(UsageError.usage)\n".utf8))
    exit(64)
}

if arguments.listOnly {
    FileHandle.standardOutput.write(Data((Variant.allCases.map(\.rawValue).joined(separator: "\n") + "\n").utf8))
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate(arguments: arguments)
application.delegate = delegate
application.run()
