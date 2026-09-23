import Darwin
import Foundation

public struct CommandResult {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String = "") { self.status = status; self.output = output }
}

public struct ProfileStatus: Encodable {
    public let profile: Profile
    public let enabled: Bool
    public let running: Bool
    public let state: WorkerState
}

public final class AgentController {
    public typealias Launcher = ([String]) throws -> CommandResult
    private let store: ProfileStore
    private let uid: UInt32
    private let launch: Launcher
    private let timeout: TimeInterval
    private let fm = FileManager.default
    public init(store: ProfileStore, uid: UInt32 = getuid(), timeout: TimeInterval = 12,
                launch: @escaping Launcher = AgentController.launchctl) {
        self.store = store; self.uid = uid; self.timeout = timeout; self.launch = launch
    }
    private var domain: String { "gui/\(uid)" }
    private func target(_ profile: Profile) -> String { domain + "/" + store.label(profile) }
    public static func launchctl(_ arguments: [String]) throws -> CommandResult {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
    private func isLoaded(_ profile: Profile) throws -> Bool {
        // Only inspect command success, never parse launchctl's diagnostic output.
        try launch(["print", target(profile)]).status == 0
    }
    private func execute(_ arguments: [String]) throws {
        let result = try launch(arguments)
        guard result.status == 0 else {
            throw CLIError("launchctl \(arguments[0]) failed (\(result.status)): \(result.output)", exitCode: 4)
        }
    }
    public func install(from executable: URL) throws {
        let lease = try store.controlLease(); defer { withExtendedLifetime(lease) {} }
        for profile in try store.profiles() {
            guard try !store.workerRunning(profile) else { throw CLIError("Stop all profiles before installing or updating the agent.", exitCode: 4) }
        }
        guard fm.isExecutableFile(atPath: executable.path) else { throw CLIError("Source executable is not executable.", exitCode: 5) }
        try store.write(Data(contentsOf: executable), to: store.binary, permissions: 0o700)
    }
    public func uninstall() throws {
        let lease = try store.controlLease(); defer { withExtendedLifetime(lease) {} }
        for profile in try store.profiles() {
            guard !store.enabled(profile), try !store.workerRunning(profile), try !isLoaded(profile) else {
                throw CLIError("Stop all profiles before uninstalling the agent.", exitCode: 4)
            }
        }
        if fm.fileExists(atPath: store.binary.path) { try fm.removeItem(at: store.binary) }
    }
    public func plist(_ profile: Profile) throws -> Data {
        let values: [String: Any] = [
            "Label": store.label(profile),
            "ProgramArguments": [store.binary.path, "agent", "run", profile.alias],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ExitTimeOut": 10,
            "StandardOutPath": store.logURL(profile).path,
            "StandardErrorPath": store.logURL(profile).path
        ]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
    public func status(_ alias: String) throws -> ProfileStatus {
        let profile = try store.profile(alias)
        let running = try store.workerRunning(profile)
        let saved = try store.state(profile)
        let state: WorkerState
        if running {
            if let saved, saved.phase == .ready {
                guard let id = saved.displayID, id != 0,
                      let mode = saved.mode, mode.matches(profile.configuration) else {
                    throw CLIError("Worker reported readiness without the requested display mode.", exitCode: 5)
                }
            }
            state = saved ?? WorkerState(profileID: profile.id, phase: .starting)
        } else if let saved, saved.phase == .failed {
            state = saved
        } else {
            state = WorkerState(profileID: profile.id, phase: .stopped,
                                message: saved?.phase == .ready || saved?.phase == .starting ? "Owner is not running; saved display ID is stale." : nil)
        }
        return ProfileStatus(profile: profile, enabled: store.enabled(profile), running: running, state: state)
    }
    public func start(_ alias: String) throws -> ProfileStatus {
        let lease = try store.controlLease(); defer { withExtendedLifetime(lease) {} }
        let profile = try store.profile(alias)
        guard fm.isExecutableFile(atPath: store.binary.path) else { throw CLIError("Install the agent first: vdisplay agent install", exitCode: 4) }
        if try store.workerRunning(profile) {
            guard store.enabled(profile) else { throw CLIError("Profile is owned by a foreground worker; stop it before enabling background operation.", exitCode: 4) }
            return try waitReady(profile)
        }
        try fm.createDirectory(at: store.launchAgents, withIntermediateDirectories: true)
        try store.write(plist(profile), to: store.plistURL(profile))
        try store.saveState(WorkerState(profileID: profile.id, phase: .starting), for: profile)
        do {
            if try isLoaded(profile) { try execute(["kickstart", target(profile)]) }
            else { try execute(["bootstrap", domain, store.plistURL(profile).path]) }
        } catch {
            let message = "\(error) Profile remains enabled; use stop to disable login restoration."
            try store.saveState(WorkerState(profileID: profile.id, phase: .failed, message: message), for: profile)
            throw CLIError(message, exitCode: 4)
        }
        return try waitReady(profile)
    }
    private func waitReady(_ profile: Profile) throws -> ProfileStatus {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let current = try status(profile.alias)
            if current.running, current.state.phase == .ready { return current }
            if current.state.phase == .failed {
                throw CLIError(current.state.message ?? "Display worker failed.", exitCode: 5)
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        throw CLIError("Profile did not become ready. Inspect status and log: \(store.logURL(profile).path). The profile remains enabled; use stop to disable it.", exitCode: 5)
    }
    public func stop(_ alias: String) throws {
        let lease = try store.controlLease(); defer { withExtendedLifetime(lease) {} }
        let profile = try store.profile(alias)
        if try isLoaded(profile) { try execute(["bootout", target(profile)]) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while try store.workerRunning(profile) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CLIError("Owner is still running. Profile remains enabled; inspect its log before retrying stop.", exitCode: 5)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if store.enabled(profile) { try fm.removeItem(at: store.plistURL(profile)) }
        try store.saveState(WorkerState(profileID: profile.id, phase: .stopped), for: profile)
    }
}
