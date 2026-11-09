// swift-tools-version:5.9
import PackageDescription

// Tests are a plain executable because XCTest isn't available with Command Line Tools alone.
let package = Package(
    name: "textstop",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TextStopCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "textstop", dependencies: ["TextStopCore"]),
        .executableTarget(name: "textstop-tests", dependencies: ["TextStopCore"]),
    ]
)
