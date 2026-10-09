import AppKit

final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class RegionSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    private enum ResizeHandle: CaseIterable, Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum DragMode {
        case none
        case create(anchor: CGPoint)
        case move(start: CGPoint, original: CGRect)
        case resize(handle: ResizeHandle, start: CGPoint, original: CGRect)
    }

    private var currentRect: CGRect
    private var dragMode: DragMode = .none
    private var finished = false
    private let safeVisibleRect: CGRect

    private let minimumSelectionSize: CGFloat = 12
    private let handleVisualSize: CGFloat = 10
    private let handleHitSize: CGFloat = 22

    private var controlBarRect: CGRect {
        let preferredWidth: CGFloat = 370
        let availableWidth = max(240, safeVisibleRect.width - 24)
        let width = min(preferredWidth, availableWidth)
        let x = min(
            max(safeVisibleRect.minX + 12, safeVisibleRect.midX - width / 2),
            max(safeVisibleRect.minX + 12, safeVisibleRect.maxX - width - 12)
        )
        // メニューバーやノッチを避けるため、操作バーはvisibleFrame内の下側へ置く。
        let y = safeVisibleRect.minY + 16
        return CGRect(x: x, y: y, width: width, height: 50)
    }

    private var confirmRect: CGRect {
        let bar = controlBarRect
        return CGRect(x: bar.minX + 12, y: bar.minY + 10, width: 100, height: 30)
    }

    private var resetRect: CGRect {
        let bar = controlBarRect
        return CGRect(x: bar.midX - 50, y: bar.minY + 10, width: 100, height: 30)
    }

    private var cancelRect: CGRect {
        let bar = controlBarRect
        return CGRect(x: bar.maxX - 112, y: bar.minY + 10, width: 100, height: 30)
    }

    init(frame frameRect: NSRect, safeVisibleRect: CGRect, initialRect: CGRect?) {
        self.safeVisibleRect = safeVisibleRect.intersection(CGRect(origin: .zero, size: frameRect.size))
        if let initialRect {
            self.currentRect = initialRect.standardized.intersection(CGRect(origin: .zero, size: frameRect.size))
        } else {
            self.currentRect = .zero
        }
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        self.currentRect = .zero
        self.safeVisibleRect = .zero
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let shadePath = NSBezierPath(rect: bounds)
        if hasValidSelection {
            shadePath.append(NSBezierPath(rect: currentRect))
            shadePath.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.30).setFill()
        shadePath.fill()

        if hasValidSelection {
            drawSelection()
        }

        drawControls()
    }

    private var hasValidSelection: Bool {
        currentRect.width >= minimumSelectionSize && currentRect.height >= minimumSelectionSize
    }

    private func drawSelection() {
        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath(rect: currentRect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 2
        outline.stroke()

        for handle in ResizeHandle.allCases {
            let center = handlePoint(handle, in: currentRect)
            let handleRect = CGRect(
                x: center.x - handleVisualSize / 2,
                y: center.y - handleVisualSize / 2,
                width: handleVisualSize,
                height: handleVisualSize
            )
            let path = NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        let text = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72)
        ]
        let size = text.size(withAttributes: attrs)
        let x = min(currentRect.minX + 6, max(6, bounds.width - size.width - 14))
        let yCandidate = currentRect.minY - size.height - 10
        let y = yCandidate >= 6 ? yCandidate : min(bounds.height - size.height - 6, currentRect.maxY + 6)
        text.draw(at: CGPoint(x: x + 4, y: y + 2), withAttributes: attrs)
    }

    private func drawControls() {
        let bar = NSBezierPath(roundedRect: controlBarRect, xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        bar.fill()

        drawButton(rect: confirmRect, title: "決定", enabled: hasValidSelection, emphasized: true)
        drawButton(rect: resetRect, title: "やり直す", enabled: hasValidSelection, emphasized: false)
        drawButton(rect: cancelRect, title: "キャンセル", enabled: true, emphasized: false)

        let instruction = hasValidSelection
            ? "枠内＝移動／辺・角＝サイズ変更／枠外＝新規指定"
            : "録画する範囲をドラッグしてください。"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.62)
        ]
        let size = instruction.size(withAttributes: attrs)
        let x = min(
            max(safeVisibleRect.minX + 8, safeVisibleRect.midX - size.width / 2),
            max(safeVisibleRect.minX + 8, safeVisibleRect.maxX - size.width - 8)
        )
        let y = min(safeVisibleRect.maxY - size.height - 8, controlBarRect.maxY + 8)
        instruction.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    private func drawButton(rect: CGRect, title: String, enabled: Bool, emphasized: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if !enabled {
            NSColor.controlColor.withAlphaComponent(0.55).setFill()
        } else if emphasized {
            NSColor.controlAccentColor.setFill()
        } else {
            NSColor.controlColor.setFill()
        }
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: enabled && emphasized ? NSColor.white : NSColor.labelColor.withAlphaComponent(enabled ? 1.0 : 0.45)
        ]
        let size = title.size(withAttributes: attrs)
        title.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard !finished else { return }
        let point = clampPoint(convert(event.locationInWindow, from: nil))

        if confirmRect.contains(point) {
            guard hasValidSelection else {
                NSSound.beep()
                return
            }
            finished = true
            onFinish?(currentRect.integral)
            return
        }

        if resetRect.contains(point) {
            currentRect = .zero
            dragMode = .none
            needsDisplay = true
            return
        }

        if cancelRect.contains(point) {
            cancel()
            return
        }

        if hasValidSelection, let handle = hitTestHandle(at: point) {
            dragMode = .resize(handle: handle, start: point, original: currentRect)
            return
        }

        if hasValidSelection && currentRect.contains(point) {
            dragMode = .move(start: point, original: currentRect)
            return
        }

        currentRect = .zero
        dragMode = .create(anchor: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !finished else { return }
        let point = clampPoint(convert(event.locationInWindow, from: nil))

        switch dragMode {
        case .none:
            return

        case .create(let anchor):
            currentRect = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            ).intersection(bounds)

        case .move(let start, let original):
            let dx = point.x - start.x
            let dy = point.y - start.y
            var moved = original.offsetBy(dx: dx, dy: dy)

            if moved.minX < bounds.minX { moved.origin.x += bounds.minX - moved.minX }
            if moved.maxX > bounds.maxX { moved.origin.x -= moved.maxX - bounds.maxX }
            if moved.minY < bounds.minY { moved.origin.y += bounds.minY - moved.minY }
            if moved.maxY > bounds.maxY { moved.origin.y -= moved.maxY - bounds.maxY }
            currentRect = moved

        case .resize(let handle, _, let original):
            currentRect = resizedRect(original: original, handle: handle, point: point)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !finished else { return }

        if case .create = dragMode, !hasValidSelection {
            currentRect = .zero
            NSSound.beep()
        }

        dragMode = .none
        needsDisplay = true
    }

    private func resizedRect(original: CGRect, handle: ResizeHandle, point: CGPoint) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        switch handle {
        case .topLeft:
            minX = point.x
            maxY = point.y
        case .top:
            maxY = point.y
        case .topRight:
            maxX = point.x
            maxY = point.y
        case .right:
            maxX = point.x
        case .bottomRight:
            maxX = point.x
            minY = point.y
        case .bottom:
            minY = point.y
        case .bottomLeft:
            minX = point.x
            minY = point.y
        case .left:
            minX = point.x
        }

        if handle == .topLeft || handle == .bottomLeft || handle == .left {
            minX = min(minX, maxX - minimumSelectionSize)
        }
        if handle == .topRight || handle == .bottomRight || handle == .right {
            maxX = max(maxX, minX + minimumSelectionSize)
        }
        if handle == .topLeft || handle == .top || handle == .topRight {
            maxY = max(maxY, minY + minimumSelectionSize)
        }
        if handle == .bottomLeft || handle == .bottom || handle == .bottomRight {
            minY = min(minY, maxY - minimumSelectionSize)
        }

        minX = max(bounds.minX, minX)
        maxX = min(bounds.maxX, maxX)
        minY = max(bounds.minY, minY)
        maxY = min(bounds.maxY, maxY)

        if maxX - minX < minimumSelectionSize {
            if handle == .left || handle == .topLeft || handle == .bottomLeft {
                minX = max(bounds.minX, maxX - minimumSelectionSize)
            } else {
                maxX = min(bounds.maxX, minX + minimumSelectionSize)
            }
        }
        if maxY - minY < minimumSelectionSize {
            if handle == .bottom || handle == .bottomLeft || handle == .bottomRight {
                minY = max(bounds.minY, maxY - minimumSelectionSize)
            } else {
                maxY = min(bounds.maxY, minY + minimumSelectionSize)
            }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func hitTestHandle(at point: CGPoint) -> ResizeHandle? {
        for handle in ResizeHandle.allCases {
            let center = handlePoint(handle, in: currentRect)
            let hitRect = CGRect(
                x: center.x - handleHitSize / 2,
                y: center.y - handleHitSize / 2,
                width: handleHitSize,
                height: handleHitSize
            )
            if hitRect.contains(point) {
                return handle
            }
        }
        return nil
    }

    private func handlePoint(_ handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func clampPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish?(nil)
    }
}

