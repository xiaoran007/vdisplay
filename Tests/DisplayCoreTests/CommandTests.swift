import XCTest
@testable import DisplayCore

final class CommandTests: XCTestCase {
    func testHelpAndReadOnlyCommands() throws {
        XCTAssertEqual(try Command.parse([]), .help)
        XCTAssertEqual(try Command.parse(["--help"]), .help)
        XCTAssertEqual(try Command.parse(["list"]), .list(json: false))
        XCTAssertEqual(try Command.parse(["list", "--json"]), .list(json: true))
        XCTAssertEqual(try Command.parse(["doctor"]), .doctor)
    }

    func testRunDefaultsAndOutputPixelSemantics() throws {
        let command = try Command.parse(["run", "--width", "3840", "--height", "2160", "--scale", "2"])
        guard case .run(let config) = command else { return XCTFail("Expected run") }
        XCTAssertEqual(config.width, 3840)
        XCTAssertEqual(config.height, 2160)
        XCTAssertEqual(config.scale, 2)
        XCTAssertEqual(config.refresh, 60)
        XCTAssertEqual(config.name, "vdisplay")
        XCTAssertTrue(DisplayMode(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840,
                                  pixelHeight: 2160, refreshRate: 60).matches(config))
        XCTAssertFalse(DisplayMode(logicalWidth: 3840, logicalHeight: 2160, pixelWidth: 3840,
                                   pixelHeight: 2160, refreshRate: 60).matches(config))
    }

    func testInvalidCommandsAndMalformedOptions() {
        let cases = [
            ["unknown"], ["doctor", "--json"], ["list", "--json", "--json"], ["help", "run"],
            ["run"], ["run", "--width"], ["run", "--width", "--height", "1080"],
            ["run", "--width", "1920", "--height", "1080", "--width", "1280"],
            ["run", "--width", "1920", "--height", "1080", "--unknown", "value"]
        ]
        for arguments in cases {
            XCTAssertThrowsError(try Command.parse(arguments), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2)
            }
        }
    }

    func testRejectInvalidDimensions() {
        for width in ["0", "-1", "+1", "1.5", "4294967296", "", "abc", " 1920"] {
            XCTAssertThrowsError(try Command.parse(["run", "--width", width, "--height", "1080"]))
        }
        XCTAssertThrowsError(try Command.parse(["run", "--width", "1921", "--height", "1080", "--scale", "2"]))
        XCTAssertThrowsError(try Command.parse(["run", "--width", "1920", "--height", "1081", "--scale", "2"]))
    }

    func testRejectUnsupportedScaleRefreshAndNames() {
        let base = ["run", "--width", "1920", "--height", "1080"]
        for scale in ["0", "3", "-2"] { XCTAssertThrowsError(try Command.parse(base + ["--scale", scale])) }
        for rate in ["nan", "inf", "0", "-60", "120", "abc"] {
            XCTAssertThrowsError(try Command.parse(base + ["--refresh", rate]))
        }
        for name in ["", "   ", "bad\nname", "bad\0name"] {
            XCTAssertThrowsError(try Command.parse(base + ["--name", name]))
        }
    }

    func testModeReadbackRejectsWrongPixelsAndUnknownRate() throws {
        let config = try DisplayConfiguration(name: "Remote", width: 1920, height: 1080, scale: 1, refresh: 60)
        for rate in [0.0, 30, 120, .nan, .infinity] {
            XCTAssertFalse(DisplayMode(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 1920,
                                       pixelHeight: 1080, refreshRate: rate).matches(config))
        }
        XCTAssertFalse(DisplayMode(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840,
                                   pixelHeight: 2160, refreshRate: 60).matches(config))
        XCTAssertTrue(DisplayMode(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 1920,
                                  pixelHeight: 1080, refreshRate: 59.94).matches(config))
    }
}
