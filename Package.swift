// swift-tools-version:5.9
import PackageDescription

// The app is a single executable module; build.sh wraps the release binary into
// LocalShift.app together with Resources/ and the bundled runtimes.
let package = Package(
    name: "LocalShift",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LocalShift",
            path: "Sources",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        // Fast, runtime-free checks that run in CI. Conversion and UI acceptance
        // that needs FFmpeg/LibreOffice/Pages lives in Tests/Acceptance.
        .testTarget(
            name: "LocalShiftTests",
            dependencies: ["LocalShift"],
            path: "Tests/Unit"
        ),
    ]
)
