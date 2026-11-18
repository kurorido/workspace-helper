import XCTest
import WorkspaceCore

final class WorkspaceCoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPathNormalizationAndRelativePaths() {
        XCTAssertEqual(normalizePath("/tmp/a/../b"), "/tmp/b")
        XCTAssertEqual(normalizePath("/tmp//a/"), "/tmp/a")
        XCTAssertEqual(normalizePath("~"), FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(relativePath(from: "/tmp/wh", to: "/tmp/wh/alpha"), "alpha")
        XCTAssertEqual(relativePath(from: "/tmp/wh/alpha", to: "/tmp/wh/alpha"), ".")
        XCTAssertEqual(relativePath(from: "/tmp/wh/alpha/nested", to: "/tmp/wh/beta"), "../../beta")
        XCTAssertEqual(automaticFolderName(for: "/work/group/alpha", avoiding: ["alpha"]), "group/alpha")
    }

    func testDropItemAndPlan() throws {
        let alpha = try makeDir("alpha")
        let workspace = try writeFile("team.code-workspace", #"{"folders":[]}"#)
        let readme = try writeFile("readme.txt", "hi")
        let url = URL(fileURLWithPath: alpha)
        XCTAssertEqual(pathFromDropItem(url), url.path)
        XCTAssertEqual(pathFromDropItem(url.dataRepresentation), url.path)

        let plan = planDrop([alpha, alpha, workspace, readme])
        XCTAssertEqual(plan.workspacePath.map(normalizePath), normalizePath(workspace))
        XCTAssertEqual(plan.folderPaths, [normalizePath(alpha)])
        XCTAssertEqual(plan.rejected.count, 1)
        XCTAssertFalse(plan.multipleWorkspaces)

        let second = try writeFile("other.code-workspace", #"{"folders":[]}"#)
        let multiple = planDrop([workspace, second])
        XCTAssertTrue(multiple.multipleWorkspaces)
        XCTAssertNil(multiple.workspacePath)
    }

    func testSymlinkFolderKeepsTheLinkPath() throws {
        let real = try makeDir("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: real))
        XCTAssertEqual(classifyPath(link.path), .folder)
        var editor = WorkspaceEditor()
        let result = editor.addFolders([link.path])
        XCTAssertEqual(result.added, 1)
        XCTAssertTrue(editor.folders[0].path.hasSuffix("/link"))
    }

    func testComposeRelativeWorkspace() throws {
        _ = try makeDir("proj")
        let alpha = try makeDir("proj/alpha")
        let beta = try makeDir("proj/beta")
        var editor = WorkspaceEditor()
        let imported = editor.addFolders([beta, alpha])
        XCTAssertEqual(imported.added, 2)
        XCTAssertEqual(editor.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["beta", "alpha"])
        XCTAssertTrue(editor.isDirty)

        let output = root.appendingPathComponent("proj/dev.code-workspace").path
        let text = editor.renderedText(for: output)
        XCTAssertTrue(text.contains("\n\t\"folders\""))
        XCTAssertTrue(text.contains("\"path\": \"beta\""))
        XCTAssertTrue(text.contains("\"path\": \"alpha\""))
        XCTAssertLessThan(text.range(of: "\"path\": \"beta\"")!.lowerBound, text.range(of: "\"path\": \"alpha\"")!.lowerBound)
        XCTAssertTrue(text.contains("\"settings\": {}"))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("\\u"))

        let inside = root.appendingPathComponent("proj/alpha/inside.code-workspace").path
        let insideValue = try parseJSON(editor.renderedText(for: inside))
        let insidePaths = insideValue.objectValue("folders")?.array?.compactMap { $0.objectValue("path")?.string }
        XCTAssertEqual(insidePaths, ["../beta", "."])
    }

    func testAbsolutePathsSpacesChineseAndDuplicates() throws {
        let spaced = try makeDir("my project")
        let chinese = try makeDir("專案資料")
        var editor = WorkspaceEditor()
        _ = editor.addFolders([spaced, chinese, spaced + "/"])
        XCTAssertEqual(editor.folders.map(\.name), ["my project", "專案資料"])
        editor.setUseAbsolutePaths(true)
        let output = root.appendingPathComponent("out.code-workspace").path
        let text = editor.renderedText(for: output)
        XCTAssertTrue(text.contains(normalizePath(spaced)))
        XCTAssertTrue(text.contains("專案資料"))
        XCTAssertFalse(text.contains("\\u"))
        try writeTextAtomically(text, to: output)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
        let loaded = try loadWorkspace(from: output)
        XCTAssertTrue(loaded.useAbsolutePaths)
        XCTAssertEqual(loaded.folders.map(\.path), [normalizePath(spaced), normalizePath(chinese)])
    }

    func testLoadJSONCPreserveSettingsAndMissingFolder() throws {
        let alpha = try makeDir("alpha")
        let source = """
        {
          // keep me
          "settings": {
            "zebra": 1,
            "alpha": "http://example.com",
            "editor.fontSize": 16
          },
          "folders": [
            {"path": "alpha", "name": "API"},
            {"path": "missing-folder", "name": "a\\"b"},
          ],
          "extensions": {"recommendations": ["ms-python.python"]}
        }
        """
        let file = try writeFile("dev.code-workspace", source)
        var editor = WorkspaceEditor()
        try editor.load(from: file)
        XCTAssertFalse(editor.isDirty)
        XCTAssertFalse(editor.useAbsolutePaths)
        XCTAssertEqual(editor.folders.map(\.name), ["API", "a\"b"])
        XCTAssertEqual(editor.folders.map(\.missing), [false, true])
        XCTAssertEqual(editor.folders[0].path, normalizePath(alpha))

        let group = try makeDir("group/alpha")
        let imported = editor.addFolders([group])
        XCTAssertEqual(imported.added, 1)
        XCTAssertEqual(editor.folders.last?.name, "alpha")
        editor.rename(id: editor.folders[0].id, to: "服務")
        let saved = root.appendingPathComponent("saved.code-workspace").path
        try writeTextAtomically(editor.renderedText(for: saved), to: saved)
        let text = try String(contentsOfFile: saved, encoding: .utf8)
        XCTAssertLessThan(text.range(of: "\"folders\"")!.lowerBound, text.range(of: "\"settings\"")!.lowerBound)
        XCTAssertLessThan(text.range(of: "zebra")!.lowerBound, text.range(of: "http://example.com")!.lowerBound)
        XCTAssertTrue(text.contains("ms-python.python"))
        XCTAssertTrue(text.contains("服務"))
        XCTAssertTrue(text.contains("a\\\"b"))

        let roundTrip = try loadWorkspace(from: saved)
        XCTAssertEqual(roundTrip.folders.map(\.name), ["服務", "a\"b", "alpha"])
        XCTAssertEqual(roundTrip.preserved.first { $0.name == "settings" }?.value.objectValue("editor.fontSize"), .number("16"))
    }

    func testReorderRemoveAndSameFileIdentity() throws {
        let alpha = try makeDir("alpha")
        let beta = try makeDir("beta")
        var editor = WorkspaceEditor()
        _ = editor.addFolders([alpha, beta])
        editor.move(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(editor.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["beta", "alpha"])
        editor.moveUp(id: editor.folders[1].id)
        XCTAssertEqual(editor.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["alpha", "beta"])
        let removed = editor.folders[0].id
        editor.remove(id: removed)
        XCTAssertEqual(editor.folders.count, 1)
        XCTAssertTrue(pathsMatch(alpha, alpha + "/"))
    }

    func testRejectsInvalidWorkspace() throws {
        let file = try writeFile("bad.code-workspace", #"{"folders": {"path": "a"}}"#)
        XCTAssertThrowsError(try loadWorkspace(from: file)) { error in
            XCTAssertTrue(String(describing: error).contains("folders"))
        }
    }

    func testUnicodeEscapeAndCommentsDoNotEatStrings() throws {
        let value = try parseJSON(#""\u4e2d""#)
        XCTAssertEqual(value, .string("中"))
        let object = try parseJSON(#"{"name":"http://example.com"}"#)
        XCTAssertEqual(object.objectValue("name"), .string("http://example.com"))
        XCTAssertEqual(renderJSON(.string("中文")), "\"中文\"")
    }
}

private extension JSONValue {
    func objectValue(_ key: String) -> JSONValue? {
        object?.last { $0.name == key }?.value
    }
}

private extension WorkspaceCoreTests {
    func makeDir(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func writeFile(_ relative: String, _ contents: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
