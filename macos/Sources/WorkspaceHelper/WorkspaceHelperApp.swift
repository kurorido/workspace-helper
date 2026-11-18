import AppKit
import SwiftUI
import WorkspaceCore

@main
struct WorkspaceHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        Window("工作區幫手", id: "main") {
            ContentView(model: model)
                .onAppear {
                    delegate.setHandler { urls in
                        model.accept(paths: urls.map(\.path))
                    }
                }
                .onOpenURL { url in
                    delegate.deliver([url])
                }
        }
        .defaultSize(width: 820, height: 600)
        .commands {
            WorkspaceCommands(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private var handler: (([URL]) -> Void)?
    private var pending: [URL] = []
    private var buffer: [URL] = []
    private var coalesce: DispatchWorkItem?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        deliver(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        deliver(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func setHandler(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        guard !pending.isEmpty else { return }
        let urls = pending
        pending = []
        handler(urls)
    }

    func deliver(_ urls: [URL]) {
        buffer.append(contentsOf: urls)
        coalesce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.buffer
            self.buffer = []
            if let handler = self.handler {
                handler(batch)
            } else {
                self.pending.append(contentsOf: batch)
            }
        }
        coalesce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

struct WorkspaceCommands: Commands {
    @ObservedObject var model: WorkspaceModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新工作區") { model.newWorkspace() }
                .keyboardShortcut("n")
            Button("開啟工作區…") { model.openWorkspace() }
                .keyboardShortcut("o")
            Button("加入資料夾…") { model.addFolders() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("用 Cursor 開啟") { model.openInEditor(.cursor) }
                .disabled(!model.canOpenInEditor)
            Button("用 VS Code 開啟") { model.openInEditor(.code) }
                .disabled(!model.canOpenInEditor)
        }
        CommandGroup(replacing: .saveItem) {
            Button("儲存") { model.save() }
                .keyboardShortcut("s")
                .disabled(!model.canSave)
            Button("另存新檔…") { model.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.canSaveAs)
        }
    }
}

enum ExternalEditor {
    case cursor
    case code

    var bundleID: String {
        switch self {
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .code: "com.microsoft.VSCode"
        }
    }

    var appName: String {
        switch self {
        case .cursor: "Cursor"
        case .code: "Visual Studio Code"
        }
    }

    var title: String {
        switch self {
        case .cursor: "Cursor"
        case .code: "VS Code"
        }
    }
}
