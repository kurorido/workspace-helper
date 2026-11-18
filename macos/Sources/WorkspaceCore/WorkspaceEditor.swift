import Foundation

public struct WorkspaceFolder: Equatable, Identifiable {
    public var id: UUID
    public var path: String
    public var name: String
    public var missing: Bool
    public var additional: [JSONField]

    public init(
        id: UUID = UUID(),
        path: String,
        name: String,
        missing: Bool,
        additional: [JSONField] = []
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.missing = missing
        self.additional = additional
    }
}

public struct LoadedWorkspace: Equatable {
    public var folders: [WorkspaceFolder]
    public var preserved: [JSONField]
    public var useAbsolutePaths: Bool
}

public struct FolderImportResult: Equatable {
    public var added: Int
    public var duplicates: Int
    public var rejected: Int
}

public struct WorkspaceEditor: Equatable {
    public private(set) var folders: [WorkspaceFolder]
    public private(set) var preserved: [JSONField]
    public private(set) var sourcePath: String?
    public private(set) var useAbsolutePaths: Bool
    public private(set) var isDirty: Bool

    public init() {
        folders = []
        preserved = []
        sourcePath = nil
        useAbsolutePaths = false
        isDirty = false
    }

    public mutating func newDocument() {
        self = WorkspaceEditor()
    }

    public mutating func load(from path: String) throws {
        let loaded = try loadWorkspace(from: path)
        folders = loaded.folders
        preserved = loaded.preserved
        sourcePath = normalizePath(path)
        useAbsolutePaths = loaded.useAbsolutePaths
        isDirty = false
    }

    public mutating func addFolders(_ paths: [String]) -> FolderImportResult {
        var added = 0
        var duplicates = 0
        var rejected = 0
        for raw in paths {
            let path = normalizePath(raw)
            guard classifyPath(path) == .folder else {
                rejected += 1
                continue
            }
            if folders.contains(where: { pathsMatch($0.path, path) }) {
                duplicates += 1
                continue
            }
            let taken = Set(folders.map(\.name))
            folders.append(
                WorkspaceFolder(
                    path: path,
                    name: automaticFolderName(for: path, avoiding: taken),
                    missing: false
                )
            )
            added += 1
        }
        if added > 0 { isDirty = true }
        return FolderImportResult(added: added, duplicates: duplicates, rejected: rejected)
    }

    public mutating func remove(id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders.remove(at: index)
        isDirty = true
    }

    public mutating func rename(id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty
            ? URL(fileURLWithPath: folders[index].path).lastPathComponent
            : trimmed
        guard resolved != folders[index].name else { return }
        folders[index].name = resolved
        isDirty = true
    }

    public mutating func moveUp(id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }), index > 0 else { return }
        folders.swapAt(index, index - 1)
        isDirty = true
    }

    public mutating func moveDown(id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }), index < folders.count - 1 else { return }
        folders.swapAt(index, index + 1)
        isDirty = true
    }

    public mutating func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().map { folders[$0] }
        var updated = folders
        for index in offsets.sorted(by: >) {
            updated.remove(at: index)
        }
        let insertion = destination - offsets.filter { $0 < destination }.count
        let bounded = min(max(0, insertion), updated.count)
        updated.insert(contentsOf: moving, at: bounded)
        guard updated.map(\.id) != folders.map(\.id) else { return }
        folders = updated
        isDirty = true
    }

    public mutating func setUseAbsolutePaths(_ value: Bool) {
        guard value != useAbsolutePaths else { return }
        useAbsolutePaths = value
        isDirty = true
    }

    public func renderedText(for outputPath: String) -> String {
        let directory = URL(fileURLWithPath: outputPath).deletingLastPathComponent().path
        let folderValues = folders.map { folder -> JSONValue in
            let storedPath = useAbsolutePaths
                ? normalizePath(folder.path)
                : relativePath(from: directory, to: folder.path)
            let trimmed = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty
                ? URL(fileURLWithPath: folder.path).lastPathComponent
                : trimmed
            var fields: [JSONField] = [
                JSONField("path", .string(storedPath)),
                JSONField("name", .string(name)),
            ]
            for entry in folder.additional where entry.name != "path" && entry.name != "name" {
                fields.append(entry)
            }
            return .object(fields)
        }
        var fields: [JSONField] = [JSONField("folders", .array(folderValues))]
        let extras = preserved.filter { $0.name != "folders" }
        if extras.isEmpty {
            fields.append(JSONField("settings", .object([])))
        } else {
            fields.append(contentsOf: extras)
        }
        return renderJSON(.object(fields)) + "\n"
    }

    public mutating func markSaved(to path: String) {
        sourcePath = normalizePath(path)
        isDirty = false
    }

    public func suggestedDirectory() -> String {
        if let sourcePath {
            let parent = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path
            if directoryExists(parent) { return parent }
        }
        return defaultSaveDirectory(for: folders.map(\.path))
    }

    public func suggestedFileName() -> String {
        if let sourcePath {
            let name = URL(fileURLWithPath: sourcePath).lastPathComponent
            if !name.isEmpty { return name }
        }
        if folders.count == 1 {
            let base = URL(fileURLWithPath: folders[0].path).lastPathComponent
            if !base.isEmpty {
                return base.lowercased().hasSuffix(".code-workspace") ? base : base + ".code-workspace"
            }
        }
        return "workspace.code-workspace"
    }
}

