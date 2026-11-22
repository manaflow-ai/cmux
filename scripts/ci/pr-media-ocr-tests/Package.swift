// swift-tools-version: 6.0
// Tests of scripts/ci/pr_media_ocr.swift, the text reader of the pr-media privacy gate and of the journeys'
// frame checks. They need Vision on macOS 27 (macOS 26 reads their frames whole either way); a fleet step runs them:
//   cmux-ci run --class light --script scripts/ci/run-swift-testing-suites.sh --arg scripts/ci/pr-media-ocr-tests \
//     --label macos-27 --env CMUX_SWIFT_TEST_SUITE_JOBS=1 --ref SHA
// No CI lane selects this package; whoever changes the reader runs it.
import PackageDescription

let package = Package(
    name: "PRMediaOCRTests",
    platforms: [.macOS(.v14)],
    targets: [
        .testTarget(name: "PRMediaOCRTests", exclude: ["Frames"]),
    ]
)
