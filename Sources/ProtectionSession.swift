import CoreAudio
import Darwin
import Foundation
import os

private let protectionLog = Logger(subsystem: "dev.noducking.NoDucking", category: "protection")

func writeLogLine(_ text: String) {
    protectionLog.notice("\(text, privacy: .public)")
}

private typealias DuckRequestFunction = @convention(c) (AudioDeviceID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

private let duckRequestFunction: DuckRequestFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck") else {
        return nil
    }
    return unsafeBitCast(symbol, to: DuckRequestFunction.self)
}()

var isDuckRequestAvailable: Bool {
    duckRequestFunction != nil
}

let heldRequestLevel = Float(1).nextDown
let clearedRequestLevel = Float(1)
var replayBufferFrameCount = UInt32(128)

@discardableResult
func setDuckLevel(_ level: Float, on deviceID: AudioDeviceID) -> OSStatus {
    guard let duckRequestFunction else {
        return kAudioHardwareUnsupportedOperationError
    }
    return duckRequestFunction(deviceID, level, nil, 0)
}

final class OutputDeviceRequests {
    private let lock = NSLock()
    private var holderCounts: [AudioDeviceID: Int] = [:]

    func hold(on deviceID: AudioDeviceID) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let holderCount = (holderCounts[deviceID] ?? 0) + 1
        holderCounts[deviceID] = holderCount
        return holderCount == 1 ? setDuckLevel(heldRequestLevel, on: deviceID) : noErr
    }

    func release(on deviceID: AudioDeviceID) {
        lock.lock()
        defer { lock.unlock() }
        guard let holderCount = holderCounts[deviceID] else {
            return
        }
        if holderCount <= 1 {
            holderCounts[deviceID] = nil
            setDuckLevel(clearedRequestLevel, on: deviceID)
        } else {
            holderCounts[deviceID] = holderCount - 1
        }
    }
}

let outputDeviceRequests = OutputDeviceRequests()

struct ProtectionError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed with status \(status)" }
}

enum ProtectionTarget: Equatable {
    case processes(Set<AudioObjectID>)
    case everythingExcept(Set<AudioObjectID>)

    var listedProcessObjectIDs: Set<AudioObjectID> {
        switch self {
        case .processes(let processObjectIDs), .everythingExcept(let processObjectIDs):
            return processObjectIDs
        }
    }

    func hasSameKind(as other: ProtectionTarget) -> Bool {
        switch (self, other) {
        case (.processes, .processes), (.everythingExcept, .everythingExcept):
            return true
        default:
            return false
        }
    }
}

final class ProtectionSession {
    private(set) var target: ProtectionTarget
    let outputDeviceID: AudioDeviceID

    private var tapSettings: CATapDescription?
    private var tapObjectID = AudioObjectID(0)
    private var aggregateDeviceID = AudioDeviceID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private var holdsOutputDeviceRequest = false

