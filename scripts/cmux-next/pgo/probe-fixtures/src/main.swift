// Probe program: launchOnly runs before the flush, restOnly after it.
@inline(never) func launchOnly(_ n: Int) -> Int {
    var sum = 0
    for i in 0..<n {
        if i % 7 == 0 { sum &+= i } else { sum &-= 1 }
    }
    return sum
}

@inline(never) func restOnly(_ n: Int) -> Int {
    var sum = 1
    for i in 0..<n where i % 3 == 0 { sum = sum &* 31 &+ i }
    return sum
}

var sink = launchOnly(1000)
#if CMUX_PGO_PROBE_FLUSH
// launch.profraw at the startup mark, then counters start again; rest.profraw before quit.
let files = CommandLine.arguments.dropFirst()
precondition(files.count == 2, "usage: probe LAUNCH.profraw REST.profraw")
files.first!.withCString { __llvm_profile_set_filename($0) }
precondition(__llvm_profile_write_file() == 0, "launch write failed")
__llvm_profile_reset_counters()
sink &+= restOnly(1000)
files.last!.withCString { __llvm_profile_set_filename($0) }
precondition(__llvm_profile_write_file() == 0, "rest write failed")
#else
sink &+= restOnly(1000)
#endif
print(sink)
