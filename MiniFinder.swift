// 迷你 Finder：浮在最上層的小面板，自動切到目前正在編輯的檔案所在資料夾
import AppKit
import ApplicationServices
import ServiceManagement

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// 標題區：雙擊收合／展開，單擊拖曳就移動面板
final class HeaderView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}

final class RowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

enum SortMode: String {
    case name, modified
}

struct Entry {
    let url: URL
    let isDir: Bool
    let modified: Date
}

final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let panel: FloatingPanel
    let table = NSTableView()
    let scroll = NSScrollView()
    let titleButton = NSButton()
    let statusLabel = NSTextField(labelWithString: "")
    let emptyLabel = NSTextField(wrappingLabelWithString: "")
    var followButton: NSButton!
    var sortButton: NSButton!
    let divider = NSBox()
    let header = HeaderView()
    var collapsed = false
    var sortMode = SortMode(rawValue: UserDefaults.standard.string(forKey: "sortMode") ?? "") ?? .name

    var folder: URL?
    var currentFile: URL?
    var entries: [Entry] = []
    var lastDetected: URL?
    var following = true
    var wasTrusted = AXIsProcessTrusted()
    let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    override init() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 360),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        panel.title = "迷你 Finder"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            panel.standardWindowButton($0)?.isHidden = true
        }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 180, height: 200)
        buildUI()
        if !panel.setFrameUsingName("MiniFinderPanelV2") {
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 256, y: screen.maxY - 376))
            }
        }
        panel.setFrameAutosaveName("MiniFinderPanelV2")
        if UserDefaults.standard.bool(forKey: "collapsed") {
            setCollapsed(true)
        } else if panel.frame.height < panel.minSize.height {
            // 記住的位置是收合時的高度（例如收合中被強制結束），展開回原本高度
            collapsed = true
            setCollapsed(false)
        }
    }

    func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    func buildUI() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        titleButton.isBordered = false
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.font = .systemFont(ofSize: 13, weight: .semibold)
        titleButton.imagePosition = .imageLeading
        titleButton.imageHugsTitle = true
        titleButton.toolTip = "點一下看上層資料夾"
        titleButton.target = self
        titleButton.action = #selector(showAncestors)
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let upButton = iconButton("arrow.up", "上一層", #selector(goUp))
        followButton = iconButton("location.fill", "自動跟隨", #selector(toggleFollow))
        let finderButton = iconButton("arrow.up.forward.square", "在 Finder 打開", #selector(openInFinder))
        let hideButton = iconButton("xmark", "隱藏面板（選單列圖示可再叫出）", #selector(hidePanel))
        sortButton = iconButton("textformat", "排序", #selector(toggleSort))
        updateFollowButton()
        updateSortButton()

        let toolbar = NSStackView(views: [sortButton, upButton, followButton, finderButton, hideButton])
        toolbar.spacing = 0
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let menu = NSMenu()
        menu.addItem(withTitle: "打開", action: #selector(openSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "在 Finder 中顯示", action: #selector(revealSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "拷貝路徑", action: #selector(copyPath), keyEquivalent: "").target = self
        table.menu = menu

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        header.onDoubleClick = { [weak self] in self?.toggleCollapsed() }
        header.toolTip = "雙擊收合／展開"
        header.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // 狀態列放在標題區裡，雙擊那一行字也能收合
        header.addSubview(statusLabel)
        [header, titleButton, toolbar, divider, scroll, emptyLabel].forEach(background.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: divider.topAnchor),

            titleButton.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            titleButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            titleButton.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.leadingAnchor, constant: -4),

            toolbar.centerYAnchor.constraint(equalTo: titleButton.centerYAnchor),
            toolbar.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),

            statusLabel.topAnchor.constraint(equalTo: titleButton.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 11),
            statusLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -11),

            divider.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),

            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
        ])
        showStatus()
    }

    // MARK: 偵測目前編輯中的檔案

    func detectFrontDocument() -> URL? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        var docRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &docRef) == .success,
              let doc = docRef as? String, let url = URL(string: doc), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    func tick() {
        // 權限是在面板開著時才勾的話，狀態列要跟著更新
        let trusted = AXIsProcessTrusted()
        if trusted != wasTrusted {
            wasTrusted = trusted
            lastDetected = nil
            showStatus()
        }
        if following, let doc = detectFrontDocument(), doc != lastDetected {
            lastDetected = doc
            currentFile = doc
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: doc.path, isDirectory: &isDir)
            show(folder: isDir.boolValue ? doc : doc.deletingLastPathComponent())
            return
        }
        reloadIfChanged()
    }

    // MARK: 資料夾內容

    func show(folder newFolder: URL) {
        folder = newFolder
        titleButton.title = FileManager.default.displayName(atPath: newFolder.path)
        let icon = NSWorkspace.shared.icon(forFile: newFolder.path)
        icon.size = NSSize(width: 16, height: 16)
        titleButton.image = icon
        titleButton.toolTip = newFolder.path
        entries = listing(of: newFolder)
        table.reloadData()
        selectCurrentFile()
        showStatus()
    }

    func listing(of dir: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            return Entry(url: url, isDir: isDir, modified: v?.contentModificationDate ?? .distantPast)
        }.sorted(by: sortOrder)
    }

    // 依名稱：資料夾在前；依修改時間：不分資料夾，最新的在最上面
    func sortOrder(_ a: Entry, _ b: Entry) -> Bool {
        switch sortMode {
        case .name:
            if a.isDir != b.isDir { return a.isDir }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        case .modified:
            return a.modified > b.modified
        }
    }

    func reloadIfChanged() {
        guard let folder else { return }
        let fresh = listing(of: folder)
        let changed = fresh.count != entries.count
            || zip(fresh, entries).contains { $0.url != $1.url || $0.modified != $1.modified }
        guard changed else { return }
        let selected = Set(table.selectedRowIndexes.map { entries[$0].url })
        entries = fresh
        table.reloadData()
        let rows = IndexSet(entries.indices.filter { selected.contains(entries[$0].url) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        showStatus()
    }

    func selectCurrentFile() {
        guard let currentFile, let row = entries.firstIndex(where: { $0.url.standardizedFileURL == currentFile }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func showStatus() {
        let trusted = AXIsProcessTrusted()
        if folder == nil {
            titleButton.title = "迷你 Finder"
            titleButton.image = nil
            statusLabel.stringValue = trusted ? "等待中" : "尚未取得權限"
            emptyLabel.stringValue = trusted
                ? "切到一個開著檔案的視窗，這裡就會顯示它的資料夾"
                : "到系統設定 → 輔助使用，打開「迷你 Finder」才能自動跟隨"
        } else {
            if let currentFile, currentFile.deletingLastPathComponent() == folder {
                statusLabel.stringValue = "正在編輯 \(currentFile.lastPathComponent)"
            } else {
                statusLabel.stringValue = "\(entries.count) 個項目"
            }
            emptyLabel.stringValue = entries.isEmpty ? "資料夾是空的" : ""
        }
        emptyLabel.isHidden = collapsed || emptyLabel.stringValue.isEmpty
    }

    func updateSortButton() {
        let symbol = sortMode == .modified ? "clock" : "textformat"
        sortButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "排序")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        sortButton.contentTintColor = sortMode == .modified ? .controlAccentColor : .secondaryLabelColor
        sortButton.toolTip = sortMode == .modified ? "依修改時間排序（點一下改依名稱）" : "依名稱排序（點一下改依修改時間）"
    }

    func updateFollowButton() {
        let symbol = following ? "location.fill" : "location.slash"
        followButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "自動跟隨")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        followButton.contentTintColor = following ? .controlAccentColor : .secondaryLabelColor
        followButton.toolTip = following ? "自動跟隨：開（點一下關閉）" : "自動跟隨：關（點一下開啟）"
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let id = NSUserInterfaceItemIdentifier("name")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id: id)
        let isCurrent = entry.url.standardizedFileURL == currentFile
        cell.textField?.stringValue = entry.url.lastPathComponent
        cell.textField?.font = isCurrent ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        cell.toolTip = entry.modified == .distantPast
            ? entry.url.lastPathComponent
            : "\(entry.url.lastPathComponent)\n修改時間 \(dateFormatter.string(from: entry.modified))"
        return cell
    }

    func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 11),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -11),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // 拖曳：把檔案本身放到剪貼簿，拖到哪裡都等於拖檔案
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        entries[row].url as NSURL
    }

    // MARK: 動作

    var selectedURLs: [URL] {
        let clicked = table.clickedRow
        if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) { return [entries[clicked].url] }
        return table.selectedRowIndexes.map { entries[$0].url }
    }

    func browse(to url: URL) {
        following = false
        updateFollowButton()
        show(folder: url)
    }

    @objc func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        let entry = entries[row]
        if entry.isDir {
            browse(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    @objc func openSelected() { selectedURLs.forEach { NSWorkspace.shared.open($0) } }

    @objc func revealSelected() { NSWorkspace.shared.activateFileViewerSelecting(selectedURLs) }

    @objc func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedURLs.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc func openInFinder() {
        guard let folder else { return }
        if let currentFile, currentFile.deletingLastPathComponent() == folder {
            NSWorkspace.shared.activateFileViewerSelecting([currentFile])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    @objc func goUp() {
        guard let folder, folder.path != "/" else { return }
        browse(to: folder.deletingLastPathComponent())
    }

    // 點資料夾名稱：列出每一層上層資料夾，點了就跳過去
    @objc func showAncestors() {
        guard let folder else { return }
        let menu = NSMenu()
        var url = folder
        while true {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path),
                                  action: #selector(ancestorPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: titleButton.bounds.height + 4), in: titleButton)
    }

    @objc func ancestorPicked(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        browse(to: url)
    }

    @objc func toggleFollow() {
        following.toggle()
        updateFollowButton()
        if following {
            lastDetected = nil
            tick()
        }
    }

    @objc func hidePanel() { panel.orderOut(nil) }

    @objc func toggleSort() {
        sortMode = sortMode == .name ? .modified : .name
        UserDefaults.standard.set(sortMode.rawValue, forKey: "sortMode")
        updateSortButton()
        let selected = Set(table.selectedRowIndexes.map { entries[$0].url })
        entries.sort(by: sortOrder)
        table.reloadData()
        let rows = IndexSet(entries.indices.filter { selected.contains(entries[$0].url) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) } else { table.scrollRowToVisible(0) }
    }

    // MARK: 收合

    func toggleCollapsed() { setCollapsed(!collapsed) }

    // 收合時只留標題區，上緣位置不動，往上縮
    func setCollapsed(_ value: Bool) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let headerHeight = content.bounds.height - divider.frame.minY
        var frame = panel.frame
        if value {
            // 啟動時還原的是收合後的高度，不能當成展開高度存起來
            if frame.height > headerHeight + 1 {
                UserDefaults.standard.set(frame.height, forKey: "expandedHeight")
            }
            panel.minSize = NSSize(width: 180, height: headerHeight)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: headerHeight)
            frame.origin.y += frame.height - headerHeight
            frame.size.height = headerHeight
        } else {
            let saved = UserDefaults.standard.double(forKey: "expandedHeight")
            let height = max(saved > 0 ? saved : 360, 200)
            panel.minSize = NSSize(width: 180, height: 200)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            frame.origin.y -= height - frame.height
            frame.size.height = height
        }
        collapsed = value
        UserDefaults.standard.set(value, forKey: "collapsed")
        [divider, scroll].forEach { $0.isHidden = value }
        emptyLabel.isHidden = value || emptyLabel.stringValue.isEmpty
        panel.setFrame(frame, display: true, animate: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var controller: PanelController!
    var statusItem: NSStatusItem!
    var loginItem: NSMenuItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PanelController()
        controller.panel.orderFrontRegardless()

        // 第一次啟動會跳出系統詢問，引導到「輔助使用」打勾
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "迷你 Finder")
        let menu = NSMenu()
        menu.addItem(withTitle: "顯示／隱藏面板", action: #selector(togglePanel), keyEquivalent: "").target = self
        loginItem = NSMenuItem(title: "登入時自動開啟", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束迷你 Finder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.controller.tick()
        }
        controller.tick()
        // 測試用：open --args <資料夾> 直接顯示指定資料夾
        if CommandLine.arguments.count > 1 {
            controller.browse(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }

    @objc func togglePanel() {
        if controller.panel.isVisible {
            controller.panel.orderOut(nil)
        } else {
            controller.panel.orderFrontRegardless()
        }
    }

    // MARK: 登入項目（以系統設定裡的登入項目清單為準）

    // 每次打開選單都重讀一次，使用者在系統設定增刪後打勾狀態才會一致
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let enabled = isLoginItemEnabled() else {
            loginItem.state = .off
            loginItem.title = "登入時自動開啟（需允許控制 System Events）"
            return
        }
        loginItem.title = "登入時自動開啟"
        loginItem.state = enabled ? .on : .off
    }

    // nil 表示讀不到（使用者還沒允許迷你 Finder 控制 System Events）
    func isLoginItemEnabled() -> Bool? {
        guard let paths = loginItemPaths() else { return nil }
        return paths.contains(Bundle.main.bundlePath) || SMAppService.mainApp.status == .enabled
    }

    func loginItemPaths() -> [String]? {
        guard let result = runSystemEvents("get path of every login item") else { return nil }
        if result.numberOfItems == 0 { return result.stringValue.map { [$0] } ?? [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }

    func runSystemEvents(_ command: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"System Events\" to \(command)")
        let result = script?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    @objc func toggleLogin() {
        guard let enabled = isLoginItemEnabled() else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            return
        }
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "\"", with: "\\\"")
        if enabled {
            // 兩種登記方式都清掉，避免殘留一筆開機還是會開
            _ = runSystemEvents("delete (every login item whose path is \"\(path)\")")
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        } else {
            _ = runSystemEvents("make login item at end with properties {path:\"\(path)\", hidden:false}")
        }
        if isLoginItemEnabled() == !enabled {
            loginItem.state = enabled ? .off : .on
        } else {
            NSSound.beep()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
