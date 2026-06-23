import CoreAudio
import Foundation

/// Queries and drives the output DAC's nominal sample rate so the engine can
/// run device-rate-matched (no SRC anywhere in the chain).
enum BitPerfect {
    static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    static func supportedSampleRates(of device: AudioDeviceID) -> [ClosedRange<Double>] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map { $0.mMinimum...$0.mMaximum }
    }

    /// Sets the DAC to `rate` if it supports it. Returns true when the device
    /// rate matches afterwards.
    @discardableResult
    static func matchDeviceRate(to rate: Double) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        if nominalSampleRate(of: device) == rate { return true }
        guard supportedSampleRates(of: device).contains(where: { $0.contains(rate) }) else { return false }
        var newRate = Float64(rate)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil,
                                                UInt32(MemoryLayout<Float64>.size), &newRate)
        guard status == noErr else { return false }
        // The switch is asynchronous; poll briefly.
        for _ in 0..<20 {
            if nominalSampleRate(of: device) == rate { return true }
            usleep(25_000)
        }
        return nominalSampleRate(of: device) == rate
    }
}
