import AppKit
import AuthenticationServices
import SwiftUI

/// Anmeldung an einem Immich-Konto (Passwort tippt der Nutzer selbst; Token landet im Schlüsselbund je Konto).
struct LoginView: View {
    var onDone: (() -> Void)? = nil
    @State private var server = AccountStore.shared.accounts.first?.server ?? ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    /// Anmeldearten des eingegebenen Servers (SSO-Knopf, Passwortfelder) – nil, solange unbekannt
    @State private var options: ImmichClient.LoginOptions?
    @Environment(\.webAuthenticationSession) private var webAuth

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack").font(.system(size: 48)).foregroundStyle(.tint)
            Text("HomeRoll Desktop").font(.largeTitle.bold())
            Text("Connect to your Immich server").foregroundStyle(.secondary)
            Form {
                TextField("Server", text: $server)
                if options?.password != false {
                    TextField("Email", text: $email).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)   // nur so hoch wie die Felder (ohne Passwort: eine Zeile)
            .frame(width: 380)
            .disabled(busy)
            if let error { Text(error).foregroundStyle(.red).font(.callout).frame(width: 360) }
            if options?.password != false {
                Button(busy ? "Signing In…" : "Sign In") { Task { await login() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || email.isEmpty || password.isEmpty || server.isEmpty)
            }
            if let o = options, o.sso {
                // SSO/OIDC wie in der Immich-App; Knopftext kommt vom Server (z. B. „Login with PixelUnion“)
                Button { Task { await loginSSO() } } label: {
                    Label(o.ssoTitle ?? "Sign In with SSO", systemImage: "person.badge.key")
                }
                .keyboardShortcut(o.password ? nil : .defaultAction)
                .disabled(busy)
            }
        }
        .padding(30)
        .frame(minWidth: 480, minHeight: 460)
        // Nach dem Tippen der Adresse kurz warten, dann die Anmeldearten des Servers abfragen
        .task(id: server) {
            options = nil
            guard server.count > 3 else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            options = try? await ImmichClient.shared.loginOptions(server: server)
        }
    }

    private func loginSSO() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let flow = try await ImmichClient.shared.ssoStart(server: server)
            let callback = try await webAuth.authenticate(using: flow.url, callbackURLScheme: ImmichClient.ssoScheme,
                                                          preferredBrowserSession: .shared)
            try await AccountStore.shared.loginSSO(flow, callback: callback)
            onDone?()
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // abgebrochen: still zurück
        } catch { self.error = error.localizedDescription }
    }

    private func login() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await AccountStore.shared.login(server: server, email: email.trimmingCharacters(in: .whitespaces), password: password)
            password = ""
            onDone?()
        } catch { self.error = error.localizedDescription }
    }
}

/// Eigenes Fenster für „Weiteres Konto hinzufügen“, solange schon eines angemeldet ist.
@MainActor
enum LoginWindow {
    private static var window: NSWindow?
    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Add Account"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: LoginView(onDone: { window?.close() }))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

/// Einstellungen: Konten mit „Nur ansehen“ und „Importe vom Mac“.
struct SettingsView: View {
    @Bindable var accounts = AccountStore.shared
    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(accounts.accounts) { a in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(a.name).font(.headline)
                            Text(a.email).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove", role: .destructive) { accounts.remove(a.id) }
                        }
                        Toggle("View only (no changes on the server)", isOn: Binding(
                            get: { a.readOnly }, set: { var b = a; b.readOnly = $0; accounts.update(b) }))
                        Toggle("Use for imports from this Mac", isOn: Binding(
                            get: { a.importTarget }, set: { var b = a; b.importTarget = $0; accounts.update(b) }))
                    }.padding(.vertical, 4)
                }
                Button("Add Account…") { LoginWindow.show() }
            }
            Section("Photos App on This Mac") {
                Toggle("Automatically upload new photos to the server", isOn: Binding(
                    get: { PhotosSync.shared.auto }, set: { PhotosSync.shared.auto = $0 }))
                Text("At launch and whenever new pictures arrive in Apple Photos. Only into the account set to “Use for imports from this Mac”. The first time, macOS asks for access to Photos.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sync Now") { Task { await PhotosSync.shared.run() } }
                    .disabled(!accounts.canImport || PhotosSync.shared.running)
                if PhotosSync.shared.paused, let u = PhotosSync.shared.pausedUntil {
                    HStack {
                        Text("Paused until \(u.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                        Button("Resume") { PhotosSync.shared.resume() }
                    }
                }
            }
            Section("Viewer") {
                Toggle("Always show the original (HDR)", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "mac.alwaysOriginal") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "mac.alwaysOriginal") }))
                Text("Immich's previews are SDR. With this on, photos open from the original file, so HDR photos show their full brightness.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Check for updates at launch", isOn: Binding(get: { Updater.shared.auto }, set: { Updater.shared.auto = $0 }))
                Text("Asks GitHub for the newest version of HomeRoll Desktop (version \(Updater.current) installed). Nothing about you or your photos is sent.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check Now") { Task { await Updater.shared.check(manual: true) } }.disabled(Updater.shared.busy)
            }
            Section("Keyboard (like Photos)") {
                Text("Space/double-click open · ←/→ browse · . favorite · ⌫ delete · ⌘L hide · ⌘R rotate · ⌘I info · ⌘+/⌘− zoom · ⇧⌘I import · ⇧⌘E export · ⌥⌘E export original · ⌃⌘A add to last album")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }
}
