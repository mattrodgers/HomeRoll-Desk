import Foundation

/// Ein gespeichertes Immich-Konto. Token liegt im Schlüsselbund unter „accessToken.<userId>“, nie in den Einstellungen.
struct Account: Codable, Identifiable, Hashable {
    let id: String           // Immich-Nutzer-ID
    var name: String
    var email: String
    var server: String
    /// Nur ansehen: keine Änderungen am Server (Favorit, Löschen, Alben …).
    var readOnly: Bool
    /// Ziel für Importe vom Mac (Dateien, Ordner, Apples Fotos-App). Lässt sich je Konto abschalten.
    var importTarget: Bool
}

@MainActor @Observable
final class AccountStore {
    static let shared = AccountStore()
    private(set) var accounts: [Account] = []
    private(set) var currentID: String?

    var current: Account? { accounts.first { $0.id == currentID } }
    var canWrite: Bool { current.map { !$0.readOnly } ?? false }
    var canImport: Bool { current.map { $0.importTarget && !$0.readOnly } ?? false }

    init() {
        ImmichClient.freshAPI = true
        // Der Mac führt Server + Token je Konto selbst. Ohne den iPhone-Eintrag „serverURL“ liest ImmichClient beim Start
        // nicht noch den gemeinsamen Schlüssel „accessToken“ → eine Schlüsselbund-Abfrage weniger.
        UserDefaults.standard.removeObject(forKey: "serverURL")
        if let d = UserDefaults.standard.data(forKey: "mac.accounts"), let a = try? JSONDecoder().decode([Account].self, from: d) {
            accounts = a
        }
        currentID = UserDefaults.standard.string(forKey: "mac.currentAccount")
        #if DEBUG
        // Tests: Server/Token per Startumgebung (FOTOS_SERVER/FOTOS_TOKEN), eigenes Testkonto, nichts gespeichert
        let env = ProcessInfo.processInfo.environment
        if env["FOTOS_SERVER"] != nil, env["FOTOS_TOKEN"] != nil {
            let t = Account(id: "env", name: env["FOTOS_NAME"] ?? "Test", email: "test@example.com",
                            server: env["FOTOS_SERVER"]!, readOnly: env["FOTOS_READONLY"] == "1", importTarget: true)
            accounts = [t]; currentID = t.id
            return
        }
        #endif
        if let c = current, let url = URL(string: c.server), let tok = TokenStore.token(for: c.id) {
            ImmichClient.shared.activate(server: url, token: tok)
        } else {
            currentID = nil
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(d, forKey: "mac.accounts") }
        UserDefaults.standard.set(currentID, forKey: "mac.currentAccount")
    }

    /// Anmeldung mit E-Mail + Passwort (tippt der Nutzer selbst); danach ist das Konto aktiv.
    func login(server: String, email: String, password: String) async throws {
        add(try await ImmichClient.shared.login(server: server, email: email, password: password))
    }

    /// Anmeldung per SSO/OIDC: Rücksprung des Anbieters einlösen, dann wie bei der Passwort-Anmeldung übernehmen.
    func loginSSO(_ flow: ImmichClient.SSOFlow, callback: URL) async throws {
        add(try await ImmichClient.shared.ssoFinish(flow, callback: callback))
    }

    private func add(_ r: LoginResponse) {
        UserDefaults.standard.removeObject(forKey: "serverURL")
        guard let base = ImmichClient.shared.baseURL else { return }
        TokenStore.set(r.accessToken, for: r.userId)
        Keychain.set(nil, for: "accessToken")   // ImmichClient.login legt am Mac unnötig einen Eintrag an
        if let i = accounts.firstIndex(where: { $0.id == r.userId }) {
            accounts[i].name = r.name; accounts[i].email = r.userEmail; accounts[i].server = base.absoluteString
        } else {
            accounts.append(Account(id: r.userId, name: r.name, email: r.userEmail, server: base.absoluteString,
                                    readOnly: false, importTarget: true))
        }
        currentID = r.userId
        save()
    }

    func switchTo(_ id: String) {
        guard let a = accounts.first(where: { $0.id == id }), let url = URL(string: a.server),
              let tok = TokenStore.token(for: a.id) else { return }
        ImmichClient.shared.activate(server: url, token: tok)
        currentID = id
        save()
    }

    func update(_ a: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == a.id }) else { return }
        accounts[i] = a
        save()
    }

    /// Konto entfernen (Token weg); ist es das aktive, kommt das nächste dran oder die Anmeldung.
    func remove(_ id: String) {
        TokenStore.set(nil, for: id)
        accounts.removeAll { $0.id == id }
        if currentID == id {
            currentID = nil
            if let next = accounts.first { switchTo(next.id) } else { ImmichClient.shared.logout() }
        }
        save()
    }
}
