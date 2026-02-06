import AppKit

struct ShiftState {
    let label: String
    let icon: String
}

let states: [ShiftState] = [
    ShiftState(label: "Stand", icon: "🧍"),
    ShiftState(label: "Sit", icon: "💺"),
    ShiftState(label: "Perch", icon: "🐦"),
    ShiftState(label: "Stool", icon: "🪑"),
]

final class ShiftyApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let currentItem = NSMenuItem(title: "Current: --", action: nil, keyEquivalent: "")
    private let nextChangeItem = NSMenuItem(title: "Next change: --", action: nil, keyEquivalent: "")
    private var currentLabel: String?
    private var nextChange = Date()
    private var queue: [ShiftState] = []
    private var baseTitle = ""
    private var tickTimer: Timer?
    private var flashTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.addItem(currentItem)
        menu.addItem(nextChangeItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        setRandomState(initial: true)
        tickTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    private func refillQueue() {
        var items = states.shuffled()
        if let currentLabel, items.first?.label == currentLabel, items.count > 1 {
            items.swapAt(0, 1)
        }
        queue = items
    }

    private func setRandomState(initial: Bool) {
        if queue.isEmpty {
            refillQueue()
        }

        let state = queue.removeFirst()
        currentLabel = state.label
        baseTitle = "\(state.icon) \(state.label.uppercased())"
        statusItem.button?.title = baseTitle
        currentItem.title = "Current: \(state.label.uppercased())"

        nextChange = Date().addingTimeInterval(Double(Int.random(in: 50...70) * 60))
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        nextChangeItem.title = "Next change: \(formatter.string(from: nextChange))"

        if !initial {
            sendNotification(body: baseTitle)
            flashTitle()
        }
    }

    private func sendNotification(body: String) {
        let script = "display notification \"\(body.replacingOccurrences(of: "\"", with: "\\\""))\" with title \"Shifty\" subtitle \"Time to shift\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func flashTitle() {
        guard let currentLabel else { return }
        statusItem.button?.title = "⏰ \(currentLabel.uppercased())"
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.statusItem.button?.title = self?.baseTitle ?? ""
        }
    }

    @objc private func tick() {
        if Date() >= nextChange {
            setRandomState(initial: false)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = ShiftyApp()
app.delegate = delegate
app.run()