public func loadWorkspace(from path: String) throws -> LoadedWorkspace {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw WorkspaceError("無法讀取檔案：\(path)")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw WorkspaceError("無法用 UTF-8 讀取檔案：\(path)")
    }
    let root: JSONValue
    do {
        root = try parseJSON(text)
    } catch let error as WorkspaceError {
        throw error
    } catch {
        throw WorkspaceError("工作區內容不是有效的 JSON。")
    }
    guard let pairs = root.object else {
        throw WorkspaceError("工作區檔的最外層必須是一個物件。")
    }
    let folderValue = pairs.last { $0.name == "folders" }?.value
    let entries: [JSONValue]
    if let folderValue {
        guard let array = folderValue.array else {
            throw WorkspaceError("folders 必須是陣列。")
        }
        entries = array
    } else {
        entries = []
    }

    var drafts: [FolderDraft] = []
    for (offset, entry) in entries.enumerated() {
        guard let object = entry.object else {
            throw WorkspaceError("第 \(offset + 1) 個資料夾格式不正確。")
        }
        guard object.contains(where: { $0.name == "path" }) else {
            throw WorkspaceError("第 \(offset + 1) 個資料夾缺少 path。")
        }
        guard let storedPath = object.last(where: { $0.name == "path" })?.value.string else {
            throw WorkspaceError("第 \(offset + 1) 個資料夾的 path 必須是文字。")
        }
        if object.contains(where: { $0.name == "name" }),
           object.last(where: { $0.name == "name" })?.value.string == nil {
            throw WorkspaceError("第 \(offset + 1) 個資料夾的 name 必須是文字。")
        }
        let explicit = object.last(where: { $0.name == "name" })?.value.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = resolveStoredPath(storedPath, workspaceFile: path)
        drafts.append(
            FolderDraft(
                rawPath: storedPath,
                path: resolved,
                explicitName: (explicit?.isEmpty == false) ? explicit : nil,
                missing: !isExistingDirectory(resolved),
                additional: object.filter { $0.name != "path" && $0.name != "name" }
            )
        )
    }

    var used = Set<String>()
    let folders = drafts.map { draft -> WorkspaceFolder in
        let name: String
        if let explicit = draft.explicitName {
            name = explicit
        } else {
            name = automaticFolderName(for: draft.path, avoiding: used)
        }
        used.insert(name)
        return WorkspaceFolder(
            path: draft.path,
            name: name,
            missing: draft.missing,
            additional: draft.additional
        )
    }
    let absolute = !drafts.isEmpty && drafts.allSatisfy { isAbsoluteWorkspacePath($0.rawPath) }
    return LoadedWorkspace(
        folders: folders,
        preserved: pairs.filter { $0.name != "folders" },
        useAbsolutePaths: absolute
    )
}

private struct FolderDraft {
    var rawPath: String
    var path: String
    var explicitName: String?
    var missing: Bool
    var additional: [JSONField]
}

private func resolveStoredPath(_ stored: String, workspaceFile: String) -> String {
    let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("file:"), let url = URL(string: trimmed), url.isFileURL {
        return normalizePath(url.path)
    }
    if trimmed.hasPrefix("~") || trimmed.hasPrefix("/") {
        return normalizePath(trimmed)
    }
    let base = URL(fileURLWithPath: workspaceFile).deletingLastPathComponent().path
    let joined = base == "/" ? "/" + trimmed : base + "/" + trimmed
    return normalizePath(joined)
}

private func isAbsoluteWorkspacePath(_ path: String) -> Bool {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("file:")
}

private func isExistingDirectory(_ path: String) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}
