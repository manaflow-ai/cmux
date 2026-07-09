import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalTranscriptImagePathScannerTests {
    private let scanner = TerminalTranscriptImagePathScanner()

    @Test
    func detectsRequiredTranscriptPathForms() {
        let rows = [
            "⎿  Read(/tmp/km-mobile.png)",
            "Read image (123.1KB)",
            "Wrote \"/Users/x/My Shots/screen.jpeg\"",
            "open ~/Desktop/plot.webp,",
            "saved to /tmp/a.PNG.",
            "/tmp/x.txt /tmp/y.svg",
        ]

        let matches = scanner.scan(
            rows: rows,
            context: .init(homeDirectory: "/Users/tester")
        )

        #expect(matches.map(\.rowIndex) == [0, 2, 3, 4])
        #expect(matches.map(\.path) == [
            "/tmp/km-mobile.png",
            "/Users/x/My Shots/screen.jpeg",
            "~/Desktop/plot.webp",
            "/tmp/a.PNG",
        ])
        #expect(matches[2].resolvedPath == "/Users/tester/Desktop/plot.webp")
    }

    @Test
    func supportsMultiplePathsAndImageExtensions() {
        let matches = scanner.scan(rows: [
            "compare /tmp/a.gif /tmp/b.HEIC /tmp/c.jpg /tmp/d.JPEG /tmp/e.webp /tmp/f.png"
        ])

        #expect(matches.map(\.path) == [
            "/tmp/a.gif",
            "/tmp/b.HEIC",
            "/tmp/c.jpg",
            "/tmp/d.JPEG",
            "/tmp/e.webp",
            "/tmp/f.png",
        ])
    }

    @Test
    func deduplicatesSamePathWithinRow() {
        let matches = scanner.scan(rows: [
            "Read(/tmp/a.png) then opened [/tmp/a.png],"
        ])

        #expect(matches.map(\.path) == ["/tmp/a.png"])
    }

    @Test
    func unquotedSpaceContainingPathDoesNotReturnHalfWord() {
        let matches = scanner.scan(rows: [
            "Wrote /Users/x/My Shots/screen.jpeg"
        ])

        #expect(matches.isEmpty)
    }

    @Test
    func resolvesRelativePathsOnlyWhenCwdIsProvided() {
        let withoutCwd = scanner.scan(rows: ["saved plots/graph.png"])
        let withCwd = scanner.scan(rows: ["saved plots/graph.png"], context: .init(cwd: "/work"))

        #expect(withoutCwd.isEmpty)
        #expect(withCwd.map(\.path) == ["plots/graph.png"])
        #expect(withCwd.map(\.resolvedPath) == ["/work/plots/graph.png"])
    }
}
