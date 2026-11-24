import AppKit
import CoreAudio

enum ProtectionMode: String {
    case allApplications = "all"
    case chosenApplications = "chosen"
    case off
}

final class ProtectionManager {
    private let protectedApplicationsKey = "protectedApplications"
    private let modeKey = "mode"
    private let sessionQueue = DispatchQueue(label: "noducking.sessions")
    private let generationLock = NSLock()
    private var latestGeneration = 0
    private var sessions: [String: ProtectionSession] = [:]
    private var leftAloneTimer: Timer?
    private var testProcessIdentifiers: [pid_t] = []
    private(set) var mode: ProtectionMode
    private(set) var protectedApplicationNames: [String: String]
    private(set) var activeSessionCount = 0
    private(set) var lastFailureText: String?
    var onChange: (() -> Void)?

    init() {
        protectedApplicationNames = UserDefaults.standard.dictionary(forKey: protectedApplicationsKey) as? [String: String] ?? [:]
        mode = ProtectionMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .chosenApplications
        observe(kAudioHardwarePropertyProcessObjectList)
        observe(kAudioHardwarePropertyDefaultOutputDevice)
    }

    func isProtected(_ identifier: String) -> Bool {
        protectedApplicationNames[identifier] != nil
    }

    func setProtected(_ isProtected: Bool, identifier: String, name: String) {
        protectedApplicationNames[identifier] = isProtected ? name : nil
        UserDefaults.standard.set(protectedApplicationNames, forKey: protectedApplicationsKey)
        refresh()
    }

