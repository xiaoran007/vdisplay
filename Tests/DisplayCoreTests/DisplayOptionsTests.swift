import Foundation
import XCTest
@testable import DisplayCore

final class DisplayOptionsTests: XCTestCase {
    func testPresetsAndOverrides() throws {
        XCTAssertEqual(Set(DisplayPreset.all.map(\.id)).count, DisplayPreset.all.count)
        for preset in DisplayPreset.all {
            let config = try DisplayOptions.resolve([preset.id])
            XCTAssertEqual(config.width, preset.width)
            XCTAssertEqual(config.height, preset.height)
            XCTAssertEqual(config.scale, preset.scale)
        }
        let config = try DisplayOptions.resolve(["4k-hidpi", "--name", "Remote", "--size", "2560x1440"])
        XCTAssertEqual(config, try DisplayConfiguration(name: "Remote", width: 2560, height: 1440, scale: 2, refresh: 60))
        XCTAssertEqual(try Command.parse(["presets", "--json"]), .presets(json: true))
        XCTAssertEqual(try Command.parse(["presets"]), .presets(json: false))
        XCTAssertThrowsError(try Command.parse(["presets", "extra"]))
    }

    func testConfigurationDefaultsAndProfileExpansion() throws {
        let reader: DisplayOptions.FileReader = { path in
            XCTAssertEqual(path, "display.json")
            return Data(#"{"width":3840,"height":2160,"scale":2}"#.utf8)
        }
        let config = try DisplayOptions.resolve(["--config", "display.json", "--name", "Remote"], readFile: reader)
        XCTAssertEqual(config, try DisplayConfiguration(name: "Remote", width: 3840, height: 2160, scale: 2, refresh: 60))
        XCTAssertEqual(try Command.parse(["profile", "add", "remote", "--config", "display.json", "--name", "Remote"], readFile: reader), .profile(.add("remote", config)))
        XCTAssertEqual(try Command.parse(["profile", "add", "remote", "1080p"]), .profile(.add("remote", try DisplayOptions.resolve(["1080p"]))))
        let defaults = try DisplayOptions.resolve(["--config", "display.json"], readFile: { _ in Data(#"{"width":1920,"height":1080}"#.utf8) })
        XCTAssertEqual(defaults.name, "vdisplay")
        XCTAssertEqual(defaults.scale, 1)
        XCTAssertEqual(defaults.refresh, 60)
    }

    func testInvalidSizesAndConflictingSources() {
        for size in ["0x1080", "1920", "1920X1080", "x1080", "1920x", "1x2x3", "-1x1080", "4294967296x1080"] {
            XCTAssertThrowsError(try DisplayOptions.resolve(["--size", size]), size)
        }
        for args in [["missing"], ["1080p", "--config", "file"], ["--size", "1920x1080", "--width", "1920"],
                     ["--size", "1920x1080", "--height", "1080"], ["--size", "1920x1080", "--size", "1280x720"],
                     ["--config"], ["1080p", "extra"]] {
            XCTAssertThrowsError(try DisplayOptions.resolve(args), "\(args)")
        }
    }

    func testInvalidFilesAreRejectedBeforeOverrides() {
        let files = ["not json", "[]", "{}", #"{"width":1920,"height":1080,"scle":2}"#,
                     #"{"width":1920,"height":1080,"name":null}"#, #"{"width":"1920","height":1080}"#,
                     #"{"width":1920,"height":1080,"scale":3}"#, #"{"width":1920,"height":1080,"refresh":120}"#]
        for file in files {
            XCTAssertThrowsError(try DisplayOptions.resolve(["--config", "file", "--scale", "1", "--refresh", "60"], readFile: { _ in Data(file.utf8) }), file)
        }
        XCTAssertThrowsError(try DisplayOptions.resolve(["--config", "/nonexistent/vdisplay-test.json"])) { error in
            XCTAssertEqual((error as? CLIError)?.exitCode, 2)
            XCTAssertTrue(String(describing: error).contains("Cannot load display configuration"))
        }
    }
}