    init(name: String, target: ProtectionTarget, outputDeviceID: AudioDeviceID) throws {
        self.target = target
        self.outputDeviceID = outputDeviceID
        do {
            try start(name: name)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func update(to newTarget: ProtectionTarget) -> Bool {
        guard tapObjectID != 0, var description = tapSettings, target.hasSameKind(as: newTarget) else {
            return false
        }
        description.processes = Array(newTarget.listedProcessObjectIDs)
        var address = systemPropertyAddress(kAudioTapPropertyDescription)
        let status = withUnsafePointer(to: &description) { pointer in
            AudioObjectSetPropertyData(tapObjectID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        writeLogLine("tap \(tapObjectID) processes changed to \(newTarget.listedProcessObjectIDs.sorted()): status \(status)")
        guard status == noErr else {
            return false
        }
        target = newTarget
        return true
    }

    private func start(name: String) throws {
        guard let outputDeviceIdentifier = stringProperty(outputDeviceID, kAudioDevicePropertyDeviceUID) else {
            throw ProtectionError(step: "reading the output device identifier", status: -1)
        }

        let tapSettings: CATapDescription
        switch target {
        case .processes(let processObjectIDs):
            tapSettings = CATapDescription(stereoMixdownOfProcesses: Array(processObjectIDs))
        case .everythingExcept(let excludedProcessObjectIDs):
            tapSettings = CATapDescription(
                excludingProcesses: Array(excludedProcessObjectIDs), deviceUID: outputDeviceIdentifier, stream: 0
            )
        }
        self.tapSettings = tapSettings
        tapSettings.uuid = UUID()
        tapSettings.name = "NoDucking \(name)"
        tapSettings.isPrivate = true
        tapSettings.muteBehavior = .mutedWhenTapped
        var status = AudioHardwareCreateProcessTap(tapSettings, &tapObjectID)
        guard status == noErr else {
            throw ProtectionError(step: "creating the process tap", status: status)
        }

        let combinedDeviceSettings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NoDucking \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceIdentifier,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceIdentifier]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapSettings.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(combinedDeviceSettings as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            throw ProtectionError(step: "creating the combined device", status: status)
        }

        var inputStreamCount = 0
        for _ in 0..<20 {
            inputStreamCount = ProtectionSession.inputStreamCount(of: aggregateDeviceID)
            if inputStreamCount > 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard inputStreamCount > 0 else {
            throw ProtectionError(step: "waiting for the tap stream", status: -1)
        }
        let tapStreamIndex = inputStreamCount - 1

        var bufferFrameCount = replayBufferFrameCount
        var bufferAddress = systemPropertyAddress(kAudioDevicePropertyBufferFrameSize)
        let bufferStatus = AudioObjectSetPropertyData(
            aggregateDeviceID, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferFrameCount
        )
        var bufferSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(aggregateDeviceID, &bufferAddress, 0, nil, &bufferSize, &bufferFrameCount)
        writeLogLine("replay buffer asked \(replayBufferFrameCount) frames: status \(bufferStatus), now \(bufferFrameCount)")

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inputData, _, outputData, _ in
            ProtectionSession.copyTappedAudio(from: inputData, tapStreamIndex: tapStreamIndex, to: outputData)
        }
        guard status == noErr else {
            throw ProtectionError(step: "creating the replay callback", status: status)
        }

        let streamUsageStatus = enableOnlyInputStream(at: tapStreamIndex, of: inputStreamCount)
        let outputDeviceInputStreamCount = ProtectionSession.inputStreamCount(of: outputDeviceID)
        writeLogLine("input streams on combined device: \(inputStreamCount), on output device: \(outputDeviceInputStreamCount), reading only stream \(tapStreamIndex): status \(streamUsageStatus)")

        let aggregateDuckStatus = setDuckLevel(heldRequestLevel, on: aggregateDeviceID)
        let outputDuckStatus = outputDeviceRequests.hold(on: outputDeviceID)
        holdsOutputDeviceRequest = true
        writeLogLine("duck request \(heldRequestLevel) on combined device \(aggregateDeviceID): status \(aggregateDuckStatus), on output device \(outputDeviceID): status \(outputDuckStatus)")

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            throw ProtectionError(step: "starting the replay", status: status)
        }
        writeLogLine("protecting \(name): tap \(tapObjectID), combined device \(aggregateDeviceID), target \(target)")
    }

    func stop() {
        if aggregateDeviceID != 0 {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            setDuckLevel(clearedRequestLevel, on: aggregateDeviceID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if holdsOutputDeviceRequest {
            outputDeviceRequests.release(on: outputDeviceID)
            holdsOutputDeviceRequest = false
        }
        if tapObjectID != 0 {
            AudioHardwareDestroyProcessTap(tapObjectID)
        }
        ioProcID = nil
        aggregateDeviceID = 0
        tapObjectID = 0
        tapSettings = nil
    }

    private static func inputStreamCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return 0
        }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private func enableOnlyInputStream(at streamIndex: Int, of streamCount: Int) -> OSStatus {
        guard let ioProcID else {
            return -1
        }
        let headerByteCount = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalByteCount = headerByteCount + streamCount * MemoryLayout<UInt32>.size
        let usage = UnsafeMutableRawPointer.allocate(
            byteCount: totalByteCount, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment
        )
        defer { usage.deallocate() }
        usage.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(streamCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for index in 0..<streamCount {
            let isOn: UInt32 = index == streamIndex ? 1 : 0
            usage.storeBytes(of: isOn, toByteOffset: headerByteCount + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(aggregateDeviceID, &address, 0, nil, UInt32(totalByteCount), usage)
    }

    static func copyTappedAudio(from inputData: UnsafePointer<AudioBufferList>, tapStreamIndex: Int, to outputData: UnsafeMutablePointer<AudioBufferList>) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        var outputChannelTotal = 0
        for buffer in outputBuffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            outputChannelTotal += Int(buffer.mNumberChannels)
        }
        guard !inputBuffers.isEmpty, outputChannelTotal > 0 else {
            return
        }
        let tapBuffer = inputBuffers[min(tapStreamIndex, inputBuffers.count - 1)]
        guard let tapSamples = tapBuffer.mData?.assumingMemoryBound(to: Float32.self) else {
            return
        }
        let tapChannelCount = Int(tapBuffer.mNumberChannels)
        guard tapChannelCount > 0 else {
            return
        }
        let bytesPerSample = MemoryLayout<Float32>.size
        let tapFrameCount = Int(tapBuffer.mDataByteSize) / (bytesPerSample * tapChannelCount)
        let foldsDown = outputChannelTotal < tapChannelCount
        var outputChannelOffset = 0
        for buffer in outputBuffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0, let outputSamples = buffer.mData?.assumingMemoryBound(to: Float32.self) else {
                outputChannelOffset += channelCount
                continue
            }
            let frameCount = min(tapFrameCount, Int(buffer.mDataByteSize) / (bytesPerSample * channelCount))
            for channel in 0..<channelCount {
                let outputChannel = outputChannelOffset + channel
                if foldsDown {
                    let sourceChannelCount = (tapChannelCount - outputChannel + outputChannelTotal - 1) / outputChannelTotal
                    let scale = 1 / Float(sourceChannelCount)
                    for frame in 0..<frameCount {
                        var sum: Float = 0
                        var sourceChannel = outputChannel
                        while sourceChannel < tapChannelCount {
                            sum += tapSamples[frame * tapChannelCount + sourceChannel]
                            sourceChannel += outputChannelTotal
                        }
                        outputSamples[frame * channelCount + channel] = sum * scale
                    }
                } else if outputChannel < max(2, tapChannelCount) {
                    let tapChannel = min(outputChannel, tapChannelCount - 1)
                    for frame in 0..<frameCount {
                        outputSamples[frame * channelCount + channel] = tapSamples[frame * tapChannelCount + tapChannel]
                    }
                }
            }
            outputChannelOffset += channelCount
        }
    }
}
