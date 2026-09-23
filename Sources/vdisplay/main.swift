import AppKit
import CoreGraphics
import Darwin
import DisplayCore
import Foundation
import SystemConfiguration
import VirtualDisplayBridge

let usage = """
Usage:
  vdisplay run --width PIXELS --height PIXELS [--name NAME] [--scale 1|2] [--refresh 60]
  vdisplay list [--json]
  vdisplay doctor
  vdisplay profile add ALIAS --width PIXELS --height PIXELS [--name NAME] [--scale 1|2] [--refresh 60]
  vdisplay profile list
  vdisplay profile remove ALIAS
  vdisplay agent install|uninstall
  vdisplay start PROFILE [--wait]
  vdisplay stop PROFILE [--wait]
  vdisplay status PROFILE [--json]
  vdisplay --help

run keeps one SDR virtual display alive until Ctrl-C or SIGTERM.
Dimensions are output pixels; scale 2 requests half-sized logical dimensions.
Background profiles require explicit agent installation. Start enables login restoration;
stop disables it. Both commands wait for completion. Run without sudo.
"""

func diagnostic(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func checkSession() throws {
    var uid: uid_t = 0
    guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          user != "loginwindow", uid == getuid(), uid != 0 else {
        throw CLIError("Run as the logged-in graphical console user (not root).", exitCode: 4)
    }
}

func checkAPI() throws {
    var error = [CChar](repeating: 0, count: 1024)
    guard VDCheckAPI(&error, error.count) else {
        throw CLIError(String(cString: error), exitCode: 3)
    }
}

func onlineIDs() throws -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    var result = CGGetOnlineDisplayList(0, nil, &count)
    guard result == .success else { throw CLIError("Display enumeration failed: \(result.rawValue)", exitCode: 5) }
    if count == 0 { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    result = CGGetOnlineDisplayList(count, &ids, &count)
    guard result == .success else { throw CLIError("Display enumeration failed: \(result.rawValue)", exitCode: 5) }
    return Array(ids.prefix(Int(count)))
}

func currentMode(_ id: CGDirectDisplayID) -> DisplayMode? {
    guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
    return DisplayMode(logicalWidth: mode.width, logicalHeight: mode.height,
                       pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
}

struct DisplayInfo: Encodable {
    let displayID: UInt32
    let name: String?
    let ownership: String
    let isMain: Bool
    let isActive: Bool
    let mode: DisplayMode?
}

func listDisplays(json: Bool) throws {
    let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, String)? in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return (number.uint32Value, screen.localizedName)
    })
    let displays = try onlineIDs().map { id in
        DisplayInfo(displayID: id, name: names[id], ownership: "unknown",
                    isMain: CGDisplayIsMain(id) != 0, isActive: CGDisplayIsActive(id) != 0, mode: currentMode(id))
    }
    if json { print(try encode(displays)); return }
    for display in displays {
        let name = display.name ?? "Unnamed display"
        if let mode = display.mode {
            print("\(display.displayID)  \(name)  \(mode.pixelWidth)x\(mode.pixelHeight) pixels  \(mode.logicalWidth)x\(mode.logicalHeight) logical  \(mode.refreshRate) Hz  ownership=unknown")
        } else { print("\(display.displayID)  \(name)  mode unavailable  ownership=unknown") }
    }
}

