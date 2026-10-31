// PanelProbe: a minimal sandboxed app that asks one question.
// When automation, not a person, presses Open in this app's folder panel, does
// macOS still extend the app's sandbox to the chosen folder?
//
// Usage (started by run-arms.sh, never by Apple Events):
//   PanelProbe <arm> <chosen dir> <sibling dir> <previous arm's chosen dir or ->
// Paths are passed already resolved (pwd -P) by the unsandboxed script.
//
// One launch:
//   G1  the app runs in its sandbox container, else VOID
//   G3  before any panel: reads and creates in chosen and sibling, and a read of
//       the previous arm's file, all refused with errno 1, else VOID
//   a route-control window with one default button "Go": the driver presses it
//       by the same route it will use on the panel; its action logs ROUTE-OK
//       and opens the panel (begin, not runModal)
//   G4  the panel returned the chosen folder
//   after OK: R-in, R-list, G2 (create+write+unlink) allowed; R-sib, W-sib refused
// Only errno 1 counts as refused; any other failure is VOID.
// The app never calls ok(_:) and never acts on its own panel, except cancel(nil)
// at the 90 s timeout.
//
// Output: results-<arm>.txt in the container's home and os_log subsystem
// dev.probe.a11y.panel, the same lines in both.
import AppKit
import Darwin
import os

let log = Logger(subsystem: "dev.probe.a11y.panel", category: "probe")

struct Args {
    let arm: String
    let chosen: String
    let sibling: String
    let previous: String?

    static func parse() -> Args? {
        let a = CommandLine.arguments
        guard a.count >= 5 else { return nil }
        return Args(arm: a[1], chosen: a[2], sibling: a[3], previous: a[4] == "-" ? nil : a[4])
    }
}

final class Record {
    private let handle: FileHandle?
    private var seq = 0

    init(arm: String) {
        let path = NSHomeDirectory() + "/results-\(arm).txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func line(_ text: String) {
        seq += 1
        let full = "\(seq) \(text)"
        log.log("\(full, privacy: .public)")
        guard let handle, let data = (full + "\n").data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.synchronize()
    }
}

/// Outcome of one file-system observation: ok, refused (errno 1) or other (any other errno).
enum Seen: CustomStringConvertible {
    case ok
    case refused
    case other(Int32)

    var description: String {
        switch self {
        case .ok: return "ok"
        case .refused: return "refused"
        case .other(let code): return "errno\(code)"
        }
    }
}

enum Ops {
    static func read(_ path: String) -> Seen {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return seen(errno) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = Darwin.read(fd, &buffer, buffer.count)
        return n >= 0 ? .ok : seen(errno)
    }

    static func list(_ path: String) -> Seen {
        guard let dir = opendir(path) else { return seen(errno) }
        defer { closedir(dir) }
        errno = 0
        var entries = 0
        while readdir(dir) != nil { entries += 1 }
        return errno == 0 ? .ok : seen(errno)
    }

