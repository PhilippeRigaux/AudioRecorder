// AudioRecorder: Command-line macOS tool using AVFoundation and Swifter
// Listens for audio input, detects sound thresholds, records to AIFF,
// and exposes HTTP endpoints for remote control.
import Foundation
import AVFoundation
import Swifter
import AudioUnit

// Parse command-line arguments
var serverPort: Int = 8000
let args = CommandLine.arguments
for i in 1..<args.count {
    let arg = args[i]
    if arg == "-h" || arg == "--help" {
        print("""
        Usage: AudioRecorder [-p port]
        
        Options:
          -h, --help     Affiche ce message d'aide.
          -p <port>      Définit le port HTTP (par défaut 8000).
        """)
        exit(0)
    } else if arg == "-p", i + 1 < args.count {
        if let port = Int(args[i+1]) {
            serverPort = port
        } else {
            print("Port invalide : \(args[i+1])")
            exit(1)
        }
    }
}


// MARK: - Configuration and global state

var sampleRate: Double          = 96_000.0
var bitDepth:  Int               = 24
var channels:  AVAudioChannelCount = 2
let bufferSize: AVAudioFrameCount = 4096

var startThreshold: Double     = 3.0    // % RMS pour démarrer
var stopThreshold:  Double     = 1.0    // % RMS pour stopper
var stopTimeout:   TimeInterval = 60.0  // en secondes

var outputFileURL = URL(fileURLWithPath: "capture.aiff")
var recording      = false
var waitingForStart = false
var detectedStart   = false
var lastAboveTime   = Date().timeIntervalSince1970
var recordingStart  = Date()
var currentLevel: Double = 0.0

// Name of the input audio device to record (set via /setdevice endpoint), applied via HAL input unit
var inputDeviceName: String? = nil

/// Return the AudioDeviceID for the device matching the given name
func audioDeviceID(forName name: String) -> AudioDeviceID? {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr else {
        return nil
    }
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(), count: deviceCount)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs) == noErr else {
        return nil
    }
    for id in deviceIDs {
        var deviceName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Safely get the CFString property
        let status: OSStatus = withUnsafeMutablePointer(to: &deviceName) { ptr in
            AudioObjectGetPropertyData(
                id,
                &nameAddress,
                0,
                nil,
                &nameSize,
                UnsafeMutableRawPointer(ptr)
            )
        }
        if status == noErr, (deviceName as String) == name {
            return id
        }
    }
    return nil
}

let server = HttpServer()
// HTTP help endpoint: lists all available commands and their usage
server["/help"] = { _ in
    let txt = """
    Available commands:
      GET /setdevice?deviceName=<deviceName>        Set input device name (applied on next recording start)
      GET /setformat?format=<rate>-<bits>-<channels> Set sample format (applied on next recording start)
      GET /setfile?path=<filePath>                   Set output AIFF file path
      GET /setthresholds?startThreshold=<n>&stopThreshold=<n>&stopTimeout=<ms> Update detection thresholds (timeout in ms)
      GET /start                                     Start listening and await sound detection
      GET /stop                                      Stop recording immediately
      GET /status                                    Return current state in JSON
    """
    return .ok(.text(txt))
}

// /status: return JSON with current recording state, device, file path, format, sound level, and duration
server["/status"] = { _ in
    let state: Any = detectedStart
        ? true
        : (waitingForStart ? "waiting" : false)
    let duration = detectedStart
        ? Int(Date().timeIntervalSince(recordingStart))
        : 0
    let info: [String: Any] = [
      "recording":   state,
      "device":      inputDeviceName ?? "default",
      "file":        outputFileURL.path,
      "format":      "\(Int(sampleRate))-\(bitDepth)-\(channels)",
      "soundLevel":  String(format: "%.2f", currentLevel),
      "duration":    duration
    ]
    do {
        let jsonData = try JSONSerialization.data(
            withJSONObject: info,
            options: [.withoutEscapingSlashes]
        )
        return HttpResponse.raw(
            200, "OK",
            ["Content-Type": "application/json"]
        ) { writer in
            try writer.write(jsonData)
        }
    } catch {
        return .internalServerError
    }
}

// /setdevice: set the desired input device by name (stored, actual routing applied on next /start)
server["/setdevice"] = { req in
    if let name = req.queryParams.first(where: { $0.0 == "deviceName" })?.1,
       !name.isEmpty {
        inputDeviceName = name
        return .ok(.text("Will record from device '\(name)'"))
    } else {
        return .badRequest(.text("Missing or empty 'deviceName' parameter"))
    }
}

// /setformat: update desired sample format (rate-bits-channels) for future recordings
server["/setformat"] = { req in
    if let fmt = req.queryParams.first(where: { $0.0 == "format" })?.1 {
        let parts = fmt.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return .badRequest(.text("Error: format must be RATE-BITS-CHANS"))
        }
        // Update global format variables
        sampleRate = Double(parts[0])
        bitDepth   = parts[1]
        channels   = AVAudioChannelCount(parts[2])
        return .ok(.text("Format set to \(fmt) — applied on next recording start"))
    } else {
        return .badRequest(.text("Missing 'format' parameter"))
    }
}

// /setfile: change output file path for recording
server["/setfile"] = { req in
    if let path = req.queryParams.first(where: { $0.0 == "path" })?.1,
       !path.isEmpty {
        outputFileURL = URL(fileURLWithPath: path)
        return .ok(.text("Recording file set to \(outputFileURL.path)"))
    } else {
        return .badRequest(.text("Missing or empty 'path' parameter"))
    }
}

