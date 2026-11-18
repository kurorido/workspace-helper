import Foundation

public func normalizePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return lexicalNormalize(expanded)
}

public func relativePath(from baseDirectory: String, to target: String) -> String {
    let base = pathComponents(baseDirectory)
    let destination = pathComponents(target)
    var index = 0
    while index < base.count && index < destination.count && base[index] == destination[index] {
        index += 1
    }
    let upward = Array(repeating: "..", count: base.count - index)
    let parts = upward + destination[index...]
    if parts.isEmpty { return "." }
    return parts.joined(separator: "/")
}

public func pathComponents(_ path: String) -> [String] {
    normalizePath(path).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

public func automaticFolderName(for path: String, avoiding taken: Set<String>) -> String {
    let parts = pathComponents(path)
    let usable = parts.isEmpty ? [normalizePath(path)] : parts
    for length in 1...usable.count {
        let name = usable.suffix(length).joined(separator: "/")
        if !nameIsTaken(name, taken) { return name }
    }
    let base = usable.joined(separator: "/")
    var index = 2
    var candidate = "\(base) (\(index))"
    while nameIsTaken(candidate, taken) {
        index += 1
        candidate = "\(base) (\(index))"
    }
    return candidate
}

public enum PathKind: Equatable {
    case folder
    case workspaceFile
    case missing
    case notFolder
}

public func classifyPath(_ path: String) -> PathKind {
    let normalized = normalizePath(path)
    var isDirectory = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory)
    if !exists { return .missing }
    if isDirectory.boolValue { return .folder }
    if normalized.lowercased().hasSuffix(".code-workspace") { return .workspaceFile }
    return .notFolder
}

public struct DropPlan: Equatable {
    public var workspacePath: String?
    public var folderPaths: [String]
    public var rejected: [String]
    public var multipleWorkspaces: Bool
}

public func planDrop(_ paths: [String]) -> DropPlan {
    var workspaces: [String] = []
    var folders: [String] = []
    var rejected: [String] = []
    for raw in paths {
        let path = normalizePath(raw)
        switch classifyPath(path) {
        case .folder:
            if folders.contains(where: { pathsMatch($0, path) }) { continue }
            folders.append(path)
        case .workspaceFile:
            if !workspaces.contains(where: { pathsMatch($0, path) }) {
                workspaces.append(path)
            }
        case .missing, .notFolder:
            rejected.append(path)
        }
    }
    if workspaces.count > 1 {
        return DropPlan(workspacePath: nil, folderPaths: [], rejected: rejected, multipleWorkspaces: true)
    }
    return DropPlan(
        workspacePath: workspaces.first,
        folderPaths: folders,
        rejected: rejected,
        multipleWorkspaces: false
    )
}

public func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = normalizePath(lhs)
    let right = normalizePath(rhs)
    if left.caseInsensitiveCompare(right) == .orderedSame { return true }
    let leftURL = URL(fileURLWithPath: left)
    let rightURL = URL(fileURLWithPath: right)
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    if let leftID = try? leftURL.resourceValues(forKeys: keys).fileResourceIdentifier,
       let rightID = try? rightURL.resourceValues(forKeys: keys).fileResourceIdentifier {
        return (leftID as AnyObject).isEqual(rightID)
    }
    return false
}

public func pathFromDropItem(_ item: Any?) -> String? {
    guard let item else { return nil }
    if let url = item as? URL, url.isFileURL { return url.path }
    if let url = item as? NSURL, url.isFileURL { return url.path }
    if let data = item as? Data {
        if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
            return url.path
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let url = URL(string: text), url.isFileURL { return url.path }
            if text.hasPrefix("/") { return text }
        }
    }
    if let text = item as? String {
        if let url = URL(string: text), url.isFileURL { return url.path }
        if text.hasPrefix("/") { return text }
    }
    return nil
}

public func defaultSaveDirectory(for folderPaths: [String]) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let desktop = (home as NSString).appendingPathComponent("Desktop")
    let fallback = directoryExists(desktop) ? desktop : home
    let folders = folderPaths.map(normalizePath)
    if folders.count == 1 {
        let parent = URL(fileURLWithPath: folders[0]).deletingLastPathComponent().path
        return directoryExists(parent) ? parent : fallback
    }
    guard var common = commonDirectory(of: folders) else { return fallback }
    while common != "/" && !directoryExists(common) {
        let parent = URL(fileURLWithPath: common).deletingLastPathComponent().path
        if parent == common { break }
        common = parent
    }
    return directoryExists(common) ? common : fallback
}

public func abbreviateHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    let prefix = home.hasSuffix("/") ? home : home + "/"
    if path.hasPrefix(prefix) {
        return "~/" + path.dropFirst(prefix.count)
    }
    return path
}

public func writeTextAtomically(_ text: String, to path: String) throws {
    let destination = URL(fileURLWithPath: path)
    let directory = destination.deletingLastPathComponent()
    guard directoryExists(directory.path) else {
        throw WorkspaceError("找不到目錄：\(directory.path)")
    }
    let temporary = directory.appendingPathComponent(
        ".\(destination.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp"
    )
    do {
        try text.write(to: temporary, atomically: false, encoding: .utf8)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    } catch let error as WorkspaceError {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw WorkspaceError("無法寫入檔案：\(path)\n\(error.localizedDescription)")
    }
    if FileManager.default.fileExists(atPath: temporary.path) {
        try? FileManager.default.removeItem(at: temporary)
    }
}

func directoryExists(_ path: String) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}

private func lexicalNormalize(_ path: String) -> String {
    let isAbsolute = path.hasPrefix("/")
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    var stack: [String] = []
    for part in parts {
        if part == "." { continue }
        if part == ".." {
            if let last = stack.last, last != ".." {
                stack.removeLast()
            } else if !isAbsolute {
                stack.append("..")
            }
            continue
        }
        stack.append(String(part))
    }
    if isAbsolute {
        return "/" + stack.joined(separator: "/")
    }
    if stack.isEmpty { return "." }
    return stack.joined(separator: "/")
}

private func nameIsTaken(_ name: String, _ taken: Set<String>) -> Bool {
    taken.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
}

private func commonDirectory(of paths: [String]) -> String? {
    let componentLists = paths.map { pathComponents($0) }
    guard var shared = componentLists.first else { return nil }
    for components in componentLists.dropFirst() {
        var prefix: [String] = []
        for pair in zip(shared, components) {
            if pair.0 != pair.1 { break }
            prefix.append(pair.0)
        }
        shared = prefix
    }
    if shared.isEmpty { return "/" }
    return "/" + shared.joined(separator: "/")
}
