import AppKit
import ApplicationServices
import Darwin

// Private but long-stable API that maps an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct Window {
    let id: CGWindowID
    let appName: String
    let title: String
    let element: AXUIElement
}

// MARK: - Terminal helpers

let bold = "\u{1B}[1m", dim = "\u{1B}[2m", green = "\u{1B}[32m", yellow = "\u{1B}[33m", reset = "\u{1B}[0m"

/// Reads a single keypress without waiting for Enter.
func readKey() -> Character? {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
        // Not a TTY (e.g. piped input): fall back to line input.
        return readLine()?.first ?? "\n"
    }
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }

    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
    return Character(UnicodeScalar(byte))
}

// MARK: - Accessibility helpers

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func ensureAccessibility() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

// MARK: - Window discovery

/// Windows visible on the current desktop (Space), front to back, excluding the
/// terminal window this app is running in.
func windowsOnCurrentDesktop() -> [Window] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

    let ownPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var skippedOwnWindow = false
    var axWindowsByPID: [pid_t: [CGWindowID: AXUIElement]] = [:]
    var result: [Window] = []

    for entry in info {
        guard
            let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
            let id = entry[kCGWindowNumber as String] as? CGWindowID,
            let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
            let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict),
            bounds.width > 50, bounds.height > 50
        else { continue }

        // The frontmost window of the frontmost app is the terminal we're running in.
        if pid == ownPID && !skippedOwnWindow {
            skippedOwnWindow = true
            continue
        }

        if axWindowsByPID[pid] == nil {
            let app = AXUIElementCreateApplication(pid)
            var map: [CGWindowID: AXUIElement] = [:]
            for element in (attribute(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(element, &wid) == .success { map[wid] = element }
            }
            axWindowsByPID[pid] = map
        }

        // Only offer windows we can actually minimise.
        guard let element = axWindowsByPID[pid]?[id] else { continue }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable) == .success,
              settable.boolValue else { continue }

        let appName = entry[kCGWindowOwnerName as String] as? String ?? "Unknown"
        let title = (attribute(element, kAXTitleAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
            ?? entry[kCGWindowName as String] as? String
            ?? "(untitled)"
        result.append(Window(id: id, appName: appName, title: title, element: element))
    }
    return result
}

// MARK: - Main

guard ensureAccessibility() else {
    print("""
    \(yellow)peace needs Accessibility access to minimise windows.\(reset)
    Grant it to your terminal app in System Settings → Privacy & Security → Accessibility,
    then run peace again.
    """)
    exit(1)
}

let windows = windowsOnCurrentDesktop()
guard !windows.isEmpty else {
    print("No other windows on this desktop. Already at peace.")
    exit(0)
}

print("\(bold)\(windows.count) window\(windows.count == 1 ? "" : "s") on this desktop.\(reset)")
print("\(dim)y/Enter = keep open · n = minimise · a = minimise the rest · q = keep the rest\(reset)\n")

var toMinimise: [Window] = []
var kept = 0

ask: for (index, window) in windows.enumerated() {
    let counter = "\(dim)[\(index + 1)/\(windows.count)]\(reset)"
    print("\(counter) \(bold)\(window.appName)\(reset) — \(window.title)  Keep open? ", terminator: "")
    fflush(stdout)

    while true {
        guard let key = readKey() else { print(); break ask }
        switch key.lowercased() {
        case "y", "k", "\n", "\r":
            print("\(green)keep\(reset)"); kept += 1
        case "n", "m":
            print("\(yellow)minimise\(reset)"); toMinimise.append(window)
        case "a":
            print("\(yellow)minimise the rest\(reset)"); toMinimise += windows[index...]
            break ask
        case "q", "\u{1B}":
            print("\(dim)stop\(reset)"); kept += windows.count - index
            break ask
        default:
            continue
        }
        break
    }
}

print()
var failed = 0
for window in toMinimise {
    if AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) != .success {
        failed += 1
        print("\(yellow)Couldn't minimise \(window.appName) — \(window.title)\(reset)")
    }
}

print("Kept \(kept), minimised \(toMinimise.count - failed). ☮︎")
