import AppKit
import SwiftUI

@main
struct FotosMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("HomeRoll Desktop", id: "main") {
            MainView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands { FotosCommands() }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated { PhotosSync.shared.startIfEnabled() }
        #if DEBUG
        MainActor.assumeIsolated { SelfTest.runIfRequested() }
        #endif
    }
}

/// Menüleiste mit Apples Befehlen und Kürzeln (REA: MainMenu.nib, siehe MAC-PLAN.md §3).
struct FotosCommands: Commands {
    @Bindable var lib = Library.shared
    @Bindable var accounts = AccountStore.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Album") { Menus.newAlbum(lib) }
                .keyboardShortcut("n").disabled(!accounts.canWrite)
            Button("New Smart Album…") { SmartAlbumWindow.show() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Import…") { Transfer.chooseAndImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!accounts.canImport)
            Button("Import New Photos from Photos App") { Task { await PhotosSync.shared.run() } }
                .disabled(!accounts.canImport || PhotosSync.shared.running)
            Menu("Export") {
                Button("Export Photos…") { Transfer.export(original: false) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Unmodified Original…") { Transfer.export(original: true) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
            }.disabled(lib.targets.isEmpty)
            Button("Share Link") { Task { await Menus.shareLink(lib) } }.disabled(lib.targets.isEmpty)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { Task { await Printing.printSelection() } }
                .keyboardShortcut("p").disabled(!lib.targets.contains(where: \.isImage))
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Deselect All") { lib.selection = []; lib.onReloadAll?() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Find") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                .keyboardShortcut("f")
        }
        CommandMenu("Image") {
            let w = accounts.canWrite, none = lib.targets.isEmpty
            Button("Open Viewer") { if let a = lib.targets.last, let p = lib.indexPath(a.id) { lib.open(p) } }
                .keyboardShortcut(.downArrow).disabled(none || lib.viewer != nil)
            Button("Close Viewer") { lib.closeViewer() }
                .keyboardShortcut(.upArrow).disabled(lib.viewer == nil)
            Divider()
            Button(lib.targets.allSatisfy(\.isFavorite) && !none ? "Unfavorite" : "Favorite") {
                Task { await lib.toggleFavorite() }
            }.disabled(!w || none)
            Button("Rotate Counterclockwise") { Task { await lib.rotate(clockwise: false) } }
                .keyboardShortcut("r").disabled(!w || none)
            Button("Rotate Clockwise") { Task { await lib.rotate(clockwise: true) } }
                .keyboardShortcut("r", modifiers: [.command, .option]).disabled(!w || none)
            Divider()
            Button("Edit") { lib.edit() }.disabled(!w || !lib.targets.contains(where: \.isImage) || lib.editing != nil)
            Button("Copy Edits") { Task { await lib.copyEdits() } }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!lib.targets.contains(where: \.isImage))
            Button("Paste Edits") { Task { await lib.pasteEdits() } }
                .keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!w || none || !EditClipboard.hasEdits)
            Divider()
            Button("Add to Last Album") { if let id = lib.lastAlbumID { Task { await lib.addToAlbum(id) } } }
                .keyboardShortcut("a", modifiers: [.command, .control]).disabled(!w || none || lib.lastAlbumID == nil)
            Menu("Add to") {
                ForEach(lib.albums) { a in Button(a.albumName) { Task { await lib.addToAlbum(a.id) } } }
            }.disabled(!w || none)
            if case .album = lib.source {
                Button("Make Key Photo") { Task { await lib.makeKeyPhoto() } }.disabled(!w || lib.targets.count != 1)
                Button("Remove from Album") { Task { await lib.removeFromAlbum() } }.disabled(!w || none)
            }
            Divider()
            Button(lib.source == .hidden ? "Unhide Photo" : "Hide Photo") { Task { await lib.toggleHidden() } }
                .keyboardShortcut("l").disabled(!w || none)
            if lib.source == .trash {
                Button("Recover") { Task { await lib.restore() } }.disabled(!w || none)
                Button("Delete Permanently…") {
                    if Menus.confirmDeleteForever(lib.targets.count) { Task { await lib.deleteForever() } }
                }.keyboardShortcut(.delete).disabled(!w || none)
            } else {
                Button("Delete Photo") { Task { await lib.trash() } }
                    .keyboardShortcut(.delete).disabled(!w || none)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Back") { lib.goBack() }.keyboardShortcut("[").disabled(!lib.canGoBack || lib.viewer != nil)
            Divider()
            Button("Zoom In") { lib.zoom = min(Library.zoomSizes.count - 1, lib.zoom + 1) }.keyboardShortcut("+")
            Button("Zoom Out") { lib.zoom = max(0, lib.zoom - 1) }.keyboardShortcut("-")
            Divider()
        }
        CommandGroup(before: .windowList) {
            Button("Get Info") { InfoWindow.show() }.keyboardShortcut("i")
            Divider()
        }
        CommandMenu("Account") {
            ForEach(accounts.accounts) { a in
                Button(a.name + (a.readOnly ? " (view only)" : "")) { accounts.switchTo(a.id) }
                    .disabled(a.id == accounts.currentID)
            }
            Divider()
            Button("Add Another Account…") { LoginWindow.show() }
            Button("Reload") { Task { await lib.load() } }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