// /setthresholds: adjust start/stop RMS thresholds and silence timeout (in ms) for detection logic
server["/setthresholds"] = { req in
    let params = Dictionary(uniqueKeysWithValues: req.queryParams)
    if let s = params["startThreshold"], let v = Double(s) {
        startThreshold = v
    }
    if let s = params["stopThreshold"], let v = Double(s) {
        stopThreshold = v
    }
    if let s = params["stopTimeout"], let v = Double(s) {
        stopTimeout = v / 1000.0
    }
    return .ok(.text("Thresholds updated: startThreshold=\(startThreshold), stopThreshold=\(stopThreshold), stopTimeout=\(stopTimeout)"))
}

// /start: begin listening, wait for sound above threshold, then record
server["/start"] = { _ in
    guard !recording else {
      return .badRequest(.text("Already recording"))
    }
    recording = true
    waitingForStart = true
    detectedStart = false
    lastAboveTime = Date().timeIntervalSince1970
    DispatchQueue.global(qos: .userInitiated).async {
      AudioRecorder.shared.start()
    }
    return .ok(.text("Recording started, awaiting sound"))
}

// /stop: immediately stop recording and close file
server["/stop"] = { _ in
    guard recording else {
      return .badRequest(.text("No recording in progress"))
    }
    AudioRecorder.shared.stop()
    return .ok(.text("Recording stopped"))
}

do {
    try server.start(UInt16(serverPort), forceIPv4: true)
    print("HTTP server started on port \(serverPort)")
} catch {
    print("Error starting server: \(error)")
}

// MARK: – Moteur audio et détection

class AudioRecorder {
  static let shared = AudioRecorder()
  private let engine = AVAudioEngine()
  
  private var audioFile: AVAudioFile?
  
  private init() {
      // Intentionally left empty; prepare the engine in start()
  }
  
  func start() {
    // Retrieve the engine’s input node for audio capture
    let input = engine.inputNode
    // If a device name has been selected, route the input node to that device via HAL
    if let deviceName = inputDeviceName,
       let deviceID = audioDeviceID(forName: deviceName) {
        var id = deviceID
        AudioUnitSetProperty(
            input.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
    // Determine the audio format from the input node
    let fmt = input.inputFormat(forBus: 0)
    // Remove any existing tap to avoid multiple taps
    input.removeTap(onBus: 0)
    // Install a tap to receive audio buffers for level detection and writing
    input.installTap(onBus: 0, bufferSize: bufferSize, format: fmt) { [weak self] buffer, _ in
        self?.process(buffer: buffer)
    }
    // Prepare the audio engine now that nodes and taps are configured
    engine.prepare()
    do {
        try engine.start()
    } catch {
        print("Audio engine start error:", error)
        recording = false
        return
    }
  
    // Create AVAudioFile for writing PCM data (AIFF container)
    let settings: [String: Any] = [
      AVFormatIDKey:            kAudioFormatLinearPCM,
      AVSampleRateKey:          sampleRate,
      AVNumberOfChannelsKey:    channels,
      AVLinearPCMBitDepthKey:   bitDepth,
      AVLinearPCMIsFloatKey:    false,
      AVLinearPCMIsBigEndianKey:false
    ]
    do {
      audioFile = try AVAudioFile(forWriting: outputFileURL,
                                  settings: settings)
      lastAboveTime = Date().timeIntervalSince1970
      currentLevel = 0.0
    } catch {
      print("Cannot create file:", error)
      return
    }
  }
  
  func stop() {
    // Stop the audio engine and remove processing tap
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    // Reset level indicator to zero
    currentLevel = 0.0
    audioFile = nil
    recording = false
    waitingForStart = false
    detectedStart = false
  }
  
  private func process(buffer: AVAudioPCMBuffer) {
    // Calculate RMS level of incoming audio buffer to monitor sound level
    guard let chData = buffer.floatChannelData?[0] else { return }
    let frameCount = Int(buffer.frameLength)
    var sum: Float = 0
    for i in 0..<frameCount { sum += abs(chData[i]) }
    let rms = sum / Float(frameCount)
    currentLevel = Double(rms) * 100.0
    
    // Detect start of sound: when level exceeds startThreshold, mark start time
    if waitingForStart && currentLevel > startThreshold {
      // mark actual recording start time on detection
      recordingStart = Date()
      detectedStart   = true
      waitingForStart = false
      DispatchQueue.main.async {
          let lvl = String(format: "%.2f", currentLevel)
          let thr = String(format: "%.2f", startThreshold)
          print("→ Sound detected at level \(lvl)% (threshold: \(thr)%)")
      }
    }
    
    // Write audio data to file once recording has started
    if detectedStart, let file = audioFile {
      do {
        try file.write(from: buffer)
      } catch {
        print("Write error:", error)
      }
      if currentLevel > stopThreshold {
        lastAboveTime = Date().timeIntervalSince1970
      }
      if Date().timeIntervalSince1970 - lastAboveTime > stopTimeout {
        DispatchQueue.main.async {
          // Auto-stop recording after prolonged silence
          print("→ Prolonged silence detected, stopping automatically.")
          AudioRecorder.shared.stop()
        }
      }
    }
  }
}

// Keep the run loop alive to continue processing audio and HTTP requests
RunLoop.main.run()
