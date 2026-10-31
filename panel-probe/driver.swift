// panel-driver: the automation side of the panel probe. It never sends Apple
// Events to the probe app. Subcommands:
//   trusted                         print AXIsProcessTrusted
//   key <return|escape>             post a CGEvent key down and up to the HID tap
//   raise <pid>                     AXFrontmost on the app, AXRaise on its windows
//   press <pid> <title>             AXPress the first button titled <title> in the
//                                   app's tree; then in every openAndSavePanelService
//                                   process' tree. Prints FOUND/AXERROR or
//                                   TARGET-NOT-FOUND
//   dump <pid>                      the AX tree of the app and of every panel service
//   windows                         on-screen windows by owner (CGWindowList; needs
//                                   no Accessibility)
import AppKit
import ApplicationServices
import CoreGraphics

func out(_ text: String) {
    print(text)
    fflush(stdout)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return error == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String {
    (attribute(element, name) as? String) ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func panelServicePIDs() -> [pid_t] {
    NSWorkspace.shared.runningApplications
        .filter { ($0.bundleIdentifier ?? "").contains("openAndSavePanelService") }
        .map(\.processIdentifier)
}

func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(element, depth) { return true }
    guard depth < maxDepth else { return false }
    for child in children(element) where walk(child, depth: depth + 1, maxDepth: maxDepth, visit: visit) {
        return true
    }
    return false
}

func dump(pid: pid_t, label: String) {
    out("DUMP \(label) pid=\(pid)")
    let app = AXUIElementCreateApplication(pid)
    _ = walk(app, depth: 0, maxDepth: 12) { element, depth in
        let role = string(element, kAXRoleAttribute)
        let title = string(element, kAXTitleAttribute)
        let description = string(element, kAXDescriptionAttribute)
        let identifier = string(element, kAXIdentifierAttribute)
        let focused = (attribute(element, kAXFocusedAttribute) as? Bool).map { $0 ? " focused" : "" } ?? ""
        out(String(repeating: "  ", count: depth) + "\(role) title=\"\(title)\" desc=\"\(description)\" id=\"\(identifier)\"\(focused)")
        return false
    }
}

func press(pid: pid_t, title: String) -> Bool {
    var targets: [(String, pid_t)] = [("app", pid)]
    targets += panelServicePIDs().map { ("panelService", $0) }
    for (label, target) in targets {
        var found: AXUIElement?
        _ = walk(AXUIElementCreateApplication(target), depth: 0, maxDepth: 14) { element, _ in
            if string(element, kAXRoleAttribute) == kAXButtonRole as String,
               string(element, kAXTitleAttribute) == title {
                found = element
                return true
            }
            return false
        }
        if let found {
            let error = AXUIElementPerformAction(found, kAXPressAction as CFString)
            out("FOUND in=\(label) pid=\(target) title=\(title)")
            out("AXERROR \(error.rawValue)")
            return true
        }
    }
    out("TARGET-NOT-FOUND title=\(title) searched=\(targets.map { "\($0.0):\($0.1)" }.joined(separator: ","))")
    return false
}

func key(_ name: String) -> Bool {
    let code: CGKeyCode
    switch name {
    case "return": code = 36
    case "escape": code = 53
    default: return false
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
        out("KEY-EVENT-NIL")
        return false
    }
    down.post(tap: .cghidEventTap)
    usleep(50_000)
    up.post(tap: .cghidEventTap)
    out("KEY-POSTED \(name) preflightPostEvent=\(CGPreflightPostEventAccess())")
    return true
}

func raise(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    let frontmost = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    out("RAISE frontmost axerror=\(frontmost.rawValue)")
    for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        out("RAISE window=\"\(string(window, kAXTitleAttribute))\" main=\(main.rawValue) raise=\(raised.rawValue)")
    }
}

func windows() {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for info in list {
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = info[kCGWindowOwnerPID as String] as? Int ?? -1
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        let name = info[kCGWindowName as String] as? String ?? ""
        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        out("WINDOW owner=\"\(owner)\" pid=\(pid) layer=\(layer) name=\"\(name)\" bounds=\(bounds)")
    }
}

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    out("usage: panel-driver trusted|key|raise|press|dump|windows ...")
    exit(2)
}
switch argv[1] {
case "trusted":
    out("TRUSTED ax=\(AXIsProcessTrusted()) postEvent=\(CGPreflightPostEventAccess())")
case "key" where argv.count == 3:
    exit(key(argv[2]) ? 0 : 1)
case "raise" where argv.count == 3:
    guard let pid = pid_t(argv[2]) else { exit(2) }
    raise(pid: pid)
case "press" where argv.count == 4:
    guard let pid = pid_t(argv[2]) else { exit(2) }
    exit(press(pid: pid, title: argv[3]) ? 0 : 3)
case "dump" where argv.count == 3:
    guard let pid = pid_t(argv[2]) else { exit(2) }
    dump(pid: pid, label: "app")
    for service in panelServicePIDs() { dump(pid: service, label: "panelService") }
case "windows":
    windows()
default:
    out("bad arguments: \(argv.dropFirst().joined(separator: " "))")
    exit(2)
}
