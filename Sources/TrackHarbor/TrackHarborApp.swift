import SwiftUI
import AppKit

@main
struct TrackHarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DownloadViewModel()

    var body: some Scene {
        Window("TrackHarbor", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 700, minHeight: 700)
        }
        .defaultSize(width: 900, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About TrackHarbor") {
                    AppDelegate.showAboutPanel()
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "TrackHarbor", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func showAboutPanel() {
        let credits = NSMutableAttributedString(string: "Created by Gertjan Assies\n\n")
        credits.append(NSAttributedString(
            string: "gertjanassies.dev",
            attributes: [.link: URL(string: "https://gertjanassies.dev") as Any]
        ))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "TrackHarbor",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1",
            .credits: credits
        ]
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
