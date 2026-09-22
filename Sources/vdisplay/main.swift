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
  vdisplay --help

run keeps one SDR virtual display alive until Ctrl-C or SIGTERM.
Dimensions are output pixels; scale 2 requests half-sized logical dimensions.
Run in the current user's graphical login session. No background service is installed.
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

func runDisplay(_ configuration: DisplayConfiguration) throws {
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
    // Foreground runs have ephemeral identity. Persistent profiles are a later phase.
    // Each foreground owner has a distinct PID. Do not enumerate before creation:
    // CoreGraphics can cache a topology that excludes the new display's modes.
    let serial = UInt32(getpid())
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

do {
    switch try Command.parse(Array(CommandLine.arguments.dropFirst())) {
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