final class RegionSelector {
    private var panel: RegionSelectionPanel?
    private var completion: ((CGRect?) -> Void)?
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var finishing = false

    func select(on screen: NSScreen, initialRect: CGRect?, completion: @escaping (CGRect?) -> Void) {
        teardownPanel()
        finishing = false
        self.completion = completion

        let overlay = RegionSelectionPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.level = .screenSaver
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.hasShadow = false
        overlay.hidesOnDeactivate = false
        overlay.ignoresMouseEvents = false
        overlay.isFloatingPanel = false

        let visible = screen.visibleFrame.intersection(screen.frame)
        let localSafeRect = CGRect(
            x: visible.minX - screen.frame.minX,
            y: visible.minY - screen.frame.minY,
            width: visible.width,
            height: visible.height
        )

        let view = RegionSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            safeVisibleRect: localSafeRect,
            initialRect: initialRect
        )
        view.onFinish = { [weak self] rect in
            self?.finish(rect)
        }
        overlay.contentView = view

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            if event.keyCode == 53 {
                view?.cancel()
                return nil
            }
            return event
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak view] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    view?.cancel()
                }
            }
        }

        panel = overlay
        overlay.orderFrontRegardless()
    }

    func cancel() {
        if let view = panel?.contentView as? RegionSelectionView {
            view.cancel()
        } else {
            completion = nil
            teardownPanel()
        }
    }

    private func finish(_ rect: CGRect?) {
        guard !finishing else { return }
        finishing = true

        let callback = completion
        completion = nil
        teardownPanel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            callback?(rect)
        }
    }

    private func teardownPanel() {
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
