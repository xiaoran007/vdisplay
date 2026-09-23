import Darwin
import Foundation

public struct Profile: Codable, Equatable {
    public let id: UUID
    public let alias: String
    public let serial: UInt32
    public let configuration: DisplayConfiguration

    public static func validateAlias(_ alias: String) throws {
        guard alias.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw CLIError("Profile alias must be 1-64 ASCII letters, digits, underscores, or hyphens, starting with a letter or digit.")
        }
    }
}

public final class FileLease {
    private let fd: Int32
    public let token = UUID()
    public init(url: URL, nonblocking: Bool = true) throws {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CLIError("Cannot open lock: \(url.path)", exitCode: 5) }
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK {
                throw CLIError("Another operation owns lock: \(url.lastPathComponent)", exitCode: 4)
            }
            throw CLIError("Could not acquire lock: \(url.lastPathComponent) (errno \(reason))", exitCode: 5)
        }
        let bytes = Array(token.uuidString.utf8)
        guard ftruncate(descriptor, 0) == 0, write(descriptor, bytes, bytes.count) == bytes.count else {
            flock(descriptor, LOCK_UN); close(descriptor)
            throw CLIError("Could not record lock ownership.", exitCode: 5)
        }
        fd = descriptor
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

public enum WorkerPhase: String, Codable { case starting, ready, stopped, failed }

public struct WorkerState: Codable, Equatable {
    public let profileID: UUID
    public let phase: WorkerPhase
    public let displayID: UInt32?
    public let mode: DisplayMode?
    public let message: String?
    public let ownerToken: UUID?

    public init(profileID: UUID, phase: WorkerPhase, displayID: UInt32? = nil,
                mode: DisplayMode? = nil, message: String? = nil, ownerToken: UUID? = nil) {
        self.profileID = profileID
        self.phase = phase
        self.displayID = displayID
        self.mode = mode
        self.message = message
        self.ownerToken = ownerToken
    }
}

public final class ProfileStore {
    public let root: URL
    public let launchAgents: URL
    private let fm = FileManager.default
    public var binary: URL { root.appendingPathComponent("bin/vdisplay") }
    private var profilesURL: URL { root.appendingPathComponent("profiles.json") }

    public init(root: URL, launchAgents: URL) { self.root = root; self.launchAgents = launchAgents }
    public static func standard() -> ProfileStore {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return ProfileStore(root: library.appendingPathComponent("Application Support/vdisplay"),
                            launchAgents: library.appendingPathComponent("LaunchAgents"))
    }
    public func prepare() throws {
        for directory in [root, root.appendingPathComponent("bin"), root.appendingPathComponent("runtime"), root.appendingPathComponent("logs")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
    public func controlLease() throws -> FileLease { try prepare(); return try FileLease(url: root.appendingPathComponent("control.lock")) }
    public func workerLease(_ profile: Profile) throws -> FileLease { try FileLease(url: lockURL(profile)) }
    public func workerToken(_ profile: Profile) throws -> UUID? {
        UUID(uuidString: try String(contentsOf: lockURL(profile), encoding: .utf8))
    }
    private func lockURL(_ profile: Profile) -> URL { root.appendingPathComponent("runtime/\(profile.id.uuidString).lock") }
    public func stateURL(_ profile: Profile) -> URL { root.appendingPathComponent("runtime/\(profile.id.uuidString).json") }
    public func logURL(_ profile: Profile) -> URL { root.appendingPathComponent("logs/\(profile.id.uuidString).log") }
    public func label(_ profile: Profile) -> String { "io.vdisplay.profile.\(profile.id.uuidString.lowercased())" }
    public func plistURL(_ profile: Profile) -> URL { launchAgents.appendingPathComponent(label(profile) + ".plist") }
    public func enabled(_ profile: Profile) -> Bool { fm.fileExists(atPath: plistURL(profile).path) }

    public func workerRunning(_ profile: Profile) throws -> Bool {
        guard fm.fileExists(atPath: lockURL(profile).path) else { return false }
        do { let lease = try workerLease(profile); withExtendedLifetime(lease) {}; return false }
        catch let error as CLIError where error.exitCode == 4 { return true }
    }

    private struct Document: Codable { let version: Int; let profiles: [Profile] }
    public func profiles() throws -> [Profile] {
        guard fm.fileExists(atPath: profilesURL.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: profilesURL))
        guard document.version == 1 else { throw CLIError("Unsupported profile document version: \(document.version)", exitCode: 5) }
        var aliases = Set<String>(); var ids = Set<UUID>(); var serials = Set<UInt32>()
        for profile in document.profiles {
            try Profile.validateAlias(profile.alias)
            guard profile.serial != 0, aliases.insert(profile.alias).inserted,
                  ids.insert(profile.id).inserted, serials.insert(profile.serial).inserted else {
                throw CLIError("Profile document contains duplicate identities or invalid serial numbers.", exitCode: 5)
            }
        }
        return document.profiles
    }
    public func profile(_ alias: String) throws -> Profile {
        guard let profile = try profiles().first(where: { $0.alias == alias }) else {
            throw CLIError("Unknown profile: \(alias)")
        }
        return profile
    }
    public func add(alias: String, configuration: DisplayConfiguration) throws -> Profile {
        try Profile.validateAlias(alias)
        let lease = try controlLease(); defer { withExtendedLifetime(lease) {} }
        var profiles = try profiles()
        guard !profiles.contains(where: { $0.alias == alias }) else { throw CLIError("Profile already exists: \(alias)") }
        let serials = Set(profiles.map(\.serial))
        var serial = UInt32.random(in: 1...UInt32.max)
        while serials.contains(serial) { serial = UInt32.random(in: 1...UInt32.max) }
        let profile = Profile(id: UUID(), alias: alias, serial: serial, configuration: configuration)
        profiles.append(profile)
        try writeJSON(Document(version: 1, profiles: profiles), to: profilesURL)
        return profile
    }
    public func remove(_ alias: String) throws {
        let lease = try controlLease(); defer { withExtendedLifetime(lease) {} }
        let profile = try profile(alias)
        guard !enabled(profile), try !workerRunning(profile) else { throw CLIError("Stop profile \(alias) before removing it.", exitCode: 4) }
        try writeJSON(Document(version: 1, profiles: profiles().filter { $0.id != profile.id }), to: profilesURL)
        if fm.fileExists(atPath: stateURL(profile).path) { try fm.removeItem(at: stateURL(profile)) }
        // Keep the stable lock inode; removing it could bypass an existing lease.
    }
    public func state(_ profile: Profile) throws -> WorkerState? {
        guard fm.fileExists(atPath: stateURL(profile).path) else { return nil }
        let state = try JSONDecoder().decode(WorkerState.self, from: Data(contentsOf: stateURL(profile)))
        guard state.profileID == profile.id else { throw CLIError("Runtime state belongs to a different profile.", exitCode: 5) }
        return state
    }
    public func saveState(_ state: WorkerState, for profile: Profile) throws {
        guard state.profileID == profile.id else { throw CLIError("Runtime profile identity mismatch.", exitCode: 5) }
        try writeJSON(state, to: stateURL(profile))
    }
    public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(value), to: url)
    }
    public func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
