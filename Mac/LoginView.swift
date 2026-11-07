import AppKit
import SwiftUI

/// Anmeldung an einem Immich-Konto (Passwort tippt der Nutzer selbst; Token landet im Schlüsselbund je Konto).
struct LoginView: View {
    var onDone: (() -> Void)? = nil
    @State private var server = AccountStore.shared.accounts.first?.server ?? ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack").font(.system(size: 48)).foregroundStyle(.tint)
            Text("HomeRoll Desktop").font(.largeTitle.bold())
            Text("Connect to your Immich server").foregroundStyle(.secondary)
            Form {
                TextField("Server", text: $server)
                TextField("Email", text: $email).textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password)
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .disabled(busy)
            if let error { Text(error).foregroundStyle(.red).font(.callout).frame(width: 360) }
            Button(busy ? "Signing In…" : "Sign In") { Task { await login() } }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || email.isEmpty || password.isEmpty || server.isEmpty)
        }
        .padding(30)
        .frame(minWidth: 480, minHeight: 460)
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
            }
            Section("Keyboard (like Photos)") {
                Text("Space/double-click open · ←/→ browse · . favorite · ⌫ delete · ⌘L hide · ⌘R rotate · ⌘I info · ⌘+/⌘− zoom · ⇧⌘I import · ⇧⌘E export · ⌥⌘E export original · ⌃⌘A add to last album")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
    }
}