    /// Create a new file, write to it, then unlink it. A create that should have been
    /// refused but was not is still cleaned up.
    static func createWrite(_ path: String) -> Seen {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return seen(errno) }
        let bytes: [UInt8] = Array("probe\n".utf8)
        let n = write(fd, bytes, bytes.count)
        let writeErrno = errno
        close(fd)
        let unlinked = unlink(path)
        let unlinkErrno = errno
        if n < 0 { return seen(writeErrno) }
        if unlinked != 0 { return seen(unlinkErrno) }
        return .ok
    }

    private static func seen(_ code: Int32) -> Seen {
        code == EPERM ? .refused : .other(code)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var args: Args?
    private var record: Record?
    private var window: NSWindow?
    private var panel: NSOpenPanel?
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let args = Args.parse() else {
            FileHandle.standardError.write(Data("usage: PanelProbe arm chosen sibling previous|-\n".utf8))
            NSApp.terminate(nil)
            return
        }
        self.args = args
        let record = Record(arm: args.arm)
        self.record = record
        record.line("START arm=\(args.arm) chosen=\(args.chosen) sibling=\(args.sibling) previous=\(args.previous ?? "-")")

        let home = NSHomeDirectory()
        let sandboxed = home.contains("/Library/Containers/dev.probe.a11y.panel/")
        record.line("G1 home=\(home) sandboxed=\(sandboxed)")
        guard sandboxed else { return finish(void: "g1") }

        var g3: [(String, Seen)] = [
            ("readChosen", Ops.read(args.chosen + "/inside.txt")),
            ("readSibling", Ops.read(args.sibling + "/outside.txt")),
            ("listChosen", Ops.list(args.chosen)),
            ("createChosen", Ops.createWrite(args.chosen + "/g3.tmp")),
            ("createSibling", Ops.createWrite(args.sibling + "/g3.tmp")),
        ]
        if let previous = args.previous {
            g3.append(("readPrevious", Ops.read(previous + "/inside.txt")))
        }
        record.line("G3 " + g3.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        if let bad = g3.first(where: { if case .refused = $0.1 { return false } else { return true } }) {
            return finish(void: "g3:\(bad.0)")
        }

        showRouteControl()
        waitUntilReady(deadline: Date().addingTimeInterval(30))
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.logState() }
    }

    private func showRouteControl() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 320, height: 140),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "PanelProbe"
        let button = NSButton(title: "Go", target: self, action: #selector(go))
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 110, y: 50, width: 100, height: 32)
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func waitUntilReady(deadline: Date) {
        guard !finished else { return }
        if NSApp.isActive, window?.isKeyWindow == true {
            record?.line("READY active=true key=true")
            return
        }
        if Date() > deadline {
            record?.line("NOTREADY active=\(NSApp.isActive) key=\(window?.isKeyWindow == true)")
            return finish(void: nil, notRun: "notReady")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitUntilReady(deadline: deadline)
        }
    }

    private func logState() {
        guard !finished else { return }
        let key = NSApp.keyWindow.map { "\(type(of: $0)):\($0.title)" } ?? "none"
        record?.line("STATE active=\(NSApp.isActive) keyWindow=\(key) panelOpen=\(panel != nil)")
    }

    @objc private func go() {
        guard panel == nil, let args else { return }
        record?.line("ROUTE-OK")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: args.chosen, isDirectory: true)
        self.panel = panel
        panel.begin { [weak self] response in self?.completed(response) }
        record?.line("PANEL-SHOWN")
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, !self.finished, let panel = self.panel else { return }
            self.record?.line("PANEL-TIMEOUT")
            panel.cancel(nil)
        }
    }

    private func completed(_ response: NSApplication.ModalResponse) {
        guard !finished, let args, let record else { return }
        let url = panel?.url
        if response != .OK {
            record.line("RESPONSE cancel code=\(response.rawValue)")
            return finish(void: nil, result: "response=cancel")
        }
        let returned = url?.standardizedFileURL.resolvingSymlinksInPath().path ?? "nil"
        record.line("RESPONSE ok url=\(url?.path ?? "nil") resolved=\(returned)")
        guard returned == args.chosen else { return finish(void: "g4") }

        let after: [(String, Seen)] = [
            ("rIn", Ops.read(args.chosen + "/inside.txt")),
            ("rList", Ops.list(args.chosen)),
            ("g2", Ops.createWrite(args.chosen + "/g2.tmp")),
            ("rSib", Ops.read(args.sibling + "/outside.txt")),
            ("wSib", Ops.createWrite(args.sibling + "/w.tmp")),
        ]
        let summary = after.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        record.line("AFTER " + summary)
        if let bad = after.first(where: { if case .other = $0.1 { return true } else { return false } }) {
            return finish(void: "notEPERM:\(bad.0)")
        }
        finish(void: nil, result: "response=ok " + summary)
    }

    private func finish(void reason: String?, notRun: String? = nil, result: String? = nil) {
        guard !finished else { return }
        finished = true
        if let reason { record?.line("VOID reason=\(reason)") }
        if let notRun { record?.line("NOTRUN reason=\(notRun)") }
        if let result { record?.line("RESULT \(result)") }
        record?.line("END")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
