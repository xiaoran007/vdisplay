import Foundation

public struct DisplayPreset: Encodable, Equatable {
    public let id: String
    public let width: UInt32
    public let height: UInt32
    public let scale: UInt32
    public let refresh: Double

    public static let all: [DisplayPreset] = [
        DisplayPreset(id: "1080p", width: 1920, height: 1080, scale: 1, refresh: 60),
        DisplayPreset(id: "1440p", width: 2560, height: 1440, scale: 1, refresh: 60),
        DisplayPreset(id: "4k", width: 3840, height: 2160, scale: 1, refresh: 60),
        DisplayPreset(id: "4k-hidpi", width: 3840, height: 2160, scale: 2, refresh: 60),
        DisplayPreset(id: "ultrawide", width: 3440, height: 1440, scale: 1, refresh: 60),
        DisplayPreset(id: "portrait", width: 1080, height: 1920, scale: 1, refresh: 60)
    ]
}

public enum DisplayOptions {
    public typealias FileReader = (String) throws -> Data
    public static func readFile(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private struct FileConfiguration: Decodable {
        let configuration: DisplayConfiguration
        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Key.self)
            let allowed: Set<String> = ["name", "width", "height", "scale", "refresh"]
            let unknown = keys.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
            guard unknown.isEmpty else { throw CLIError("Unknown configuration fields: \(unknown.joined(separator: ", "))") }
            let values = try decoder.container(keyedBy: Fields.self)
            // Missing optional fields use documented defaults; null is invalid.
            func optional<T: Decodable>(_ type: T.Type, _ key: Fields, _ value: T) throws -> T {
                values.contains(key) ? try values.decode(type, forKey: key) : value
            }
            configuration = try DisplayConfiguration(
                name: optional(String.self, .name, "vdisplay"),
                width: values.decode(UInt32.self, forKey: .width), height: values.decode(UInt32.self, forKey: .height),
                scale: optional(UInt32.self, .scale, 1), refresh: optional(Double.self, .refresh, 60))
        }
        enum Fields: String, CodingKey { case name, width, height, scale, refresh }
    }

    public static func resolve(_ arguments: [String], readFile: FileReader = DisplayOptions.readFile) throws -> DisplayConfiguration {
        var tail = arguments
        var preset: DisplayPreset?
        if let first = tail.first, !first.hasPrefix("-") {
            guard let found = DisplayPreset.all.first(where: { $0.id == first }) else {
                throw CLIError("Unknown preset: \(first). Use vdisplay presets.")
            }
            preset = found
            tail.removeFirst()
        }
        let allowed: Set<String> = ["--name", "--width", "--height", "--size", "--scale", "--refresh", "--config"]
        var values: [String: String] = [:]
        var index = 0
        while index < tail.count {
            let key = tail[index]
            guard allowed.contains(key) else { throw CLIError("Unknown option: \(key)") }
            guard values[key] == nil else { throw CLIError("Duplicate option: \(key)") }
            guard index + 1 < tail.count, !tail[index + 1].hasPrefix("--") else { throw CLIError("Missing value for \(key).") }
            values[key] = tail[index + 1]
            index += 2
        }
        guard preset == nil || values["--config"] == nil else {
            throw CLIError("Choose either a preset or --config, not both.")
        }
        guard values["--size"] == nil || (values["--width"] == nil && values["--height"] == nil) else {
            throw CLIError("Use --size or --width/--height, not both.")
        }
        var base: DisplayConfiguration?
        if let path = values["--config"] {
            do { base = try JSONDecoder().decode(FileConfiguration.self, from: readFile(path)).configuration }
            catch { throw CLIError("Cannot load display configuration '\(path)': \(error)") }
        } else if let preset {
            base = try DisplayConfiguration(name: "vdisplay", width: preset.width, height: preset.height,
                                            scale: preset.scale, refresh: preset.refresh)
        }
        func integer(_ raw: String, _ label: String) throws -> UInt32 {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = UInt32(raw) else {
                throw CLIError("Invalid unsigned integer for \(label): \(raw)")
            }
            return number
        }
        func value(_ key: String, default fallback: UInt32?) throws -> UInt32 {
            if let raw = values[key] { return try integer(raw, key) }
            guard let fallback else { throw CLIError("Specify a preset, --config, --size, or both --width and --height.") }
            return fallback
        }
        let width: UInt32
        let height: UInt32
        if let size = values["--size"] {
            let parts = size.split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw CLIError("Size must use WIDTHxHEIGHT, for example 2560x1440.") }
            width = try integer(String(parts[0]), "--size width")
            height = try integer(String(parts[1]), "--size height")
        } else {
            width = try value("--width", default: base?.width)
            height = try value("--height", default: base?.height)
        }
        let refresh: Double
        if let raw = values["--refresh"] {
            guard let number = Double(raw), number.isFinite else { throw CLIError("Invalid refresh rate: \(raw)") }
            refresh = number
        } else { refresh = base?.refresh ?? 60 }
        return try DisplayConfiguration(name: values["--name"] ?? base?.name ?? "vdisplay", width: width, height: height,
                                        scale: value("--scale", default: base?.scale ?? 1), refresh: refresh)
    }
}
