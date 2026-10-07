import Foundation

/// The canned repository the mock source serves: a few folders, a Swift
/// file, a README with tasks, a table and code, notes, an image and a PDF.
struct MockViewerFiles: Sendable {
    let contents: [String: Data]

    init() {
        var files: [String: Data] = [:]
        files["README.md"] = Data(Self.readme.utf8)
        files["Sources/App/Viewer.swift"] = Data(Self.swift.utf8)
        files["Sources/App/DiffRow.swift"] = Data("/// One row of a diff.\nenum DiffRow {\n    case hunk(Int)\n    case line(String)\n}\n".utf8)
        files["Package.swift"] = Data("// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"App\")\n".utf8)
        files["docs/notes.txt"] = Data("Plain notes.\nSecond line.\n".utf8)
        files["docs/config.json"] = Data("{\n  \"name\": \"cmux\",\n  \"split\": true,\n  \"width\": 120\n}\n".utf8)
        files["assets/dot.png"] = Data(base64Encoded: Self.png) ?? Data()
        files["docs/guide.pdf"] = Data(Self.pdf.utf8)
        contents = files
    }

    /// Entries directly under a repository-relative folder ("" is the top).
    func entries(in folder: String) -> [(name: String, isDirectory: Bool, size: Int)] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var seen: [String: (Bool, Int)] = [:]
        for (path, data) in contents where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                seen[String(rest[..<slash])] = (true, 0)
            } else {
                seen[String(rest)] = (false, data.count)
            }
        }
        return seen.keys.sorted().map { (name: $0, isDirectory: seen[$0]!.0, size: seen[$0]!.1) }
    }

    static let readme = """
    # cmux viewer demo

    Changes, files and documents from your Mac, on the phone.

    ## Tasks

    - [x] Parse unified diffs
    - [x] Split layout on wide screens
    - [ ] Stream git changes live
      - [ ] Needs a daemon event

    ## Layouts

    | Layout | Width | Default |
    | :----- | :---: | ------: |
    | Unified | compact | yes |
    | Split | regular | no |

    > Viewers are read only. Edit on the Mac.

    ```swift
    let rows = DiffRows(document, layout: .split)
    print(rows.hunkRows)
    ```

    1. Open a workspace
    2. Tap **Changes**
    3. Jump between hunks with `[` and `]`

    ---

    See [the plan](docs/notes.txt) for details.
    """

    static let swift = """
    import UIKit

    /// Shows a diff, one row per line.
    final class Viewer {
        let mode = "split"
        var hunks = 2

        /* A block comment
           across two lines. */
        func render(_ lines: [String]) -> Int {
            lines.count + hunks // rows
        }
    }

    """

    /// A 4x4 gray PNG.
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAAAAACMmsGiAAAAEklEQVR4nGNkYGBgYGBgYGAAAAANAAEDuxoNAAAAAElFTkSuQmCC"

    static let pdf = """
    %PDF-1.4
    1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
    4 0 obj << /Length 52 >> stream
    BT /F1 18 Tf 40 100 Td (cmux viewer guide) Tj ET
    endstream endobj
    5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
    trailer << /Root 1 0 R >>
    %%EOF
    """
}
