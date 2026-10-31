// A tiny SwiftUI app that copies the shape of two accessibility defects found
// by hand in a menu-bar app on 2026-10-31, so a VoiceOver driver on a hosted
// runner can be shown to catch them. Variant chosen by the first argument:
//   defective      the gear is a Menu whose label is an asset image named
//                  "icon-settings" with an accessibilityLabel on top; the
//                  playback value is "1:05 elapsed, 2:44 remaining"
//   clean          known-clean control: the label image has no name anywhere
//                  (drawn in code), the value is spelled with a formatter
//   fix-hidden     asset image marked accessibilityHidden(true), formatter value
//   fix-decorative Image(decorative: "icon-settings"), formatter value
// The Menu copies the source app's modifiers: borderlessButton style, hidden
// indicator, fixedSize, accessibilityLabel on the Menu.
import AppKit
import SwiftUI

enum Variant: String {
    case defective, clean, fixHidden = "fix-hidden", fixDecorative = "fix-decorative"

    static var current: Variant {
        let arguments = CommandLine.arguments.dropFirst()
        return arguments.compactMap(Variant.init(rawValue:)).first ?? .defective
    }
}

private let unnamedGear: NSImage = {
    let image = NSImage(size: NSSize(width: 30, height: 28), flipped: false) { rect in
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 7, dy: 6)).fill()
        return true
    }
    return image
}()

private func spokenDuration(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.allowedUnits = [.minute, .second]
    return formatter.string(from: seconds) ?? ""
}

struct GearLabel: View {
    let variant: Variant

    var body: some View {
        switch variant {
        case .defective:
            Image("icon-settings").resizable().aspectRatio(contentMode: .fit).frame(width: 15, height: 14)
        case .clean:
            Image(nsImage: unnamedGear).resizable().aspectRatio(contentMode: .fit).frame(width: 15, height: 14)
        case .fixHidden:
            Image("icon-settings").resizable().aspectRatio(contentMode: .fit).frame(width: 15, height: 14)
                .accessibilityHidden(true)
        case .fixDecorative:
            Image(decorative: "icon-settings").resizable().aspectRatio(contentMode: .fit).frame(width: 15, height: 14)
        }
    }
}

struct PanelStandIn: View {
    let variant = Variant.current

    private var playbackValue: String {
        if variant == .defective {
            return "1:05 elapsed, 2:44 remaining"
        }
        return "\(spokenDuration(65)) elapsed, \(spokenDuration(164)) remaining"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Probe Artist")
            Text("Probe Title")
            HStack {
                Text("1:05")
                Spacer()
                Text("-2:44")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue(playbackValue)
            HStack {
                Menu {
                    Button("About") {}
                    Button("Settings") {}
                } label: {
                    GearLabel(variant: variant)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Hibiki menu")
                Spacer()
                Button("Hibiki Flow") {}
                    .help("Generates a playlist that continues the current track")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// AppKit lifecycle with an explicit window: run 41236703586 showed a SwiftUI
// WindowGroup built this way (swiftc, no Xcode project) opened no window at
// all ("Fixture has no windows"), on the runners and on a local Mac alike.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fixture \(Variant.current.rawValue)"
        window.contentView = NSHostingView(rootView: PanelStandIn())
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
enum FixtureMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
