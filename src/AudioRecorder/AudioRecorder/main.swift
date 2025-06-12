import Foundation
import AVFoundation
import Swifter

// MARK: – Configuration et état global

let sampleRate: Double          = 96_000.0
let bitDepth:  Int               = 24
let channels:  AVAudioChannelCount = 2
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

// Device sélectionnable (TODO : implémenter si besoin via CoreAudio API)
var inputDeviceName: String? = nil

// MARK: – Serveur HTTP

let server = HttpServer()

server["/help"] = { _ in
    let txt = """
    Available commands:
      GET /setdevice?deviceName=<deviceName>        Set input device name (non implémenté, utilise le device par défaut)
      GET /setformat?format=<rate>-<bits>-<channels> Set sample format (ex. 48000-24-2, non appliqué dynamiquement)
      GET /setfile?path=<filePath>                   Set output AIFF file path
      GET /setthresholds?startThreshold=<n>&stopThreshold=<n>&stopTimeout=<ms> Update detection thresholds (timeout en ms)
      GET /start                                     Start listening and await sound detection
      GET /stop                                      Stop recording immediately
      GET /status                                    Return current state in JSON
    """
    return .ok(.text(txt))
}

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

server["/setdevice"] = { req in
    if let name = req.queryParams.first(where: { $0.0 == "deviceName" })?.1,
       !name.isEmpty {
        inputDeviceName = name
        return .ok(.text("Input device set to \(name)"))
    } else {
        return .badRequest(.text("Missing or empty 'deviceName' parameter"))
    }
}

server["/setformat"] = { req in
    if let fmt = req.queryParams.first(where: { $0.0 == "format" })?.1 {
        let parts = fmt.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return .badRequest(.text("Error: format must be RATE-BITS-CHANS"))
        }
        return .ok(.text("Format set to \(fmt) — (non appliqué dans cette version)"))
    } else {
        return .badRequest(.text("Missing 'format' parameter"))
    }
}

server["/setfile"] = { req in
    if let path = req.queryParams.first(where: { $0.0 == "path" })?.1,
       !path.isEmpty {
        outputFileURL = URL(fileURLWithPath: path)
        return .ok(.text("Recording file set to \(outputFileURL.path)"))
    } else {
        return .badRequest(.text("Missing or empty 'path' parameter"))
    }
}

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

server["/stop"] = { _ in
    guard recording else {
      return .badRequest(.text("No recording in progress"))
    }
    AudioRecorder.shared.stop()
    return .ok(.text("Recording stopped"))
}

do {
  try server.start(UInt16(8000), forceIPv4: true)
  print("HTTP server started on port 8000")
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
    // (Re)install tap for audio processing
    let input = engine.inputNode
    let fmt = input.inputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: bufferSize, format: fmt) { [weak self] buffer, _ in
        self?.process(buffer: buffer)
    }
    engine.prepare()
    
    do {
      try engine.start()
    } catch {
      print("Audio engine start error:", error)
      recording = false
      return
    }
    
    // Création du fichier AVAudioFile (écriture WAV PCM)
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
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    currentLevel = 0.0
    audioFile = nil
    recording = false
    waitingForStart = false
    detectedStart = false
  }
  
  private func process(buffer: AVAudioPCMBuffer) {
    // Calcul du RMS
    guard let chData = buffer.floatChannelData?[0] else { return }
    let frameCount = Int(buffer.frameLength)
    var sum: Float = 0
    for i in 0..<frameCount { sum += abs(chData[i]) }
    let rms = sum / Float(frameCount)
    currentLevel = Double(rms) * 100.0
    
    // Logique de début d’enregistrement
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
    
    // Une fois démarré, on écrit les buffers et on gère timeout de silence
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
          print("→ Silence prolongée, arrêt auto.")
          AudioRecorder.shared.stop()
        }
      }
    }
  }
}

// Garde le programme vivant
RunLoop.main.run()
