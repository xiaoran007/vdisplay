import Darwin
import Foundation
import XCTest
@testable import DisplayCore

final class ProfileTests: XCTestCase {
    private var directory: URL!
    private var store: ProfileStore!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ProfileStore(root: directory.appendingPathComponent("Application Support/vdisplay"),
                             launchAgents: directory.appendingPathComponent("LaunchAgents"))
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func add(_ alias: String = "remote") throws -> Profile {
        try store.add(alias: alias, configuration: DisplayConfiguration(name: "Remote", width: 1920,
                                                                       height: 1080, scale: 1, refresh: 60))
    }
    private func install(_ agent: AgentController) throws {
        let source = directory.appendingPathComponent("source")
        try Data("test executable".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        try agent.install(from: source)
    }
    func testReadOnlyEmptyStoreDoesNotCreateDirectories() throws {
        XCTAssertEqual(try store.profiles(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }
    func testProfileRoundTripPreservesIdentityAndConfiguration() throws {
        let first = try add()
        let second = try add("portrait")
        let reopened = ProfileStore(root: store.root, launchAgents: store.launchAgents)
        XCTAssertEqual(try reopened.profile("remote"), first)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.serial, second.serial)
        XCTAssertNotEqual(first.serial, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.root.appendingPathComponent("profiles.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testDuplicateAndUnsafeAliasesDoNotOverwriteProfiles() throws {
        let profile = try add()
        XCTAssertThrowsError(try add())
        for alias in ["../escape", "a/b", "", "-option", "space name", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try add(alias))
        }
        XCTAssertEqual(try store.profiles(), [profile])
    }
    func testCorruptUnsupportedAndInvalidConfigurationAreRejected() throws {
        _ = try add()
        let url = store.root.appendingPathComponent("profiles.json")
        let original = try Data(contentsOf: url)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try store.profiles())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try store.profiles())
        object["version"] = 1
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        var configuration = try XCTUnwrap(profiles[0]["configuration"] as? [String: Any])
        configuration["scale"] = 3
        profiles[0]["configuration"] = configuration
        object["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try store.profiles())
    }
    func testControlAndWorkerLeasesExcludeConcurrentOwners() throws {
        let profile = try add()
        var control: FileLease? = try store.controlLease()
        XCTAssertThrowsError(try add("other"))
        withExtendedLifetime(control) {}
        control = nil
        _ = try add("other")
        var worker: FileLease? = try store.workerLease(profile)
        XCTAssertTrue(try store.workerRunning(profile))
        XCTAssertThrowsError(try store.workerLease(profile))
        XCTAssertThrowsError(try store.remove(profile.alias))
        withExtendedLifetime(worker) {}
        worker = nil
        XCTAssertFalse(try store.workerRunning(profile))
        try store.remove(profile.alias)
    }
    func testStaleReadyStateIsNotReportedAsRunning() throws {
        let profile = try add()
        try store.saveState(WorkerState(profileID: profile.id, phase: .ready, displayID: 99), for: profile)
        let agent = AgentController(store: store, launch: { _ in XCTFail("Status must not invoke launchctl"); return CommandResult(status: 1) })
        let status = try agent.status(profile.alias)
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.state.phase, .stopped)
        XCTAssertNil(status.state.displayID)
    }
    func testFailureRemainsVisibleWithoutWorker() throws {
        let profile = try add()
        try store.saveState(WorkerState(profileID: profile.id, phase: .failed, message: "API unavailable"), for: profile)
        let status = try AgentController(store: store).status(profile.alias)
        XCTAssertEqual(status.state.phase, .failed)
        XCTAssertEqual(status.state.message, "API unavailable")
    }
    func testLiveOwnerCannotReportReadinessWithoutMatchingMode() throws {
        let profile = try add()
        let worker = try store.workerLease(profile)
        defer { withExtendedLifetime(worker) {} }
        try store.saveState(WorkerState(profileID: profile.id, phase: .ready, displayID: 77,
            mode: DisplayMode(logicalWidth: 1280, logicalHeight: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60)), for: profile)
        XCTAssertThrowsError(try AgentController(store: store).status("remote"))
    }
    func testPlistUsesStableExecutableArgumentsWithoutShellOrRestartLoop() throws {
        let profile = try add()
        let data = try AgentController(store: store).plist(profile)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [store.binary.path, "agent", "run", "remote"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
    }
    func testStartWaitsForWorkerAndIsIdempotentThenStopDisablesLoginRestore() throws {
        let profile = try add()
        var loaded = false
        var worker: FileLease?
        var starts = 0
        let agent = AgentController(store: store, timeout: 0, launch: { arguments in
            switch arguments[0] {
            case "print": return CommandResult(status: loaded ? 0 : 1)
            case "bootstrap":
                starts += 1; loaded = true
                worker = try self.store.workerLease(profile)
                try self.store.saveState(WorkerState(profileID: profile.id, phase: .ready, displayID: 77,
                    mode: DisplayMode(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)), for: profile)
                return CommandResult(status: 0)
            case "bootout": loaded = false; worker = nil; return CommandResult(status: 0)
            default: XCTFail("Unexpected launchctl command"); return CommandResult(status: 1)
            }
        })
        try install(agent)
        XCTAssertEqual(try agent.start("remote").state.displayID, 77)
        XCTAssertEqual(try agent.start("remote").state.displayID, 77)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(store.enabled(profile))
        XCTAssertThrowsError(try store.remove("remote"))
        XCTAssertThrowsError(try agent.uninstall())
        withExtendedLifetime(worker) {}
        try agent.stop("remote")
        XCTAssertFalse(store.enabled(profile))
        XCTAssertEqual(try agent.status("remote").state.phase, .stopped)
        try agent.uninstall()
        XCTAssertEqual(try store.profile("remote"), profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.binary.path))
    }
    func testBootstrapFailureIsReportedAndDoesNotDeleteProfile() throws {
        let profile = try add()
        let agent = AgentController(store: store, timeout: 0, launch: { _ in CommandResult(status: 5, output: "denied") })
        try install(agent)
        XCTAssertThrowsError(try agent.start("remote")) { error in
            XCTAssertTrue(String(describing: error).contains("denied"))
        }
        XCTAssertEqual(try store.profile("remote"), profile)
        XCTAssertTrue(store.enabled(profile))
    }
    func testReadinessTimeoutCannotClaimSuccess() throws {
        _ = try add()
        let agent = AgentController(store: store, timeout: 0, launch: { args in CommandResult(status: args[0] == "print" ? 1 : 0) })
        try install(agent)
        XCTAssertThrowsError(try agent.start("remote")) { error in XCTAssertEqual((error as? CLIError)?.exitCode, 5) }
    }
    func testStopFailurePreservesEnabledDefinition() throws {
        let profile = try add()
        try FileManager.default.createDirectory(at: store.launchAgents, withIntermediateDirectories: true)
        try Data().write(to: store.plistURL(profile))
        let agent = AgentController(store: store, launch: { args in CommandResult(status: args[0] == "print" ? 0 : 5) })
        XCTAssertThrowsError(try agent.stop("remote"))
        XCTAssertTrue(store.enabled(profile))
    }
    func testNewCommandSyntaxAndInvalidArguments() throws {
        XCTAssertEqual(try Command.parse(["profile", "list"]), .profile(.list))
        XCTAssertEqual(try Command.parse(["agent", "install"]), .agent(.install, profile: nil))
        XCTAssertEqual(try Command.parse(["start", "remote", "--wait"]), .start("remote"))
        XCTAssertEqual(try Command.parse(["stop", "remote"]), .stop("remote"))
        XCTAssertEqual(try Command.parse(["status", "remote", "--json"]), .status("remote", json: true))
        guard case .profile(.add(let alias, let config)) = try Command.parse(["profile", "add", "remote", "--width", "1920", "--height", "1080"]) else {
            return XCTFail("Expected profile add")
        }
        XCTAssertEqual(alias, "remote"); XCTAssertEqual(config.width, 1920)
        for arguments in [["start"], ["stop", "../bad"], ["status", "remote", "--bad"], ["agent", "run"],
                          ["profile", "remove", "remote", "extra"], ["profile", "add", "remote"], ["agent", "install", "extra"]] {
            XCTAssertThrowsError(try Command.parse(arguments), "\(arguments)")
        }
    }
}
