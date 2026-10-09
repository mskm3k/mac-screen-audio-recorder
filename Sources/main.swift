import AppKit
import Foundation
import ScreenCaptureKit
import CoreGraphics

private enum CaptureMode: Int {
    case display = 0
    case window = 1
    case region = 2

    var label: String {
        switch self {
        case .display: return "全画面"
        case .window: return "ウィンドウ"
        case .region: return "範囲指定"
        }
    }
}

private enum DefaultsKey {
    static let saveFolder = "saveFolder"
    static let captureMode = "captureMode"
    static let regionX = "captureRegion.x"
    static let regionY = "captureRegion.y"
    static let regionWidth = "captureRegion.width"
    static let regionHeight = "captureRegion.height"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2"
    }

    private var appTitle: String {
        "Mac Screen Audio Recorder v\(appVersion)"
    }

    private let recorder = RecorderEngine()
    private let regionSelector = RegionSelector()

    private var window: NSWindow!
    private var recordButton: NSButton!
    private var statusLabel: NSTextField!
    private var folderLabel: NSTextField!
    private var chooseFolderButton: NSButton!
    private var revealButton: NSButton!
    private var modeControl: NSSegmentedControl!
    private var modeDescription: NSTextField!
    private var targetSettingButton: NSButton!
    private var targetSummaryLabel: NSTextField!

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusRightClickMonitor: Any?
    private var statusStartItem: NSMenuItem!
    private var statusStopItem: NSMenuItem!
    private var statusTargetItem: NSMenuItem!
    private var statusShowItem: NSMenuItem!

    private var saveFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop", isDirectory: true)
    private var initialModeRaw = CaptureMode.display.rawValue
    private var storedRegionRect: CGRect?

    private var selectedWindowID: CGWindowID?
    private var selectedWindowOwnerPID: pid_t?
    private var selectedWindowDescription: String?

    private var lastSavedURL: URL?
    private var isBusy = false
    private var lastExternalApplication: NSRunningApplication?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var pendingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastExternalApplication = front
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            self.lastExternalApplication = app
        }

        buildMainMenu()
        buildWindow()
        buildStatusItem()

        recorder.onUserStopped = { [weak self] result in
            self?.handleEngineStopped(result, unexpected: false)
        }

        recorder.onUnexpectedStop = { [weak self] result in
            self?.handleEngineStopped(result, unexpected: true)
        }

        updateFolderLabel()
        updateTargetPresentation()
        updateUIState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.isRecording {
            pendingTermination = true

            if recorder.isStopping {
                return .terminateLater
            }

            stopRecording()
            return .terminateLater
        }

        if isBusy {
            regionSelector.cancel()
            isBusy = false
        }

        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        if let statusRightClickMonitor {
            NSEvent.removeMonitor(statusRightClickMonitor)
        }
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard

        if let savedPath = defaults.string(forKey: DefaultsKey.saveFolder), !savedPath.isEmpty {
            saveFolder = URL(fileURLWithPath: savedPath, isDirectory: true)
        }

        if defaults.object(forKey: DefaultsKey.captureMode) != nil {
            let raw = defaults.integer(forKey: DefaultsKey.captureMode)
            if CaptureMode(rawValue: raw) != nil {
                initialModeRaw = raw
            }
        }

        let regionKeys = [
            DefaultsKey.regionX,
            DefaultsKey.regionY,
            DefaultsKey.regionWidth,
            DefaultsKey.regionHeight
        ]
        if regionKeys.allSatisfy({ defaults.object(forKey: $0) != nil }) {
            let rect = CGRect(
                x: defaults.double(forKey: DefaultsKey.regionX),
                y: defaults.double(forKey: DefaultsKey.regionY),
                width: defaults.double(forKey: DefaultsKey.regionWidth),
                height: defaults.double(forKey: DefaultsKey.regionHeight)
            ).standardized
            if rect.width >= 12, rect.height >= 12 {
                storedRegionRect = rect
            }
        }
    }

    private func saveStoredRegion(_ rect: CGRect) {
        storedRegionRect = rect.integral
        let defaults = UserDefaults.standard
        defaults.set(Double(rect.minX), forKey: DefaultsKey.regionX)
        defaults.set(Double(rect.minY), forKey: DefaultsKey.regionY)
        defaults.set(Double(rect.width), forKey: DefaultsKey.regionWidth)
        defaults.set(Double(rect.height), forKey: DefaultsKey.regionHeight)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "Mac Screen Audio Recorderについて",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Mac Screen Audio Recorderを終了",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 560, height: 475)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = appTitle
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let root = NSView(frame: contentRect)
        window.contentView = root

        let title = NSTextField(labelWithString: appTitle)
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(
            labelWithString: "画面と音を手軽にキャプチャーするアプリです。"
        )
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let modeLabel = NSTextField(labelWithString: "録画対象")
        modeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false

        modeControl = NSSegmentedControl(
            labels: ["全画面", "ウィンドウ", "範囲指定"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged)
        )
        modeControl.selectedSegment = initialModeRaw
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        modeDescription = NSTextField(labelWithString: "")
        modeDescription.font = NSFont.systemFont(ofSize: 11)
        modeDescription.textColor = .secondaryLabelColor
        modeDescription.alignment = .center
        modeDescription.translatesAutoresizingMaskIntoConstraints = false

        targetSettingButton = NSButton(title: "設定不要", target: self, action: #selector(configureTarget))
        targetSettingButton.bezelStyle = .rounded
        targetSettingButton.translatesAutoresizingMaskIntoConstraints = false

        targetSummaryLabel = NSTextField(labelWithString: "")
        targetSummaryLabel.font = NSFont.systemFont(ofSize: 11)
        targetSummaryLabel.textColor = .secondaryLabelColor
        targetSummaryLabel.alignment = .center
        targetSummaryLabel.lineBreakMode = .byTruncatingMiddle
        targetSummaryLabel.translatesAutoresizingMaskIntoConstraints = false

        recordButton = NSButton(title: "●  REC", target: self, action: #selector(toggleRecording))
        recordButton.bezelStyle = .rounded
        recordButton.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        recordButton.contentTintColor = .systemRed
        recordButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "待機中")
        statusLabel.alignment = .center
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        revealButton = NSButton(
            title: "最後の録画をFinderで表示",
            target: self,
            action: #selector(revealLastRecording)
        )
        revealButton.bezelStyle = .inline
        revealButton.isHidden = true
        revealButton.translatesAutoresizingMaskIntoConstraints = false

        folderLabel = NSTextField(labelWithString: "")
        folderLabel.font = NSFont.systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.translatesAutoresizingMaskIntoConstraints = false

        chooseFolderButton = NSButton(
            title: "保存先を変更…",
            target: self,
            action: #selector(chooseFolder)
        )
        chooseFolderButton.bezelStyle = .rounded
        chooseFolderButton.translatesAutoresizingMaskIntoConstraints = false

        let copyright = NSTextField(labelWithString: "© 2026 msk")
        copyright.font = NSFont.systemFont(ofSize: 10)
        copyright.textColor = .tertiaryLabelColor
        copyright.alignment = .center
        copyright.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(subtitle)
        root.addSubview(modeLabel)
        root.addSubview(modeControl)
        root.addSubview(modeDescription)
        root.addSubview(targetSettingButton)
        root.addSubview(targetSummaryLabel)
        root.addSubview(recordButton)
        root.addSubview(statusLabel)
        root.addSubview(revealButton)
        root.addSubview(folderLabel)
        root.addSubview(chooseFolderButton)
        root.addSubview(copyright)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            modeLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            modeLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            modeControl.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 7),
            modeControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 380),

            modeDescription.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            modeDescription.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            modeDescription.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            targetSettingButton.topAnchor.constraint(equalTo: modeDescription.bottomAnchor, constant: 10),
            targetSettingButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            targetSettingButton.widthAnchor.constraint(equalToConstant: 220),

            targetSummaryLabel.topAnchor.constraint(equalTo: targetSettingButton.bottomAnchor, constant: 5),
            targetSummaryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            targetSummaryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            recordButton.topAnchor.constraint(equalTo: targetSummaryLabel.bottomAnchor, constant: 16),
            recordButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 240),
            recordButton.heightAnchor.constraint(equalToConstant: 62),

            statusLabel.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 9),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            revealButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 5),
            revealButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            folderLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            folderLabel.bottomAnchor.constraint(equalTo: copyright.topAnchor, constant: -13),
            folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330),

            chooseFolderButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            chooseFolderButton.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),

            copyright.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            copyright.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            copyright.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])

        window.makeKeyAndOrderFront(nil)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "録画開始")
        statusItem.button?.toolTip = "クリックで録画開始／右クリックでメニュー"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked(_:))
        _ = statusItem.button?.sendAction(on: [.leftMouseUp])

        let menu = NSMenu()

        statusStartItem = NSMenuItem(title: "録画開始", action: #selector(startFromStatusMenu), keyEquivalent: "")
        statusStartItem.target = self
        menu.addItem(statusStartItem)

        statusStopItem = NSMenuItem(title: "録画終了", action: #selector(stopFromStatusMenu), keyEquivalent: "")
        statusStopItem.target = self
        menu.addItem(statusStopItem)

        statusTargetItem = NSMenuItem(title: "録画対象：全画面", action: nil, keyEquivalent: "")
        statusTargetItem.isEnabled = false
        menu.addItem(statusTargetItem)

        menu.addItem(.separator())

        statusShowItem = NSMenuItem(title: "アプリを開く", action: #selector(showMainWindow), keyEquivalent: "")
        statusShowItem.target = self
        menu.addItem(statusShowItem)

        let aboutItem = NSMenuItem(title: "このアプリについて", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "アプリを終了", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusMenu = menu

        statusRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem.button,
                  event.window === button.window else {
                return event
            }

            let point = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(point) else { return event }

            NSMenu.popUpContextMenu(self.statusMenu, with: event, for: button)
            return nil
        }
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard !isBusy else {
            NSSound.beep()
            return
        }

        if recorder.isRecording {
            stopRecording()
        } else {
            beginRecordingFlow()
        }
    }

    private var selectedMode: CaptureMode {
        CaptureMode(rawValue: modeControl?.selectedSegment ?? CaptureMode.display.rawValue) ?? .display
    }

    @objc private func modeChanged() {
        UserDefaults.standard.set(selectedMode.rawValue, forKey: DefaultsKey.captureMode)
        updateTargetPresentation()
        updateUIState()
    }

    private func updateTargetPresentation() {
        guard modeDescription != nil, targetSettingButton != nil, targetSummaryLabel != nil else { return }

        switch selectedMode {
        case .display:
            modeDescription.stringValue = "メインディスプレイ全体を録画します。"
            targetSettingButton.title = "設定不要"
            targetSettingButton.isEnabled = false
            targetSummaryLabel.stringValue = "メインディスプレイ全体"

        case .window:
            modeDescription.stringValue = "録画前に対象ウィンドウを選択しておきます。"
            targetSettingButton.title = "録画ウィンドウを選択…"
            targetSettingButton.isEnabled = !recorder.isRecording && !isBusy
            targetSummaryLabel.stringValue = selectedWindowDescription ?? "未設定 — 録画前にウィンドウを選択してください"

        case .region:
            modeDescription.stringValue = "録画前に範囲を設定します。保存した範囲は次回起動後も保持されます。"
            targetSettingButton.title = "録画範囲を設定…"
            targetSettingButton.isEnabled = !recorder.isRecording && !isBusy
            if let rect = validStoredRegionRect() {
                targetSummaryLabel.stringValue = "保存済み範囲：\(Int(rect.width)) × \(Int(rect.height))  (x:\(Int(rect.minX)), y:\(Int(rect.minY)))"
            } else {
                targetSummaryLabel.stringValue = "未設定 — 録画前に範囲を設定してください"
            }
        }

        statusTargetItem?.title = "録画対象：\(selectedMode.label)"
    }

    @objc private func configureTarget() {
        guard !recorder.isRecording, !isBusy else { return }

        switch selectedMode {
        case .display:
            return
        case .window:
            configureWindowTarget()
        case .region:
            configureRegionTarget()
        }
    }

    private func configureWindowTarget() {
        guard ensureCapturePermission() else { return }

        isBusy = true
        statusLabel.stringValue = "録画できるウィンドウを取得しています…"
        updateUIState()
        window.orderOut(nil)

        activateLastExternalApplication { [weak self] in
            guard let self else { return }
            self.recorder.getShareableContent(onScreenWindowsOnly: false) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let content):
                    self.presentWindowPickerForConfiguration(content: content)
                case .failure:
                    self.recorder.getShareableContent(onScreenWindowsOnly: true) { [weak self] fallback in
                        guard let self else { return }
                        switch fallback {
                        case .success(let content):
                            self.presentWindowPickerForConfiguration(content: content)
                        case .failure(let error):
                            self.isBusy = false
                            self.statusLabel.stringValue = "ウィンドウ一覧を取得できませんでした"
                            self.updateUIState()
                            self.showError(error)
                        }
                    }
                }
            }
        }
    }

    private func presentWindowPickerForConfiguration(content: SCShareableContent) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { item in
            guard item.frame.width >= 80, item.frame.height >= 60 else { return false }
            if item.owningApplication?.processID == ownPID { return false }
            let appName = item.owningApplication?.applicationName ?? ""
            let title = item.title ?? ""
            return !appName.isEmpty || !title.isEmpty
        }.sorted {
            let left = ($0.owningApplication?.applicationName ?? "") + ($0.title ?? "")
            let right = ($1.owningApplication?.applicationName ?? "") + ($1.title ?? "")
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }

        guard !windows.isEmpty else {
            isBusy = false
            statusLabel.stringValue = "録画できるウィンドウが見つかりませんでした"
            updateUIState()
            showMainWindow()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 28), pullsDown: false)
        for item in windows {
            let app = item.owningApplication?.applicationName ?? "アプリ"
            let title = (item.title?.isEmpty == false) ? item.title! : "名称なし"
            let size = "\(Int(item.frame.width))×\(Int(item.frame.height))"
            popup.addItem(withTitle: "\(app) — \(title)  [\(size) / #\(item.windowID)]")
        }

        if let selectedWindowID,
           let selectedIndex = windows.firstIndex(where: { $0.windowID == selectedWindowID }) {
            popup.selectItem(at: selectedIndex)
        }

        let alert = NSAlert()
        alert.messageText = "録画ウィンドウを設定"
        alert.informativeText = "ここで選択したウィンドウは、RECを押した時に録画されます。録画開始前なら何度でも選び直せます。"
        alert.accessoryView = popup
        alert.addButton(withTitle: "決定")
        alert.addButton(withTitle: "キャンセル")

        let response = alert.runModal()
        defer {
            isBusy = false
            updateTargetPresentation()
            updateUIState()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        guard response == .alertFirstButtonReturn else {
            statusLabel.stringValue = "ウィンドウ設定を変更しませんでした"
            return
        }

        let index = popup.indexOfSelectedItem
        guard windows.indices.contains(index) else {
            statusLabel.stringValue = "ウィンドウを設定できませんでした"
            return
        }

        let selected = windows[index]
        let appName = selected.owningApplication?.applicationName ?? "アプリ"
        let title = (selected.title?.isEmpty == false) ? selected.title! : "名称なし"

        selectedWindowID = selected.windowID
        selectedWindowOwnerPID = selected.owningApplication?.processID
        selectedWindowDescription = "\(appName) — \(title)"
        statusLabel.stringValue = "録画ウィンドウを設定しました"
    }

    private func configureRegionTarget() {
        guard let screen = NSScreen.main else {
            showError(RecorderError.noDisplay)
            return
        }

        isBusy = true
        statusLabel.stringValue = "録画範囲を設定してください"
        updateUIState()
        window.orderOut(nil)

        activateLastExternalApplication { [weak self] in
            guard let self else { return }
            let initialRect = self.validStoredRegionRect(on: screen)
            self.regionSelector.select(on: screen, initialRect: initialRect) { [weak self] localRect in
                guard let self else { return }
                self.isBusy = false

                if let localRect {
                    self.saveStoredRegion(localRect)
                    self.statusLabel.stringValue = "録画範囲を保存しました"
                } else {
                    self.statusLabel.stringValue = "範囲設定を変更しませんでした"
                }

                self.updateTargetPresentation()
                self.updateUIState()
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func validStoredRegionRect(on screen: NSScreen? = NSScreen.main) -> CGRect? {
        guard let rect = storedRegionRect?.standardized, let screen else { return nil }
        let localBounds = CGRect(origin: .zero, size: screen.frame.size)
        let clamped = rect.intersection(localBounds).integral
        guard clamped.width >= 12, clamped.height >= 12 else { return nil }

        if clamped != rect.integral {
            saveStoredRegion(clamped)
        }
        return clamped
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            beginRecordingFlow()
        }
    }

    @objc private func startFromStatusMenu() {
        guard !recorder.isRecording, !isBusy else { return }
        beginRecordingFlow()
    }

    @objc private func stopFromStatusMenu() {
        guard recorder.isRecording else { return }
        stopRecording()
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = appTitle
        alert.informativeText = "画面と音を手軽にキャプチャーするアプリです。\n\nmacOS 14.2以降 / Universal 2"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func ensureCapturePermission() -> Bool {
        if recorder.hasScreenCapturePermission() {
            statusLabel.toolTip = nil
            return true
        }

        // macOS のシステム許可ダイアログを優先する。
        // CGRequestScreenCaptureAccess の直後に NSAlert.runModal() を呼ぶと
        // 2つのダイアログが重なり、許可ボタンが隠れてしまう。
        let granted = recorder.requestScreenCapturePermission()
        if !granted {
            statusLabel.stringValue = "画面収録を許可後、アプリを再起動してください"
            statusLabel.toolTip = "システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオ録音で許可してください。"
            updateUIState()
            return false
        }
        statusLabel.toolTip = nil
        return true
    }

    private func beginRecordingFlow() {
        guard !isBusy, !recorder.isRecording else { return }
        guard ensureCapturePermission() else { return }

        switch selectedMode {
        case .display:
            beginDisplayRecording()
        case .window:
            beginWindowRecording()
        case .region:
            beginRegionRecording()
        }
    }

    private func beginDisplayRecording() {
        prepareForRecordingStart()
        recorder.getShareableContent(onScreenWindowsOnly: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.failPreparation(error)
            case .success(let content):
                guard let display = self.recorder.mainDisplay(from: content) else {
                    self.failPreparation(RecorderError.noDisplay)
                    return
                }
                self.startRecording(target: .display(display))
            }
        }
    }

    private func beginWindowRecording() {
        guard let selectedWindowID else {
            statusLabel.stringValue = "録画ウィンドウを先に設定してください"
            updateTargetPresentation()
            showMainWindow()
            return
        }

        prepareForRecordingStart()
        window.orderOut(nil)

        activateSelectedWindowApplication { [weak self] in
            guard let self else { return }
            self.recorder.getShareableContent(onScreenWindowsOnly: false) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.failPreparation(error)
                case .success(let content):
                    guard let selectedWindow = content.windows.first(where: { $0.windowID == selectedWindowID }) else {
                        self.selectedWindowID = nil
                        self.selectedWindowOwnerPID = nil
                        self.selectedWindowDescription = nil
                        self.isBusy = false
                        self.statusLabel.stringValue = "設定したウィンドウが見つかりません。もう一度選択してください"
                        self.updateTargetPresentation()
                        self.updateUIState()
                        self.showMainWindow()
                        return
                    }
                    // 単一SCWindowではプルダウン／ポップアップが別Windowとして
                    // 取りこぼされるため、対象ウィンドウが存在するディスプレイを
                    // 実画面としてキャプチャし、そのウィンドウ矩形を切り出す。
                    // Mac Screen Audio Recorder自身だけは映り込まないよう除外する。
                    let windowFrame = selectedWindow.frame.standardized
                    let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
                    let display = content.displays.first(where: { $0.frame.contains(center) })
                        ?? content.displays
                            .filter { $0.frame.intersects(windowFrame) }
                            .max(by: { lhs, rhs in
                                let la = lhs.frame.intersection(windowFrame)
                                let ra = rhs.frame.intersection(windowFrame)
                                return la.width * la.height < ra.width * ra.height
                            })

                    guard let display else {
                        self.failPreparation(RecorderError.noDisplay)
                        return
                    }

                    let clippedFrame = windowFrame.intersection(display.frame).integral
                    guard clippedFrame.width >= 2, clippedFrame.height >= 2 else {
                        self.failPreparation(RecorderError.noWindow)
                        return
                    }

                    let sourceRect = CGRect(
                        x: clippedFrame.minX - display.frame.minX,
                        y: clippedFrame.minY - display.frame.minY,
                        width: clippedFrame.width,
                        height: clippedFrame.height
                    ).integral

                    let ownPID = ProcessInfo.processInfo.processIdentifier
                    let excludedApplications = content.applications.filter {
                        $0.processID == ownPID
                    }

                    self.startRecording(
                        target: .window(
                            display: display,
                            sourceRect: sourceRect,
                            excludingApplications: excludedApplications
                        )
                    )
                }
            }
        }
    }

    private func beginRegionRecording() {
        guard let screen = NSScreen.main,
              let localRect = validStoredRegionRect(on: screen) else {
            statusLabel.stringValue = "録画範囲を先に設定してください"
            updateTargetPresentation()
            showMainWindow()
            return
        }

        prepareForRecordingStart()
        window.orderOut(nil)

        activateLastExternalApplication { [weak self] in
            guard let self else { return }
            self.recorder.getShareableContent(onScreenWindowsOnly: true) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.failPreparation(error)
                case .success(let content):
                    guard let display = self.recorder.mainDisplay(from: content) else {
                        self.failPreparation(RecorderError.noDisplay)
                        return
                    }

                    let sourceRect = CGRect(
                        x: localRect.minX,
                        y: screen.frame.height - localRect.maxY,
                        width: localRect.width,
                        height: localRect.height
                    ).integral

                    self.startRecording(target: .region(display: display, sourceRect: sourceRect))
                }
            }
        }
    }

    private func prepareForRecordingStart() {
        isBusy = true
        revealButton.isHidden = true
        statusLabel.stringValue = "録画を開始しています…"
        updateUIState()
    }

    private func activateLastExternalApplication(completion: @escaping () -> Void) {
        guard let app = lastExternalApplication, !app.isTerminated else {
            DispatchQueue.main.async(execute: completion)
            return
        }

        _ = app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: completion)
    }

    private func activateSelectedWindowApplication(completion: @escaping () -> Void) {
        if let pid = selectedWindowOwnerPID,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated {
            _ = app.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: completion)
            return
        }
        activateLastExternalApplication(completion: completion)
    }

    private func startRecording(target: CaptureTarget) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let filename = "画面収録 \(formatter.string(from: Date())).mov"
        let outputURL = saveFolder.appendingPathComponent(filename)

        recorder.startRecording(to: outputURL, target: target) { [weak self] result in
            guard let self else { return }
            self.isBusy = false

            switch result {
            case .success:
                self.statusLabel.stringValue = "録画中 — 本体の「録画終了」またはメニューバーの赤いSTOPから終了できます"
                self.window.orderOut(nil)
            case .failure(let error):
                self.statusLabel.stringValue = "録画を開始できませんでした"
                self.showError(error)
            }
            self.updateUIState()
        }
    }

    private func failPreparation(_ error: Error) {
        isBusy = false
        statusLabel.stringValue = "録画を開始できませんでした"
        updateUIState()
        showError(error)
    }

    private func handleEngineStopped(_ result: Result<URL, Error>, unexpected: Bool) {
        isBusy = false

        switch result {
        case .success(let url):
            lastSavedURL = url
            revealButton.isHidden = false
            if unexpected {
                statusLabel.stringValue = "録画が予期せず終了しましたが、動画は保存しました：\(url.lastPathComponent)"
            } else {
                statusLabel.stringValue = "保存しました：\(url.lastPathComponent)"
            }
        case .failure(let error):
            statusLabel.stringValue = unexpected ? "録画が予期せず終了しました" : "保存に失敗しました"
            showError(error)
        }

        updateUIState()

        if pendingTermination {
            pendingTermination = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func stopRecording() {
        guard recorder.isRecording, !isBusy else { return }
        isBusy = true
        statusLabel.stringValue = "録画を終了し、動画ファイルを確定しています…"
        updateUIState()

        recorder.stopRecording { [weak self] result in
            guard let self else { return }
            self.isBusy = false

            switch result {
            case .success(let url):
                self.lastSavedURL = url
                self.statusLabel.stringValue = "保存しました：\(url.lastPathComponent)"
                self.revealButton.isHidden = false
            case .failure(let error):
                self.statusLabel.stringValue = "保存に失敗しました"
                self.showError(error)
            }
            self.updateUIState()

            if self.pendingTermination {
                self.pendingTermination = false
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }

            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    private func updateUIState() {
        let recording = recorder.isRecording
        recordButton?.isEnabled = !isBusy
        modeControl?.isEnabled = !recording && !isBusy
        chooseFolderButton?.isEnabled = !recording && !isBusy

        if recording {
            recordButton?.title = "■  録画終了"
            statusItem?.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "録画中・クリックで停止")
            statusItem?.button?.title = " STOP"
            statusItem?.button?.contentTintColor = .systemRed
            statusItem?.button?.toolTip = isBusy
                ? "録画終了処理中…／右クリックでメニュー"
                : "クリックで録画終了／右クリックでメニュー"
        } else {
            recordButton?.title = "●  REC"
            statusItem?.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "録画開始")
            statusItem?.button?.title = " REC"
            statusItem?.button?.contentTintColor = nil
            statusItem?.button?.toolTip = isBusy
                ? "録画開始準備中…／右クリックでメニュー"
                : "クリックで録画開始／右クリックでメニュー"
        }

        statusStartItem?.isEnabled = !recording && !isBusy
        statusStopItem?.isEnabled = recording && !isBusy
        statusTargetItem?.title = "録画対象：\(selectedMode.label)"

        updateTargetPresentation()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "録画の保存先を選択"
        panel.prompt = "このフォルダを使用"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveFolder

        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url
            UserDefaults.standard.set(url.path, forKey: DefaultsKey.saveFolder)
            updateFolderLabel()
        }
    }

    @objc private func revealLastRecording() {
        guard let lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastSavedURL])
    }

    private func updateFolderLabel() {
        folderLabel.stringValue = "保存先：\(saveFolder.path)"
        folderLabel.toolTip = saveFolder.path
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = appTitle
        let nsError = error as NSError
        alert.informativeText = error.localizedDescription
            + "\n\n詳細: \(nsError.domain) / \(nsError.code)"
            + "\n\n『システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオ録音』で、このアプリが許可されていることを確認してください。"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
