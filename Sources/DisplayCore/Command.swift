import Foundation

public struct CLIError: Error, CustomStringConvertible {
    public let description: String
    public let exitCode: Int32
    public init(_ description: String, exitCode: Int32 = 2) {
        self.description = description
        self.exitCode = exitCode
    }
}

public struct DisplayConfiguration: Equatable, Codable {
    public let name: String
    public let width: UInt32
    public let height: UInt32
    public let scale: UInt32
    public let refresh: Double

    public init(name: String, width: UInt32, height: UInt32, scale: UInt32, refresh: Double) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CLIError("Display name must be nonempty and contain no control characters.")
        }
        guard width > 0, height > 0 else { throw CLIError("Pixel dimensions must be positive.") }
        guard scale == 1 || scale == 2 else { throw CLIError("Scale must be 1 or 2.") }
        guard width % scale == 0, height % scale == 0 else {
            throw CLIError("Pixel dimensions must be divisible by scale.")
        }
        guard refresh == 60 else { throw CLIError("This release supports only 60 Hz SDR modes.") }
        self.name = name
        self.width = width
        self.height = height
        self.scale = scale
        self.refresh = refresh
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: values.decode(String.self, forKey: .name),
                      width: values.decode(UInt32.self, forKey: .width), height: values.decode(UInt32.self, forKey: .height),
                      scale: values.decode(UInt32.self, forKey: .scale), refresh: values.decode(Double.self, forKey: .refresh))
    }
}

public enum ProfileCommand: Equatable {
    case add(String, DisplayConfiguration)
    case list
    case remove(String)
}

public enum AgentCommand: String { case install, uninstall, run }

public enum Command: Equatable {
    case help
    case list(json: Bool)
    case presets(json: Bool)
    case doctor
    case run(DisplayConfiguration)
    case profile(ProfileCommand)
    case agent(AgentCommand, profile: String?)
    case start(String)
    case stop(String)
    case status(String, json: Bool)

    public static func parse(_ arguments: [String], readFile: DisplayOptions.FileReader = DisplayOptions.readFile) throws -> Command {
        guard let verb = arguments.first else { return .help }
        let tail = Array(arguments.dropFirst())
        switch verb {
        case "profile":
            guard let action = tail.first else { throw CLIError("Usage: vdisplay profile add|list|remove") }
            if action == "list", tail.count == 1 { return .profile(.list) }
            guard tail.count >= 2 else { throw CLIError("A profile alias is required.") }
            let alias = tail[1]
            try Profile.validateAlias(alias)
            if action == "remove", tail.count == 2 { return .profile(.remove(alias)) }
            if action == "add", case .run(let config) = try parse(["run"] + tail.dropFirst(2), readFile: readFile) {
                return .profile(.add(alias, config))
            }
            throw CLIError("Invalid profile command.")
        case "agent":
            guard let raw = tail.first, let action = AgentCommand(rawValue: raw) else {
                throw CLIError("Usage: vdisplay agent install|uninstall")
            }
            if action == .run, tail.count == 2 {
                try Profile.validateAlias(tail[1])
                return .agent(action, profile: tail[1])
            }
            guard action != .run, tail.count == 1 else { throw CLIError("Invalid agent command arguments.") }
            return .agent(action, profile: nil)
        case "start", "stop":
            guard tail.count == 1 || (tail.count == 2 && tail[1] == "--wait") else {
                throw CLIError("Usage: vdisplay \(verb) PROFILE [--wait]")
            }
            try Profile.validateAlias(tail[0])
            return verb == "start" ? .start(tail[0]) : .stop(tail[0])
        case "status":
            guard tail.count == 1 || (tail.count == 2 && tail[1] == "--json") else {
                throw CLIError("Usage: vdisplay status PROFILE [--json]")
            }
            try Profile.validateAlias(tail[0])
            return .status(tail[0], json: tail.count == 2)
        case "help", "--help", "-h":
            guard tail.isEmpty else { throw CLIError("Help takes no arguments.") }
            return .help
        case "doctor":
            guard tail.isEmpty else { throw CLIError("Doctor takes no arguments.") }
            return .doctor
        case "list":
            guard tail.isEmpty || tail == ["--json"] else { throw CLIError("Usage: vdisplay list [--json]") }
            return .list(json: !tail.isEmpty)
        case "presets":
            guard tail.isEmpty || tail == ["--json"] else { throw CLIError("Usage: vdisplay presets [--json]") }
            return .presets(json: !tail.isEmpty)
        case "run":
            return .run(try DisplayOptions.resolve(tail, readFile: readFile))
        default:
            throw CLIError("Unknown command: \(verb). Use vdisplay --help.")
        }
    }
}

public struct DisplayMode: Codable, Equatable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double

    public init(logicalWidth: Int, logicalHeight: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    public func matches(_ configuration: DisplayConfiguration) -> Bool {
        pixelWidth == Int(configuration.width) && pixelHeight == Int(configuration.height)
        && logicalWidth == Int(configuration.width / configuration.scale)
        && logicalHeight == Int(configuration.height / configuration.scale)
        && refreshRate.isFinite && abs(refreshRate - configuration.refresh) < 0.1
    }
}