    func setMode(_ newMode: ProtectionMode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: modeKey)
        refresh()
    }

    func protectProcessForTesting(_ processIdentifier: pid_t) {
        testProcessIdentifiers.append(processIdentifier)
        refresh()
    }

    func stopAll() {
        let finished = DispatchSemaphore(value: 0)
        sessionQueue.async { [self] in
            for session in sessions.values {
                session.stop()
            }
            sessions.removeAll()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 1)
    }

    func refresh() {
        guard isDuckRequestAvailable else {
            onChange?()
            return
        }
        let outputDeviceID = defaultOutputDeviceID()
        var wanted: [String: (name: String, target: ProtectionTarget)] = [:]
        switch mode {
        case .allApplications:
            if let leftAlone = processObjectIDsToLeaveAlone() {
                wanted["all"] = ("all apps", .everythingExcept(leftAlone))
            }
        case .chosenApplications:
            let applications = audioApplications()
            for (identifier, name) in protectedApplicationNames {
                if let application = applications[identifier], !application.processObjectIDs.isEmpty {
                    wanted[identifier] = (name, .processes(Set(application.processObjectIDs)))
                }
            }
        case .off:
            break
        }
        for processIdentifier in testProcessIdentifiers {
            if let objectID = audioObjectID(forProcessIdentifier: processIdentifier) {
                wanted["process:\(processIdentifier)"] = ("process \(processIdentifier)", .processes([objectID]))
            }
        }

        generationLock.lock()
        latestGeneration += 1
        let generation = latestGeneration
        generationLock.unlock()
        sessionQueue.async { [weak self] in
            self?.reconcile(wanted: wanted, outputDeviceID: outputDeviceID, generation: generation)
        }

        if mode == .allApplications, leftAloneTimer == nil {
            leftAloneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        } else if mode != .allApplications {
            leftAloneTimer?.invalidate()
            leftAloneTimer = nil
        }
    }

    private func reconcile(wanted: [String: (name: String, target: ProtectionTarget)], outputDeviceID: AudioDeviceID, generation: Int) {
        generationLock.lock()
        let isLatest = generation == latestGeneration
        generationLock.unlock()
        guard isLatest else {
            return
        }

        for (identifier, session) in sessions {
            if let target = wanted[identifier], session.outputDeviceID == outputDeviceID {
                if target.target == session.target || session.update(to: target.target) {
                    continue
                }
            }
            session.stop()
            sessions[identifier] = nil
        }
        var failureText: String?
        for (identifier, target) in wanted where sessions[identifier] == nil {
            do {
                sessions[identifier] = try ProtectionSession(
                    name: target.name, target: target.target, outputDeviceID: outputDeviceID
                )
            } catch {
                failureText = "Could not protect \(target.name): \(error)"
                writeLogLine("could not protect \(target.name): \(error)")
            }
        }

        let sessionCount = sessions.count
        DispatchQueue.main.async { [weak self] in
            self?.activeSessionCount = sessionCount
            self?.lastFailureText = failureText
            self?.onChange?()
        }
    }

    private func observe(_ selector: AudioObjectPropertySelector) {
        var address = systemPropertyAddress(selector)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            self?.refresh()
        }
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = ProtectionManager()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        manager.onChange = { [weak self] in self?.updateStatusIcon() }

        #if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--replay-buffer-frames"), index + 1 < arguments.count,
           let frameCount = UInt32(arguments[index + 1]) {
            replayBufferFrameCount = frameCount
        }
        if let index = arguments.firstIndex(of: "--protect-process-id"), index + 1 < arguments.count,
           let processIdentifier = pid_t(arguments[index + 1]) {
            manager.protectProcessForTesting(processIdentifier)
            return
        }
        #endif
        manager.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stopAll()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Call ducking", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let allItem = NSMenuItem(title: "Off for all apps", action: #selector(selectAllApplications), keyEquivalent: "")
        allItem.target = self
        allItem.state = manager.mode == .allApplications ? .on : .off
        menu.addItem(allItem)

        let chosenItem = NSMenuItem(title: "Off for chosen apps", action: nil, keyEquivalent: "")
        chosenItem.state = manager.mode == .chosenApplications ? .on : .off
        chosenItem.submenu = chosenApplicationsMenu()
        menu.addItem(chosenItem)

        let offItem = NSMenuItem(title: "On (normal macOS)", action: #selector(selectOff), keyEquivalent: "")
        offItem.target = self
        offItem.state = manager.mode == .off ? .on : .off
        menu.addItem(offItem)

        menu.addItem(.separator())
        let summary = NSMenuItem(title: summaryText(), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        if let failureText = manager.lastFailureText {
            let failure = NSMenuItem(title: failureText, action: nil, keyEquivalent: "")
            failure.isEnabled = false
            menu.addItem(failure)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NoDucking", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func chosenApplicationsMenu() -> NSMenu {
        let submenu = NSMenu()
        let useChosen = NSMenuItem(title: "Use only the ticked apps", action: #selector(selectChosenApplications), keyEquivalent: "")
        useChosen.target = self
        useChosen.state = manager.mode == .chosenApplications ? .on : .off
        submenu.addItem(useChosen)
        submenu.addItem(.separator())

        var entries: [String: (name: String, icon: NSImage?)] = [:]
        for (identifier, application) in audioApplications() {
            entries[identifier] = (application.name, application.icon)
        }
        for (identifier, name) in manager.protectedApplicationNames where entries[identifier] == nil {
            entries[identifier] = ("\(name) (not running)", nil)
        }
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No apps are using audio", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for (identifier, entry) in entries.sorted(by: { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }) {
            let item = NSMenuItem(title: entry.name, action: #selector(toggleApplication(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = identifier
            item.state = manager.isProtected(identifier) ? .on : .off
            if let icon = entry.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            submenu.addItem(item)
        }
        return submenu
    }

    private func summaryText() -> String {
        guard isDuckRequestAvailable else {
            return "Not available on this macOS version"
        }
        let count = manager.activeSessionCount
        switch manager.mode {
        case .allApplications:
            return count > 0 ? "Protecting all apps" : "Not protecting yet"
        case .chosenApplications:
            return count == 0 ? "Not protecting any app" : "Protecting \(count) app\(count == 1 ? "" : "s")"
        case .off:
            return "Ducking is on"
        }
    }

    @objc private func selectAllApplications() {
        manager.setMode(.allApplications)
    }

    @objc private func selectChosenApplications() {
        manager.setMode(.chosenApplications)
    }

    @objc private func selectOff() {
        manager.setMode(.off)
    }

    @objc private func toggleApplication(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else {
            return
        }
        let name = sender.title.replacingOccurrences(of: " (not running)", with: "")
        manager.setProtected(!manager.isProtected(identifier), identifier: identifier, name: name)
        if manager.mode != .chosenApplications {
            manager.setMode(.chosenApplications)
        }
    }

    private func updateStatusIcon() {
        let symbolName = manager.activeSessionCount > 0 ? "speaker.wave.2.fill" : "speaker.wave.2"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NoDucking")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }
}

#if DEBUG
if CommandLine.arguments.contains("--list-applications") {
    for (identifier, listed) in audioApplications().sorted(by: { $0.value.name < $1.value.name }) {
        print("\(listed.name)\t\(identifier)\t\(listed.processObjectIDs.count) audio process(es)")
    }
    exit(0)
}
#endif

let application = NSApplication.shared
let applicationDelegate = ApplicationDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.run()
