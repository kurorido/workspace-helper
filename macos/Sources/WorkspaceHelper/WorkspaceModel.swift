import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceCore

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var editor = WorkspaceEditor() {
        didSet { syncChrome() }
    }
    @Published var statusMessage = ""
    @Published var alertMessage: String?

    private weak var window: NSWindow?
    private var closeProxy: WindowDelegateProxy?
    private var allowClose = false

    var windowTitle: String {
        guard let source = editor.sourcePath else { return "未命名工作區" }
        return URL(fileURLWithPath: source).lastPathComponent
    }

    var windowSubtitle: String {
        if let source = editor.sourcePath {
            return abbreviateHome(source)
        }
        return "拖入資料夾，或拖入現有的工作區檔來修改"
    }

    var canSave: Bool { editor.isDirty && !editor.folders.isEmpty }
    var canSaveAs: Bool { !editor.folders.isEmpty }
    var canOpenInEditor: Bool { editor.sourcePath != nil || !editor.folders.isEmpty }
    var missingCount: Int { editor.folders.filter(\.missing).count }

    func attach(window: NSWindow) {
        if window.delegate !== closeProxy {
            let proxy = WindowDelegateProxy()
            proxy.original = window.delegate
            proxy.shouldClose = { [weak self] in
                guard let self else { return true }
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { self.confirmClose() }
                }
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self.confirmClose() }
                }
            }
            closeProxy = proxy
            window.delegate = proxy
        }
        self.window = window
        syncChrome()
    }

    func accept(paths: [String]) {
        let plan = planDrop(paths)
        if plan.multipleWorkspaces {
            alertMessage = "一次只能開啟一個工作區檔。"
            return
        }
        if let workspace = plan.workspacePath {
            let apply = {
                self.applyOpen(path: workspace, folders: plan.folderPaths, rejected: plan.rejected.count)
            }
            if editor.isDirty {
                confirmDiscard(then: apply)
            } else {
                apply()
            }
            return
        }
        let imported = update { $0.addFolders(plan.folderPaths) }
        statusMessage = describe(opened: nil, imported: imported, rejected: plan.rejected.count)
    }

    func newWorkspace() {
        let reset = {
            self.allowClose = false
            self.update { $0.newDocument() }
            self.statusMessage = "已建立新的工作區。"
        }
        if editor.isDirty {
            confirmDiscard(then: reset)
        } else {
            reset()
        }
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "加入"
        panel.message = "選擇要加入工作區的資料夾，可以多選。"
        guard panel.runModal() == .OK else { return }
        accept(paths: panel.urls.map(\.path))
    }

    func openWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.prompt = "開啟"
        panel.message = "選擇要修改的 .code-workspace"
        if let type = UTType(filenameExtension: "code-workspace") {
            panel.allowedContentTypes = [type, .json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(paths: [url.path])
    }

    func save() {
        _ = saveInteractively(forcePrompt: false)
    }

    func saveAs() {
        _ = saveInteractively(forcePrompt: true)
    }

    func openInEditor(_ editorApp: ExternalEditor) {
        if editor.sourcePath == nil || editor.isDirty {
            guard saveInteractively(forcePrompt: editor.sourcePath == nil) else { return }
        }
        guard let path = editor.sourcePath else { return }
        launch(path, with: editorApp)
    }

    func remove(id: UUID) {
        update { $0.remove(id: id) }
        statusMessage = ""
    }

    func rename(id: UUID, to name: String) {
        update { $0.rename(id: id, to: name) }
    }

    func moveUp(id: UUID) { update { $0.moveUp(id: id) } }
    func moveDown(id: UUID) { update { $0.moveDown(id: id) } }
    func move(from offsets: IndexSet, to destination: Int) {
        update { $0.move(from: offsets, to: destination) }
    }

    func setAbsolutePaths(_ value: Bool) {
        update { $0.setUseAbsolutePaths(value) }
    }

    func reveal(path: String) {
        let url = URL(fileURLWithPath: path)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            alertMessage = "找不到這個資料夾。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !accepted.isEmpty else { return false }
        let collector = DropCollector()
        let group = DispatchGroup()
        for (index, provider) in accepted.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let path = pathFromDropItem(item) {
                    collector.add(index: index, path: path)
                }
            }
        }
        group.notify(queue: .main) {
            let paths = collector.paths()
            MainActor.assumeIsolated {
                if paths.isEmpty {
                    self.statusMessage = "無法讀取拖放的項目，請改用「加入資料夾」。"
                } else {
                    self.accept(paths: paths)
                }
            }
        }
        return true
    }

    private func applyOpen(path: String, folders: [String], rejected: Int) {
        var copy = editor
        do {
            try copy.load(from: path)
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? "無法開啟工作區。"
            return
        }
        let imported = copy.addFolders(folders)
        allowClose = false
        editor = copy
        statusMessage = describe(opened: path, imported: imported, rejected: rejected)
    }

    private func update(_ body: (inout WorkspaceEditor) -> Void) {
        var copy = editor
        body(&copy)
        editor = copy
    }

    @discardableResult
    private func update(_ body: (inout WorkspaceEditor) -> FolderImportResult) -> FolderImportResult {
        var copy = editor
        let result = body(&copy)
        editor = copy
        return result
    }

    @discardableResult
    private func saveInteractively(forcePrompt: Bool) -> Bool {
        guard !editor.folders.isEmpty else {
            alertMessage = "至少需要一個資料夾。"
            return false
        }
        let path: String
        if !forcePrompt, let existing = editor.sourcePath {
            path = existing
        } else if let chosen = chooseSaveURL() {
            path = chosen
        } else {
            return false
        }
        return write(to: path)
    }

    private func chooseSaveURL() -> String? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.prompt = "儲存"
        panel.message = "選擇 .code-workspace 的儲存位置"
        panel.nameFieldStringValue = editor.suggestedFileName()
        panel.directoryURL = URL(fileURLWithPath: editor.suggestedDirectory(), isDirectory: true)
        if let type = UTType(filenameExtension: "code-workspace") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        var path = url.path
        if !path.lowercased().hasSuffix(".code-workspace") {
            path += ".code-workspace"
        }
        return path
    }

    private func write(to path: String) -> Bool {
        do {
            try writeTextAtomically(editor.renderedText(for: path), to: path)
            update { $0.markSaved(to: path) }
            statusMessage = "已儲存 \(abbreviateHome(path))"
            return true
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? "無法儲存工作區。"
            return false
        }
    }

    private func confirmDiscard(then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "要放棄尚未儲存的變更嗎？"
        alert.informativeText = "目前的資料夾清單還沒寫入工作區檔。"
        alert.addButton(withTitle: "放棄變更")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        action()
    }

    private func confirmClose() -> Bool {
        if allowClose || !editor.isDirty { return true }
        let alert = NSAlert()
        alert.messageText = "要儲存對工作區的變更嗎？"
        alert.informativeText = "如果不儲存，這次加入或移除的資料夾不會寫入檔案。"
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "不儲存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard saveInteractively(forcePrompt: false) else { return false }
            allowClose = true
            return true
        case .alertSecondButtonReturn:
            allowClose = true
            return true
        default:
            return false
        }
    }

    private func launch(_ path: String, with editorApp: ExternalEditor) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: editorApp.bundleID) != nil {
            process.arguments = ["-b", editorApp.bundleID, path]
        } else {
            process.arguments = ["-a", editorApp.appName, path]
        }
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                alertMessage = "無法用 \(editorApp.title) 開啟。"
            }
        } catch {
            alertMessage = "無法用 \(editorApp.title) 開啟。"
        }
    }

    private func describe(opened: String?, imported: FolderImportResult, rejected: Int) -> String {
        var parts: [String] = []
        if let opened {
            parts.append("已開啟 \(URL(fileURLWithPath: opened).lastPathComponent)")
        }
        if imported.added > 0 {
            parts.append("已加入 \(imported.added) 個資料夾")
        }
        if imported.duplicates > 0 {
            parts.append("略過 \(imported.duplicates) 個重複")
        }
        let skipped = rejected + imported.rejected
        if skipped > 0 {
            parts.append("略過 \(skipped) 個無法加入的項目")
        }
        let missing = editor.folders.filter(\.missing).count
        if opened != nil && missing > 0 {
            parts.append("\(missing) 個資料夾目前找不到")
        }
        if parts.isEmpty { return "沒有可加入的項目" }
        return parts.joined(separator: "，") + "。"
    }

    private func syncChrome() {
        guard let window else { return }
        window.isDocumentEdited = editor.isDirty
        window.representedURL = editor.sourcePath.map { URL(fileURLWithPath: $0) }
    }
}

private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, String)] = []

    func add(index: Int, path: String) {
        lock.lock()
        values.append((index, path))
        lock.unlock()
    }

    func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    var shouldClose: () -> Bool = { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return true }
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
