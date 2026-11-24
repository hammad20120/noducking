import AppKit
import CoreAudio
import Darwin

struct AudioApplication {
    let identifier: String
    let name: String
    let icon: NSImage?
    var processObjectIDs: [AudioObjectID]
}

private typealias ResponsibleProcessFunction = @convention(c) (pid_t) -> pid_t

private let responsibleProcessFunction: ResponsibleProcessFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ResponsibleProcessFunction.self)
}()

func systemPropertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func defaultOutputDeviceID() -> AudioDeviceID {
    var address = systemPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    return deviceID
}

func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = systemPropertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let string = value?.takeRetainedValue() else {
        return nil
    }
    return string as String
}

func audioObjectID(forProcessIdentifier processIdentifier: pid_t) -> AudioObjectID? {
    var address = systemPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var qualifier = processIdentifier
    var objectID = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &objectID
    )
    guard status == noErr, objectID != 0 else {
        return nil
    }
    return objectID
}

private func audioProcessObjectIDs() -> [AudioObjectID] {
    var address = systemPropertyAddress(kAudioHardwarePropertyProcessObjectList)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
        return []
    }
    var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs) == noErr else {
        return []
    }
    return objectIDs
}

private func processIdentifier(of objectID: AudioObjectID) -> pid_t? {
    var address = systemPropertyAddress(kAudioProcessPropertyPID)
    var processIdentifier = pid_t(0)
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &processIdentifier) == noErr, processIdentifier > 0 else {
        return nil
    }
    return processIdentifier
}

private func parentProcessIdentifier(of processIdentifier: pid_t) -> pid_t? {
    var information = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &information, size) == size else {
        return nil
    }
    let parent = pid_t(information.pbi_ppid)
    return parent > 1 ? parent : nil
}

private func regularApplication(forProcessIdentifier processIdentifier: pid_t) -> NSRunningApplication? {
    guard let application = NSRunningApplication(processIdentifier: processIdentifier),
          application.bundleIdentifier != nil,
          application.activationPolicy == .regular else {
        return nil
    }
    return application
}

private func owningApplication(of processIdentifier: pid_t) -> NSRunningApplication? {
    if let responsible = responsibleProcessFunction?(processIdentifier), responsible > 0,
       let owner = regularApplication(forProcessIdentifier: responsible) {
        return owner
    }
    var current = processIdentifier
    for _ in 0..<6 {
        if let owner = regularApplication(forProcessIdentifier: current) {
            return owner
        }
        guard let parent = parentProcessIdentifier(of: current) else {
            return nil
        }
        current = parent
    }
    return nil
}

private func isRunningInput(_ objectID: AudioObjectID) -> Bool {
    var address = systemPropertyAddress(kAudioProcessPropertyIsRunningInput)
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
        return false
    }
    return value != 0
}

func processObjectIDsToLeaveAlone() -> Set<AudioObjectID>? {
    let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    guard let ownObjectID = audioObjectID(forProcessIdentifier: ownProcessIdentifier) else {
        return nil
    }
    var owners: [AudioObjectID: String] = [:]
    var ownersUsingInput: Set<String> = []
    var leftAlone: Set<AudioObjectID> = [ownObjectID]
    for objectID in audioProcessObjectIDs() where objectID != ownObjectID {
        let owner = processIdentifier(of: objectID).flatMap { owningApplication(of: $0)?.bundleIdentifier }
        if let owner {
            owners[objectID] = owner
        }
        if isRunningInput(objectID) {
            leftAlone.insert(objectID)
            if let owner {
                ownersUsingInput.insert(owner)
            }
        }
    }
    for (objectID, owner) in owners where ownersUsingInput.contains(owner) {
        leftAlone.insert(objectID)
    }
    return leftAlone
}

func audioApplications() -> [String: AudioApplication] {
    let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    var applications: [String: AudioApplication] = [:]
    for objectID in audioProcessObjectIDs() {
        guard let processIdentifier = processIdentifier(of: objectID),
              let owner = owningApplication(of: processIdentifier),
              owner.processIdentifier != ownProcessIdentifier,
              let identifier = owner.bundleIdentifier else {
            continue
        }
        if applications[identifier] == nil {
            applications[identifier] = AudioApplication(
                identifier: identifier,
                name: owner.localizedName ?? identifier,
                icon: owner.icon,
                processObjectIDs: []
            )
        }
        applications[identifier]?.processObjectIDs.append(objectID)
    }
    return applications
}
