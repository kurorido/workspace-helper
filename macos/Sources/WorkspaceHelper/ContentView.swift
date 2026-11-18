import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceCore

struct ContentView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var targeted = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    if model.editor.folders.isEmpty {
                        emptyState
                            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                                model.handleDrop(providers)
                            }
                    } else {
                        folderList
                            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                                model.handleDrop(providers)
                            }
                    }
                    if targeted {
                        dropOverlay
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
            .navigationTitle(model.windowTitle)
            .navigationSubtitle(model.windowSubtitle)
            .toolbar { toolbar }
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(WindowAttachment { model.attach(window: $0) })
        .alert(
            "無法完成",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("把資料夾拖到這裡")
                .font(.title2.weight(.semibold))
            Text("可以一次拖進多個資料夾。拖入現有的 .code-workspace 就能直接修改，儲存時寫回原檔，也可以另存到別的位置。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button("加入資料夾…") { model.addFolders() }
                    .buttonStyle(.borderedProminent)
                Button("開啟工作區…") { model.openWorkspace() }
            }
            .padding(.top, 4)
        }
        .padding(32)
    }

    private var folderList: some View {
        List {
            ForEach(model.editor.folders) { folder in
                FolderRow(
                    folder: folder,
                    isFirst: folder.id == model.editor.folders.first?.id,
                    isLast: folder.id == model.editor.folders.last?.id,
                    onRename: { model.rename(id: folder.id, to: $0) },
                    onRemove: { model.remove(id: folder.id) },
                    onMoveUp: { model.moveUp(id: folder.id) },
                    onMoveDown: { model.moveDown(id: folder.id) },
                    onReveal: { model.reveal(path: folder.path) }
                )
            }
            .onMove { model.move(from: $0, to: $1) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("工作區資料夾")
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                Text("放開以加入資料夾或開啟工作區")
                    .font(.title3.weight(.semibold))
            }
            .padding(18)
            .allowsHitTesting(false)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(model.editor.folders.isEmpty ? "尚未加入資料夾" : "\(model.editor.folders.count) 個資料夾")
                    .foregroundStyle(.secondary)
                if model.missingCount > 0 {
                    Text("\(model.missingCount) 個找不到")
                        .foregroundStyle(.red)
                }
                Spacer()
                Text("儲存路徑")
                    .foregroundStyle(.secondary)
                Picker("儲存路徑", selection: absoluteBinding) {
                    Text("相對").tag(false)
                    Text("絕對").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
                .help("相對路徑會跟著工作區檔移動；絕對路徑固定指向原來的資料夾。")
            }
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.addFolders() } label: {
                Label("加入資料夾", systemImage: "folder.badge.plus")
            }
            .help("加入資料夾")
            Button { model.openWorkspace() } label: {
                Label("開啟工作區", systemImage: "doc")
            }
            .help("開啟現有的 .code-workspace")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Cursor") { model.openInEditor(.cursor) }
                Button("VS Code") { model.openInEditor(.code) }
            } label: {
                Label("用編輯器開啟", systemImage: "arrow.up.forward.app")
            }
            .disabled(!model.canOpenInEditor)
            Button { model.saveAs() } label: {
                Label("另存新檔", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.canSaveAs)
            .help("存到另一個位置")
            Button { model.save() } label: {
                Label("儲存", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(!model.canSave)
            .help(model.editor.sourcePath == nil ? "選擇儲存位置" : "寫回目前的工作區檔")
        }
    }

    private var absoluteBinding: Binding<Bool> {
        Binding(
            get: { model.editor.useAbsolutePaths },
            set: { model.setAbsolutePaths($0) }
        )
    }
}

private struct FolderRow: View {
    let folder: WorkspaceFolder
    let isFirst: Bool
    let isLast: Bool
    var onRename: (String) -> Void
    var onRemove: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onReveal: () -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                TextField("名稱", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($focused)
                    .onSubmit(commit)
                Text(abbreviateHome(folder.path))
                    .font(.caption)
                    .foregroundStyle(folder.missing ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if folder.missing {
                Text("找不到")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.red.opacity(0.12), in: Capsule())
                    .foregroundStyle(.red)
            }
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("從工作區移除")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("在 Finder 中顯示", action: onReveal)
            Divider()
            Button("上移", action: onMoveUp).disabled(isFirst)
            Button("下移", action: onMoveDown).disabled(isLast)
            Divider()
            Button("移除", action: onRemove)
        }
        .onAppear { name = folder.name }
        .onChange(of: folder.id) { _, _ in name = folder.name }
        .onChange(of: folder.name) { _, newValue in
            if !focused { name = newValue }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private var icon: NSImage {
        if folder.missing {
            return NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: folder.path)
    }

    private func commit() {
        onRename(name)
    }
}

private struct WindowAttachment: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onWindow(window) }
        }
    }
}
