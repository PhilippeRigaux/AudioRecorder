

# AudioRecorder

A command-line macOS tool written in Swift that uses **AVFoundation** and **Swifter** to:

- Listen for audio input
- Detect when sound exceeds a configurable RMS threshold
- Record audio into an AIFF file
- Expose HTTP endpoints for remote control of recording parameters and actions

---

## Table of Contents

- [Features](#features)  
- [Installation](#installation)  
- [Usage](#usage)  
  - [HTTP API](#http-api)  
  - [Examples](#examples)  
- [Configuration Options](#configuration-options)  
- [How It Works](#how-it-works)  
- [Requirements](#requirements)  
- [License](#license)  

---

## Features

- **Automatic start/stop**  
  - Begins writing audio only when sound level exceeds `startThreshold`.  
  - Stops after `stopTimeout` milliseconds of silence below `stopThreshold`.

- **Configurable detection thresholds**  
  - `startThreshold` (% RMS)  
  - `stopThreshold` (% RMS)  
  - `stopTimeout` (ms)

- **Dynamic recording format**  
  - Change sample rate, bit depth, and channel count before starting a recording.

- **Output file management**  
  - Specify AIFF file path for each recording session.

- **Input device selection**  
  - Choose any installed audio input device by name.

- **HTTP remote control**  
  - Start, stop, and configure via simple GET endpoints on port **8000**.

---

## Installation

1. **Clone the repository**  
   ```bash
   git clone https://github.com/<your-username>/AudioRecorder.git
   cd AudioRecorder
   ```

2. **Build**  
   ```bash
   swift build -c release
   ```

3. **Run**  
   ```bash
   .build/release/AudioRecorder
   ```
   This starts an HTTP server on port 8000 and begins the run loop.

---

## Usage

Once running, control the recorder via HTTP GET requests:

### HTTP API

| Endpoint                                         | Description                                                            |
| ------------------------------------------------ | ---------------------------------------------------------------------- |
| `/help`                                          | Show available commands                                               |
| `/status`                                        | Get JSON status of recorder (state, device, file, format, level, time) |
| `/setdevice?deviceName=<name>`                   | Select input device by name (applied on next recording start)          |
| `/setformat?format=<rate>-<bits>-<channels>`     | Set sample format (applied on next recording start)                    |
| `/setfile?path=<filePath>`                       | Set output AIFF file path (for next recording)                        |
| `/setthresholds?startThreshold=<n>&stopThreshold=<n>&stopTimeout=<ms>` | Adjust detection thresholds and silence timeout (ms)      |
| `/start`                                         | Begin listening and record when threshold is crossed                  |
| `/stop`                                          | Stop recording immediately                                            |

### Examples

- **Show help**  
  ```bash
  curl http://localhost:8000/help
  ```

- **Check status**  
  ```bash
  curl http://localhost:8000/status
  ```

- **Change input device**  
  ```bash
  curl "http://localhost:8000/setdevice?deviceName=BuiltIn%20Microphone"
  ```

- **Configure format**  
  ```bash
  curl "http://localhost:8000/setformat?format=48000-24-2"
  ```

- **Set output file**  
  ```bash
  curl "http://localhost:8000/setfile?path=/Users/you/Desktop/session.aiff"
  ```

- **Adjust thresholds**  
  ```bash
  curl "http://localhost:8000/setthresholds?startThreshold=5&stopThreshold=2&stopTimeout=5000"
  ```

- **Start recording**  
  ```bash
  curl http://localhost:8000/start
  ```

- **Stop recording**  
  ```bash
  curl http://localhost:8000/stop
  ```

---

## Configuration Options

- **sampleRate** (`Double`)  
- **bitDepth** (`Int`)  
- **channels** (`Int`)  
- **outputFileURL** (AIFF file path)  
- **startThreshold** (`Double`, % RMS)  
- **stopThreshold** (`Double`, % RMS)  
- **stopTimeout** (`TimeInterval`, seconds)

Adjust these via the corresponding HTTP endpoints before starting a recording.

### Default Values

| Option          | Default Value               |
| --------------- | --------------------------- |
| `sampleRate`    | `96000.0`                   |
| `bitDepth`      | `24`                        |
| `channels`      | `2`                         |
| `outputFileURL` | `capture.aiff`              |
| `startThreshold`| `3.0` (% RMS)              |
| `stopThreshold` | `1.0` (% RMS)              |
| `stopTimeout`   | `60.0` (seconds)            |

---

## How It Works

1. **AVAudioEngine** captures audio from the input node.  
2. A **tap** computes the RMS level on each buffer.  
3. When RMS > `startThreshold`, a new **AVAudioFile** is created and buffers are written.  
4. When RMS stays below `stopThreshold` for longer than `stopTimeout`, recording stops automatically.  
5. The built‑in **Swifter** HTTP server exposes control endpoints for remote configuration.

---

## Requirements

- macOS 12.0 or later  
- Xcode 14 / Swift 5.7+  
- Microphone permission (if using default device)

---

## License

MIT License © [Your Name]