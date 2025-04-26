import Defaults
import SwiftUI

// An NSPanel subclass that implements floating panel traits.
// https://stackoverflow.com/questions/46023769/how-to-show-a-window-without-stealing-focus-on-macos
class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
  var isPresented: Bool = false
  var statusBarButton: NSStatusBarButton?
  private var eventMonitor: Any?
  
  // 用于重置文本输入上下文的辅助类
  private class DummyTextView: NSTextView {}

  override var isMovable: Bool {
    get { Defaults[.popupPosition] != .statusItem }
    set {}
  }

  init(
    contentRect: NSRect,
    identifier: String = "",
    statusBarButton: NSStatusBarButton? = nil,
    view: () -> Content
  ) {
    super.init(
        contentRect: contentRect,
        styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )

    self.statusBarButton = statusBarButton
    self.identifier = NSUserInterfaceItemIdentifier(identifier)

    Defaults[.windowSize] = contentRect.size
    delegate = self

    animationBehavior = .none
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    hidesOnDeactivate = false

    // 拦截所有键盘事件
    setupEventMonitor()

    // Hide all traffic light buttons
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    contentView = NSHostingView(
      rootView: view()
        // The safe area is ignored because the title bar still interferes with the geometry
        .ignoresSafeArea()
        .gesture(DragGesture()
          .onEnded { _ in
            self.saveWindowFrame(frame: self.frame)
        })
    )
  }
  
  deinit {
    if let eventMonitor = eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
  }
  
  private func setupEventMonitor() {
    // 创建事件监视器，确保键盘事件正确分发
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard let self = self, self.isKeyWindow else {
        return event
      }
      
      // 确保事件会被分发给当前第一响应者
      if let firstResponder = self.firstResponder, 
         !(firstResponder is NSWindow),
         firstResponder.responds(to: #selector(NSResponder.keyDown(with:))) || 
         firstResponder.responds(to: #selector(NSResponder.keyUp(with:))) {
        
        let eventType = event.type
        switch eventType {
        case .keyDown:
          firstResponder.keyDown(with: event)
          return nil // 阻止事件进一步传递
        case .keyUp:
          firstResponder.keyUp(with: event)
          return nil // 阻止事件进一步传递
        default:
          break
        }
      }
      
      return event
    }
  }

  func toggle(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    if isPresented {
      close()
    } else {
      open(height: height, at: popupPosition)
    }
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    // 先重新配置窗口尺寸和位置
    setContentSize(NSSize(width: frame.width, height: min(height, Defaults[.windowSize].height)))
    setFrameOrigin(popupPosition.origin(size: frame.size, statusBarButton: statusBarButton))
    
    // 处理输入系统状态重置
    if let hostingView = contentView as? NSHostingView<Content> {
      // 发送reloadData消息，强制SwiftUI更新输入视图状态
      let selector = NSSelectorFromString("reloadData")
      if hostingView.responds(to: selector) {
          hostingView.perform(selector)
      }
      
      // 重置任何可能被持有的第一响应者
      if firstResponder != nil && firstResponder != self {
        makeFirstResponder(nil)
      }
      
      // 强制重置文本输入上下文
      if let currentInputContext = NSTextInputContext.current {
        // 尝试使用运行时方法强制重置输入上下文
        let resetSelector = NSSelectorFromString("deactivate")
        if currentInputContext.responds(to: resetSelector) {
          currentInputContext.perform(resetSelector)
        }
      }
      
      // 强制创建一个新的输入上下文
      let dummyTextView = DummyTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
      // 激活输入上下文然后立即释放
      dummyTextView.becomeFirstResponder()
      dummyTextView.resignFirstResponder()
    }
    
    // 确保窗口被显示并成为key window
    orderFrontRegardless()
    makeKey()
    isPresented = true
    
    // 最后确保窗口激活和获得输入焦点
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      // 先激活应用
      NSApp.activate(ignoringOtherApps: true)
      
      // 确保窗口是key window
      self.makeKeyAndOrderFront(nil)
      
      // 向window发送didBecomeKey通知，强制更新焦点状态
      NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: self)
    }

    if popupPosition == .statusItem {
      DispatchQueue.main.async {
        self.statusBarButton?.isHighlighted = true
      }
    }
  }
  
  // 重载sendEvent方法，确保键盘事件被正确处理
  override func sendEvent(_ event: NSEvent) {
    super.sendEvent(event)
    
    // 对于键盘事件，如果已经处理了但仍然有问题，尝试手动分发
    if (event.type == .keyDown || event.type == .keyUp) && isKeyWindow {
      if let firstResponder = firstResponder, 
         !(firstResponder is NSWindow),
         firstResponder.responds(to: #selector(NSResponder.interpretKeyEvents(_:))) {
        firstResponder.interpretKeyEvents([event])
      }
    }
  }

  func verticallyResize(to newHeight: CGFloat) {
    var newSize = Defaults[.windowSize]
    newSize.height = min(newHeight, newSize.height)

    var newOrigin = frame.origin
    newOrigin.y += (frame.height - newSize.height)

    NSAnimationContext.runAnimationGroup { (context) in
      context.duration = 0.2
      animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }
  }

  func saveWindowFrame(frame: NSRect) {
    Defaults[.windowSize] = frame.size

    if let screenFrame = screen?.visibleFrame {
      let anchorX = frame.minX + frame.width / 2 - screenFrame.minX
      let anchorY = frame.maxY - screenFrame.minY
      Defaults[.windowPosition] = NSPoint(x: anchorX / screenFrame.width, y: anchorY / screenFrame.height)
    }
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    saveWindowFrame(frame: NSRect(origin: frame.origin, size: frameSize))

    return frameSize
  }

  // Close automatically when out of focus, e.g. outside click.
  override func resignKey() {
    super.resignKey()
    // Don't hide if confirmation is shown.
    if NSApp.alertWindow == nil {
      close()
    }
  }

  override func close() {
    super.close()
    isPresented = false
    statusBarButton?.isHighlighted = false
  }

  // Allow text inputs inside the panel can receive focus
  override var canBecomeKey: Bool {
    return true
  }
}