// Notifications wake the main run loop; actual readiness is confirmed by mode readback.
let displayCallback: CGDisplayReconfigurationCallBack = { _, _, _ in
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

func runDisplay(_ configuration: DisplayConfiguration, serial requestedSerial: UInt32? = nil,
                onReady: ((DisplayInfo) throws -> Void)? = nil) throws {
    try checkSession()
    try checkAPI()
    var interrupted = false
    var signalSources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { interrupted = true; CFRunLoopWakeUp(CFRunLoopGetMain()) }
        source.resume()
        signalSources.append(source)
    }
    defer { signalSources.forEach { $0.cancel() } }

    diagnostic("Creating virtual display...")
    var error = [CChar](repeating: 0, count: 1024)
    // Profiles supply a persistent serial; direct foreground runs use ephemeral identity.
    // Each foreground owner has a distinct PID. Do not enumerate before creation:
    // CoreGraphics can cache a topology that excludes the new display's modes.
    let serial = requestedSerial ?? UInt32(getpid())
    guard let handle = VDCreate(configuration.name as CFString, configuration.width, configuration.height,
                                configuration.scale, configuration.refresh, serial, &error, error.count) else {
        throw CLIError(String(cString: error), exitCode: 5)
    }
    let id = VDDisplayID(handle)
    var released = false
    defer { if !released { VDRelease(handle) } }
    // Register after creation to avoid initializing the CoreGraphics mode cache
    // against the old display topology. Readback also covers a missed add event.
    let registration = CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
    guard registration == .success else { throw CLIError("Could not register display notifications.", exitCode: 5) }
    defer { CGDisplayRemoveReconfigurationCallback(displayCallback, nil) }
    var creationError: Error?
    do {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !interrupted {
            if try onlineIDs().contains(id), let mode = currentMode(id), mode.matches(configuration) { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                let actual = try currentMode(id).map { try encode($0) } ?? "unavailable"
                throw CLIError("Display did not reach the requested mode within 5 seconds. Actual mode: \(actual)", exitCode: 5)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if !interrupted {
            let ready = DisplayInfo(displayID: id, name: configuration.name, ownership: "this-process",
                                    isMain: CGDisplayIsMain(id) != 0, isActive: CGDisplayIsActive(id) != 0,
                                    mode: currentMode(id))
            try onReady?(ready)
            print(try encode(ready))
            fflush(stdout)
            diagnostic("Display ready. Press Ctrl-C to remove it.")
            while !interrupted {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
                guard try onlineIDs().contains(id) else {
                    throw CLIError("The owned display disappeared from the system.", exitCode: 5)
                }
            }
        }
    } catch { creationError = error }

    diagnostic("Removing virtual display...")
    VDRelease(handle)
    released = true
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while try onlineIDs().contains(id) {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            if let creationError { diagnostic(String(describing: creationError)) }
            throw CLIError("Display \(id) is still enumerated after release (5-second timeout).", exitCode: 5)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    diagnostic("Display removed.")
    if let creationError { throw creationError }
}

func runWorker(_ alias: String, store: ProfileStore) throws {
    try store.prepare()
    let profile = try store.profile(alias)
    let lease = try store.workerLease(profile)
    defer { withExtendedLifetime(lease) {} }
    try store.saveState(WorkerState(profileID: profile.id, phase: .starting), for: profile)
    do {
        try runDisplay(profile.configuration, serial: profile.serial) { info in
            try store.saveState(WorkerState(profileID: profile.id, phase: .ready,
                                           displayID: info.displayID, mode: info.mode), for: profile)
        }
        try store.saveState(WorkerState(profileID: profile.id, phase: .stopped), for: profile)
    } catch {
        do {
            try store.saveState(WorkerState(profileID: profile.id, phase: .failed,
                                           message: String(describing: error)), for: profile)
        } catch { diagnostic("Could not save worker failure: \(error)") }
        throw error
    }
}

do {
    let store = ProfileStore.standard()
    let agent = AgentController(store: store)
    switch try Command.parse(Array(CommandLine.arguments.dropFirst())) {
    case .profile(let command):
        switch command {
        case .add(let alias, let config): print(try encode(store.add(alias: alias, configuration: config)))
        case .list: print(try encode(store.profiles()))
        case .remove(let alias): try store.remove(alias); print("Profile removed: \(alias)")
        }
    case .agent(let command, let alias):
        switch command {
        case .install:
            try checkSession()
            guard let executable = Bundle.main.executableURL else { throw CLIError("Cannot locate the running executable.", exitCode: 5) }
            try agent.install(from: executable.resolvingSymlinksInPath())
            print("Agent executable installed: \(store.binary.path)")
        case .uninstall:
            try checkSession(); try agent.uninstall(); print("Agent executable removed. Profiles and logs retained.")
        case .run:
            guard let alias else { throw CLIError("Worker profile alias is required.") }
            try runWorker(alias, store: store)
        }
    case .start(let alias):
        try checkSession(); diagnostic("Starting background display..."); print(try encode(agent.start(alias)))
    case .stop(let alias):
        try checkSession(); diagnostic("Stopping background display..."); try agent.stop(alias); print("Profile stopped and disabled: \(alias)")
    case .status(let alias, let json):
        let status = try agent.status(alias)
        if json { print(try encode(status)) }
        else {
            print("\(alias): \(status.state.phase.rawValue), enabled=\(status.enabled), running=\(status.running)")
            if let id = status.state.displayID { print("Display ID: \(id)") }
            if let message = status.state.message { print(message) }
        }
    case .help: print(usage)
    case .list(let json): try listDisplays(json: json)
    case .doctor:
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(arm64)
        print("Process architecture: arm64")
        #elseif arch(x86_64)
        print("Process architecture: x86_64")
        #endif
        try checkSession()
        print("Graphical console user: available")
        try checkAPI()
        print("Required private API classes/selectors: available")
        print("Display creation and capture: not tested by doctor")
    case .run(let configuration): try runDisplay(configuration)
    }
} catch let error as CLIError {
    diagnostic(error.description)
    exit(error.exitCode)
} catch {
    diagnostic(String(describing: error))
    exit(5)
}
