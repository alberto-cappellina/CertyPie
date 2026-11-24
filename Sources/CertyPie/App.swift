import SwiftUI

@main
struct CertyPieApp: App {
    @StateObject private var store = Store()

    /// Orange, non-template icon (template images ignore colors in the menu bar).
    static let alertIcon: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [.systemOrange, .systemOrange]))
        let img = NSImage(systemSymbolName: "person.badge.key.fill",
                          accessibilityDescription: NSLocalizedString("Expiring", comment: ""))!
            .withSymbolConfiguration(cfg)!
        img.isTemplate = false
        return img
    }()

    init() {
        let args = CommandLine.arguments
        // CLI debug: `CertyPie --dump` prints scan results and exits.
        if args.contains("--dump") {
            for i in Scanner.scan() {
                print("\(i.kind.label)\t\(i.daysLeft)d\t\(i.name)\t\(i.detail)")
            }
            exit(0)
        }
        // `CertyPie --screenshots <dir>` renders popup PNGs with fake data and exits.
        if let idx = args.firstIndex(of: "--screenshots"), idx + 1 < args.count {
            MainActor.assumeIsolated { ScreenshotTool.run(dir: args[idx + 1]) }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            let n = store.flagged.count
            if n > 0 {
                Image(nsImage: Self.alertIcon)
            } else {
                Image(systemName: "person.badge.key.fill")
            }
            if n > 0 { Text("\(n)") }
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Xcode expirations").font(.headline)

            if store.flagged.isEmpty {
                Label("No items expiring within \(store.thresholdDays) days", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                let certs = store.flagged.filter { $0.kind == .certificate }
                let profs = store.flagged.filter { $0.kind == .profile }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !certs.isEmpty {
                            SectionTitle(key: "Certificates (\(certs.count))")
                            ForEach(certs) { ItemRow(item: $0) }
                        }
                        if !profs.isEmpty {
                            SectionTitle(key: "Provisioning profiles (\(profs.count))")
                            ForEach(profs) { ItemRow(item: $0) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Explicit height: ScrollView collapses inside MenuBarExtra otherwise.
                .frame(height: min(CGFloat(store.flagged.count) * 52 + 50, 320))
            }

            Divider()

            Stepper(value: $store.thresholdDays, in: 1...90) {
                Text("Alert \(store.thresholdDays) days before expiry")
            }
            Stepper(value: $store.checkHour, in: 0...23) {
                Text("Daily check at \(String(format: "%02d", store.checkHour)):00")
            }
            Toggle("Notifications", isOn: $store.notificationsEnabled)
            Toggle("Launch at login", isOn: $store.launchAtLogin)

            Divider()

            Button {
                Scanner.openProfilesFolder()
            } label: {
                Label("Open provisioning profiles folder", systemImage: "folder")
            }

            Button {
                NSWorkspace.shared.open(URL(string: "https://developer.apple.com/account")!)
            } label: {
                Label("Open Apple Developer Account", systemImage: "safari")
            }

            Divider()

            HStack {
                Button("Check now") { store.checkNow() }
                Spacer()
                if let d = store.lastScan {
                    Text(d, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

struct SectionTitle: View {
    let key: LocalizedStringKey
    var body: some View {
        Text(key).textCase(.uppercase).font(.caption2.bold()).foregroundStyle(.secondary).padding(.top, 2)
    }
}

struct ItemRow: View {
    let item: ExpiryItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.kind == .certificate ? "key.fill" : "doc.badge.gearshape")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text("\(item.kind.label)\(item.detail.isEmpty ? "" : " · \(item.detail)")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(color)
            }
        }
    }

    private var color: Color { item.isExpired || item.daysLeft <= 2 ? .red : .orange }
    private var status: String {
        let date = item.expiry.formatted(date: .abbreviated, time: .omitted)
        return item.isExpired
            ? String(format: NSLocalizedString("Expired on %@", comment: ""), date)
            : String(format: NSLocalizedString("Expires on %@ (%lld d)", comment: ""), date, item.daysLeft)
    }
}

// MARK: - Screenshot generator (fake data only)

@MainActor
enum ScreenshotTool {
    static func run(dir: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let day: TimeInterval = 86_400
        func item(_ id: String, _ kind: ItemKind, _ name: String, _ detail: String, _ days: Double) -> ExpiryItem {
            ExpiryItem(id: id, kind: kind, name: name, detail: detail, expiry: Date().addingTimeInterval(days * day + 3600))
        }
        let team = "Example Srl"
        let expiring = [
            item("c1", .certificate, "Apple Distribution: \(team) (A1B2C3D4E5)", "Keychain", -3),
            item("c2", .certificate, "Apple Development: Jane Appleseed (F6G7H8I9J0)", "Keychain", 5),
            item("p1", .profile, "Acme App AppStore", "com.example.acme · \(team)", -1),
            item("p2", .profile, "Acme App Development", "com.example.acme.dev · \(team)", 2),
            item("p3", .profile, "Acme Widget AdHoc", "com.example.acme.widget · \(team)", 6),
        ]
        let states: [(String, [ExpiryItem])] = [("expiring", expiring), ("ok", [])]
        for (name, items) in states {
            let view = ContentView()
                .environmentObject(Store(demoItems: items))
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            win.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("popup-\(name)-\(lang).png"))
            }
            win.orderOut(nil)
        }
    }
}
