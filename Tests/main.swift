import CoreAudio
import Foundation

var failureCount = 0

func makeBufferList(_ buffers: [(channelCount: Int, samples: [Float32])]) -> UnsafeMutableAudioBufferListPointer {
    let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
    for (index, buffer) in buffers.enumerated() {
        let byteCount = buffer.samples.count * MemoryLayout<Float32>.size
        let data = UnsafeMutablePointer<Float32>.allocate(capacity: max(buffer.samples.count, 1))
        data.update(from: buffer.samples, count: buffer.samples.count)
        list[index] = AudioBuffer(mNumberChannels: UInt32(buffer.channelCount), mDataByteSize: UInt32(byteCount), mData: UnsafeMutableRawPointer(data))
    }
    return list
}

func samples(of list: UnsafeMutableAudioBufferListPointer, buffer index: Int) -> [Float32] {
    let buffer = list[index]
    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
    guard let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else {
        return []
    }
    return Array(UnsafeBufferPointer(start: data, count: count))
}

func check(_ name: String, input: [(channelCount: Int, samples: [Float32])], tapStreamIndex: Int, output: [(channelCount: Int, frameCount: Int)], expected: [[Float32]]) {
    let inputList = makeBufferList(input)
    let outputList = makeBufferList(output.map { ($0.channelCount, [Float32](repeating: 9, count: $0.channelCount * $0.frameCount)) })
    ProtectionSession.copyTappedAudio(
        from: UnsafePointer(inputList.unsafeMutablePointer), tapStreamIndex: tapStreamIndex, to: outputList.unsafeMutablePointer
    )
    let actual = (0..<output.count).map { samples(of: outputList, buffer: $0) }
    if actual == expected {
        print("pass  \(name)")
    } else {
        failureCount += 1
        print("FAIL  \(name)\n      expected \(expected)\n      actual   \(actual)")
    }
}

check("stereo tap to stereo output keeps left and right",
      input: [(2, [1, 2, 3, 4])], tapStreamIndex: 0,
      output: [(2, 2)], expected: [[1, 2, 3, 4]])

check("stereo tap to mono output averages both channels",
      input: [(2, [1, 0, 0, 1])], tapStreamIndex: 0,
      output: [(1, 2)], expected: [[0.5, 0.5]])

check("mono tap to stereo output fills both channels",
      input: [(1, [1, 2])], tapStreamIndex: 0,
      output: [(2, 2)], expected: [[1, 1, 2, 2]])

check("stereo tap to four-channel output fills only the first two",
      input: [(2, [1, 2, 3, 4])], tapStreamIndex: 0,
      output: [(4, 2)], expected: [[1, 2, 0, 0, 3, 4, 0, 0]])

check("four-channel tap to stereo output folds channels down",
      input: [(4, [1, 2, 3, 4])], tapStreamIndex: 0,
      output: [(2, 1)], expected: [[2, 3]])

check("stereo tap to two mono output buffers splits left and right",
      input: [(2, [1, 2, 3, 4])], tapStreamIndex: 0,
      output: [(1, 2), (1, 2)], expected: [[1, 3], [2, 4]])

check("tap is read from its own stream, not the microphone stream before it",
      input: [(1, [7, 7]), (2, [1, 2, 3, 4])], tapStreamIndex: 1,
      output: [(2, 2)], expected: [[1, 2, 3, 4]])

check("shorter tap buffer leaves the rest of the output silent",
      input: [(2, [1, 2])], tapStreamIndex: 0,
      output: [(2, 2)], expected: [[1, 2, 0, 0]])

if failureCount > 0 {
    print("\(failureCount) test(s) failed")
    exit(1)
}
print("all tests passed")
