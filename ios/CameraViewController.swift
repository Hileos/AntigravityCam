import UIKit
import Foundation
import AVFoundation
import VideoToolbox
import Network

// MARK: - Connection State Enum
// Build Trigger: Manual Request - On-Screen Encoder Logs
enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting
    
    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
        }
    }
    
    var color: UIColor {
        switch self {
        case .disconnected: return .systemRed
        case .connecting, .reconnecting: return .systemOrange
        case .connected: return .systemGreen
        }
    }
}

class CameraViewController: UIViewController {
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var tcpClient: TCPClient?
    private var videoEncoder: VideoEncoder?
    private var needsKeyFrame = false
    private var isDroppingFrames = false // Recovery State
    private var frameCount: Int = 0 
    
    // Manual Display Display Layer
    private let displayLayer = AVSampleBufferDisplayLayer()
    
    // Connection State Management
    private var connectionState: ConnectionState = .disconnected {
        didSet {
            DispatchQueue.main.async {
                self.updateConnectionUI()
            }
        }
    }
    private var autoReconnectEnabled = false
    private var reconnectTimer: Timer?
    private let reconnectDelay: TimeInterval = 3.0
    private var hasConnectedOnce = false
    
    // Config
    private var serverIP = "192.168.1.2" 
    private let serverPort: UInt32 = 5000
    private let beaconPort: UInt16 = 5001
    private var currentFPS: Double = 30.0
    
    // UDP Beacon for device discovery
    private var beaconListener: BeaconListener?
    
    // Logging Queue context
    private let logQueue = DispatchQueue(label: "com.antigravity.logger")
    
    // UI Elements
    private let ipTextField: UITextField = {
        let tf = UITextField()
        tf.placeholder = "Enter PC IP (e.g. 192.168.1.2)"
        tf.borderStyle = .roundedRect
        tf.backgroundColor = .white
        tf.textColor = .black
        tf.text = "192.168.1.2" // Default
        return tf
    }()
    
    // Connection Status Indicator
    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "● Disconnected"
        label.textColor = .systemRed
        label.font = .systemFont(ofSize: 14, weight: .medium)
        return label
    }()
    
    // Connect/Disconnect Button
    private let connectButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("Connect", for: .normal)
        btn.backgroundColor = .white
        btn.layer.cornerRadius = 5
        return btn
    }()
    
    // Debug Console
    private let debugTextView: UITextView = {
        let tv = UITextView()
        tv.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        tv.textColor = .green
        tv.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.isEditable = false
        tv.isSelectable = false
        return tv
    }()
    
    // Send Logs Button
    private let sendLogsButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("Send Logs", for: .normal)
        btn.backgroundColor = .systemBlue
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 5
        btn.isHidden = false
        return btn
    }()

    // FPS Toggle Button
    private let fpsButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("30 FPS", for: .normal)
        btn.backgroundColor = .systemGray
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 5
        return btn
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        log("App Started. Setting up camera...")
        setupCamera()
        setupEncoder()
        startCapture()
        startBeacon()
    }
    
    private func startBeacon() {
        beaconListener = BeaconListener(port: beaconPort, deviceName: UIDevice.current.name)
        beaconListener?.onLog = { [weak self] msg in
            self?.log(msg)
        }
        beaconListener?.start()
        log("UDP Listener started on port \(beaconPort)")
    }
    
    // Custom Logger
    func log(_ msg: String) {
        logQueue.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let logLine = "[\(timestamp)] \(msg)\n"
            
            // 1. Append to File (Thread Safe)
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fileURL = dir.appendingPathComponent("console.log")
                if let data = logLine.data(using: .utf8) {
                    do {
                        if FileManager.default.fileExists(atPath: fileURL.path) {
                            let fileHandle = try FileHandle(forWritingTo: fileURL)
                            fileHandle.seekToEndOfFile()
                            fileHandle.write(data)
                            fileHandle.closeFile()
                        } else {
                            try data.write(to: fileURL)
                        }
                    } catch {
                        print("File Log Error: \(error)")
                    }
                }
            }
            
            // 2. Update UI (Main Thread via async)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.debugTextView.text = logLine + self.debugTextView.text
                // Keep only last 50 lines
                let lines = self.debugTextView.text.components(separatedBy: "\n")
                if lines.count > 50 {
                    self.debugTextView.text = lines.prefix(50).joined(separator: "\n")
                }
            }
            
            print(msg)
        }
    }
    
    private func setupUI() {
        view.backgroundColor = .black
        
        // Simple Label
        let label = UILabel()
        label.text = "Antigravity Cam"
        label.textColor = .white
        label.frame = CGRect(x: 20, y: 50, width: 200, height: 40)
        view.addSubview(label)
        
        // Status Label (next to title)
        statusLabel.frame = CGRect(x: 220, y: 50, width: 150, height: 40)
        view.addSubview(statusLabel)
        
        // IP Text Field
        ipTextField.frame = CGRect(x: 20, y: 100, width: 200, height: 40)
        view.addSubview(ipTextField)
        
        // Connect Button
        connectButton.frame = CGRect(x: 230, y: 100, width: 100, height: 40)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        view.addSubview(connectButton)

        // Send Logs Button (New Row)
        sendLogsButton.frame = CGRect(x: 20, y: 150, width: 220, height: 40)
        sendLogsButton.addTarget(self, action: #selector(sendLogsTapped), for: .touchUpInside)
        view.addSubview(sendLogsButton)

        // FPS Button
        fpsButton.frame = CGRect(x: 250, y: 150, width: 80, height: 40)
        fpsButton.addTarget(self, action: #selector(fpsTapped), for: .touchUpInside)
        view.addSubview(fpsButton)
        
        // Debug TextView (Shifted down)
        debugTextView.frame = CGRect(x: 20, y: 200, width: view.bounds.width - 40, height: view.bounds.height - 220)
        view.addSubview(debugTextView)
        
        updateConnectionUI()
    }
    
    private func updateConnectionUI() {
        statusLabel.text = "● " + connectionState.displayText
        statusLabel.textColor = connectionState.color
        
        switch connectionState {
        case .disconnected:
            connectButton.setTitle("Connect", for: .normal)
            connectButton.isEnabled = true
            sendLogsButton.isEnabled = true
            sendLogsButton.alpha = 1.0
        case .connecting, .reconnecting:
            connectButton.setTitle("Cancel", for: .normal)
            connectButton.isEnabled = true
            sendLogsButton.isEnabled = false
            sendLogsButton.alpha = 0.5
        case .connected:
            connectButton.setTitle("Disconnect", for: .normal)
            connectButton.isEnabled = true
            sendLogsButton.isEnabled = false
            sendLogsButton.alpha = 0.5
        }
    }
    
    @objc private func connectTapped() {
        switch connectionState {
        case .disconnected:
            // Start connection
            guard let ip = ipTextField.text, !ip.isEmpty else {
                log("IP is empty")
                return
            }
            serverIP = ip
            view.endEditing(true) // Dismiss keyboard
            connectToServer()
            
        case .connecting, .reconnecting:
            // Cancel connection attempt
            log("Connection cancelled by user")
            cancelConnection()
            
        case .connected:
            // Disconnect and disable auto-reconnect
            log("Disconnecting (auto-reconnect disabled)")
            autoReconnectEnabled = false
            disconnectFromServer()
        }
    }
    
    @objc private func sendLogsTapped() {
        guard let ip = ipTextField.text, !ip.isEmpty else {
            log("Enter IP Address first")
            return
        }
        
        log("Uploading logs to \(ip):5002...")
        
        DispatchQueue.global(qos: .background).async {
            self.uploadLogs(to: ip)
        }
    }
    
    private func uploadLogs(to ip: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let fileURL = dir.appendingPathComponent("console.log")
            
            guard let logData = try? Data(contentsOf: fileURL) else {
                self.log("No logs to send")
                return
            }
            
            // Simple TCP Connect & Send & Close
            let host = NWEndpoint.Host(ip)
            let port = NWEndpoint.Port(rawValue: 5002)!
            let connection = NWConnection(host: host, port: port, using: .tcp)
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send Data
                    connection.send(content: logData, completion: .contentProcessed({ error in
                        if let error = error {
                            self.log("Log upload failed: \(error)")
                        } else {
                            self.log("✅ Logs Uploaded Successfully!")
                            // Close after send
                            connection.cancel()
                            
                            // Delete local file to free space (Must be on logQueue)
                            self.logQueue.async {
                                do {
                                    try FileManager.default.removeItem(at: fileURL)
                                    self.log("Local log file cleared.")
                                } catch {
                                    self.log("Failed to clear logs: \(error)")
                                }
                            }
                        }
                    }))
                case .failed(let error):
                    self.log("Log Connection Failed: \(error)")
                default: break
                }
            }
            
            connection.start(queue: DispatchQueue(label: "LogUpload"))
        }
    }

    @objc private func fpsTapped() {
        if currentFPS == 30.0 {
            updateFrameRate(fps: 60.0)
        } else {
            updateFrameRate(fps: 30.0)
        }
    }

    private func updateFrameRate(fps: Double) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        
        do {
            try device.lockForConfiguration()
            
            // Find best format for desired FPS at 720p
            let targetDimensions = CMVideoDimensions(width: 1280, height: 720)
            var bestFormat: AVCaptureDevice.Format?
            
            for format in device.formats {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if dimensions.width == targetDimensions.width && dimensions.height == targetDimensions.height {
                    // Check if it supports the desired FPS
                    for range in format.videoSupportedFrameRateRanges {
                        if range.maxFrameRate >= fps && range.minFrameRate <= fps {
                            bestFormat = format
                            break
                        }
                    }
                }
                if bestFormat != nil { break }
            }
            
            if let format = bestFormat {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                
                currentFPS = fps
                DispatchQueue.main.async {
                    self.fpsButton.setTitle("\(Int(fps)) FPS", for: .normal)
                    self.fpsButton.backgroundColor = fps == 60.0 ? .systemGreen : .systemGray
                    self.log("Camera set to \(Int(fps)) FPS")
                }
            } else {
                log("Requested FPS \(fps) not supported for current resolution")
            }
            
            device.unlockForConfiguration()
        } catch {
            log("Failed to configure camera: \(error)")
        }
    }
    
    private func setupCamera() {
        log("Configuring Camera...")
        captureSession.sessionPreset = .iFrame1280x720
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            log("ERROR: Failed to get camera input")
            return
        }
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            log("Camera Input Added")
        }
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        // Force YUV420 Bi-Planar (NV12) for compatibility with our drawing code
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            log("Camera Output Added (YUV420)")
        }
        
        // Manual Display Layer Setup
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(displayLayer, at: 0)
    }
    
    private func setupEncoder() {
        videoEncoder = VideoEncoder(logger: self.log)
        videoEncoder?.delegate = self
        videoEncoder?.errorHandler = { [weak self] error in
            self?.log("⚠️ Encoder Error: \(error)")
            
            // CRITICAL FIX: Do NOT recreate encoder for simple latency warnings
            if error.contains("Latency") { return }
            
            self?.handleEncoderError()
        }
        log("Video Encoder Setup")
    }
    
    private func handleEncoderError() {
        // Recreate encoder on critical error
        log("Recreating encoder after error...")
        videoEncoder = VideoEncoder(logger: self.log)
        videoEncoder?.delegate = self
        videoEncoder?.errorHandler = { [weak self] error in
            self?.log("⚠️ Encoder Error: \(error)")
            
            // CRITICAL FIX: Do NOT recreate encoder for simple latency warnings
            if error.contains("Latency") { return }
            
            self?.handleEncoderError()
        }
        needsKeyFrame = true
    }
    
    private func startCapture() {
        DispatchQueue.global().async {
            self.captureSession.startRunning()
            DispatchQueue.main.async { self.log("Camera Session Running") }
        }
    }
    
    private func connectToServer() {
        connectionState = .connecting
        log("Connecting to \(serverIP)...")
        
        tcpClient = TCPClient(address: serverIP, port: serverPort)
        tcpClient?.logger = self.log
        tcpClient?.onConnected = { [weak self] in
            self?.handleConnected()
        }
        tcpClient?.onDisconnected = { [weak self] error in
            self?.handleDisconnected(error: error)
        }
        tcpClient?.connect()
    }
    
    private func handleConnected() {
        connectionState = .connected
        hasConnectedOnce = true
        autoReconnectEnabled = true // Enable auto-reconnect after first successful connection
        beaconListener?.setStreaming(true) // Update beacon state
        log("✓ Connected! Auto-reconnect enabled.")
        
        // Request keyframe after connection is stable
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.needsKeyFrame = true
            self.log("Requesting KeyFrame for stream sync")
        }
    }
    
    private func handleDisconnected(error: String?) {
        let wasConnected = connectionState == .connected
        connectionState = .disconnected
        
        if let error = error {
            log("⚠️ Disconnected: \(error)")
        } else {
            log("Disconnected")
        }
        
        // Reset stream state
        isDroppingFrames = true // Drop frames until we reconnect and get keyframe
        
        // Auto-reconnect if enabled and was previously connected
        if autoReconnectEnabled && wasConnected {
            scheduleReconnect()
        }
    }
    
    private func scheduleReconnect() {
        guard autoReconnectEnabled else { return }
        
        connectionState = .reconnecting
        log("Scheduling reconnect in \(Int(reconnectDelay))s...")
        
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            guard let self = self, self.autoReconnectEnabled else { return }
            self.log("Attempting reconnect...")
            self.connectToServer()
        }
    }
    
    private func cancelConnection() {
        autoReconnectEnabled = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        disconnectFromServer()
    }
    
    private func disconnectFromServer() {
        tcpClient?.disconnect()
        tcpClient = nil
        connectionState = .disconnected
        beaconListener?.setStreaming(false) // Reset beacon state
        isDroppingFrames = true
    }

    private func drawDebugPattern(on pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return }
        
        // Increase frame count
        frameCount += 1
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Visual Latency Test: Moving Zebra Square
        // Speed: 20 pixels per frame
        let boxSize = 100
        let speed = 20
        let xPos = (frameCount * speed) % (width - boxSize)
        let yPos = (height / 2) - (boxSize / 2) // Center vertically
        
        // Plane 0: Y (Luma)
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            
            for r in 0..<boxSize {
                let rowIdx = yPos + r
                if rowIdx >= height { break }
                
                let rowPtr = yBase.advanced(by: rowIdx * yStride).assumingMemoryBound(to: UInt8.self)
                
                // Draw Zebra Stripes (Black/White every 10 pixels)
                let isWhiteStripe = (r / 10) % 2 == 0
                let color: UInt8 = isWhiteStripe ? 255 : 0
                
                memset(rowPtr + xPos, Int32(color), boxSize)
            }
        }
        
        // Plane 1: UV (Chroma) - Set to Neural Gray (128)
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            
            for r in 0..<(boxSize/2) {
                let rowIdx = (yPos / 2) + r
                if rowIdx >= (height/2) { break }
                
                let rowPtr = uvBase.advanced(by: rowIdx * uvStride).assumingMemoryBound(to: UInt8.self)
                let uvXStart = (xPos / 2) * 2 
                
                // Write Neutral Chroma (128) for the length of the box
                for c in 0..<(boxSize/2) {
                    let ptrIdx = uvXStart + (c * 2)
                    rowPtr[ptrIdx] = 128     // U
                    rowPtr[ptrIdx + 1] = 128 // V
                }
            }
        }
    }
}

extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Only process frames if connected
        guard connectionState == .connected else { return }
        
        // Draw Debug Pattern
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            drawDebugPattern(on: pixelBuffer)
        }
        
        // Display Modified Frame on iPhone
        displayLayer.enqueue(sampleBuffer)

        // Encode Frame
        let force = needsKeyFrame
        if force { needsKeyFrame = false }
        videoEncoder?.encode(sampleBuffer, forceKeyframe: force)
    }
}

extension CameraViewController: VideoEncoderDelegate {
    func didEncode(nalData: Data, isKeyFrame: Bool, captureTime: TimeInterval) {
        // 1. Recovery Logic: If we are in "Drop Mode", we ignore everything until we see a KeyFrame
        if isDroppingFrames {
            if isKeyFrame {
                log("Recovered! Resuming stream at KeyFrame.")
                isDroppingFrames = false
            } else {
                // Drop this P-frame silently to save bandwidth and prevent artifacts
                return
            }
        }
    
        // 2. Try to Send
        let sent = tcpClient?.send(data: nalData, captureTime: captureTime) ?? false
        
        // 3. Handle Send Failure
        if !sent {
            // Buffer full or network error
            if !isDroppingFrames {
                log("⚠️ Packet Dropped! entering Recovery Mode.")
                isDroppingFrames = true
                
                // Immediately request a new KeyFrame to recover ASAP
                self.needsKeyFrame = true 
            }
        }
    }
}

// MARK: - Video Encoder
protocol VideoEncoderDelegate: AnyObject {
    func didEncode(nalData: Data, isKeyFrame: Bool, captureTime: TimeInterval)
}

class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?
    var errorHandler: ((String) -> Void)?
    private var session: VTCompressionSession?
    
    init(logger: ((String) -> Void)? = nil) {
        self.errorHandler = logger
        createSession()
    }
    
    private func createSession() {
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: 1280,
            height: 720,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            errorHandler?("Failed to create encoder: \(status)")
            return
        }
        
        // Set Properties for Low Latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber) // 1 second
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_500_000 as CFNumber) 
        
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    
    func encode(_ sampleBuffer: CMSampleBuffer, forceKeyframe: Bool = false) {
        guard let session = session,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        var properties: [String: Any]?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue!]
        }
        
        // Create timestamp for latency measurement
        let now = CFAbsoluteTimeGetCurrent()
        let refCon = UnsafeMutablePointer<CFAbsoluteTime>.allocate(capacity: 1)
        refCon.initialize(to: now)
        
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: imageBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties as CFDictionary?, sourceFrameRefcon: refCon, infoFlagsOut: nil)
        
        if status != noErr {
            errorHandler?("Encode frame failed: \(status)")
        }
    }
    
    func sendSPSandPPS(from sampleBuffer: CMSampleBuffer, captureTime: TimeInterval) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        
        var parameterSetCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        
        for i in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size: Int = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            
            if let pointer = pointer {
                let data = Data(bytes: pointer, count: size)
                // SPS/PPS are considered KeyFrame data
                delegate?.didEncode(nalData: data, isKeyFrame: true, captureTime: captureTime)
            }
        }
    }
    
    func sendNALUs(from sampleBuffer: CMSampleBuffer, isKeyFrame: Bool, captureTime: TimeInterval) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        var bufferOffset = 0
        let avccHeaderLength = 4
        
        while bufferOffset < length - avccHeaderLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, dataPointer! + bufferOffset, 4)
            naluLength = CFSwapInt32BigToHost(naluLength)
            
            let data = Data(bytes: dataPointer! + bufferOffset + 4, count: Int(naluLength))
            delegate?.didEncode(nalData: data, isKeyFrame: isKeyFrame, captureTime: captureTime)
            
            bufferOffset += 4 + Int(naluLength)
        }
    }
}

// C-style Callback function must be outside class or static
private func compressionCallback(outputCallbackRefCon: UnsafeMutableRawPointer?, sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    
    var captureTime: TimeInterval = 0
    
    // Verify sourceFrameRefCon exists
    if let sourceRefCon = sourceFrameRefCon {
        let startTime = sourceRefCon.assumingMemoryBound(to: CFAbsoluteTime.self).pointee
        captureTime = startTime
        
        let now = CFAbsoluteTimeGetCurrent()
        let latency = (now - startTime) * 1000.0
        
        encoder.errorHandler?("[Encoder] Latency: \(String(format: "%.1f", latency))ms")

        sourceRefCon.deallocate()
    }

    // Handle encoder errors
    if status != noErr {
        encoder.errorHandler?("Compression callback error: \(status)")
        return
    }
    
    guard let sampleBuffer = sampleBuffer else { return }
    
    // Check KeyFrame
    var isKeyFrame = false
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
        let rawDict = CFArrayGetValueAtIndex(attachments, 0)
        let dict = unsafeBitCast(rawDict, to: CFDictionary.self)
        let notSync = CFDictionaryContainsKey(dict, unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self))
        isKeyFrame = !notSync
    }
    
    if isKeyFrame {
        encoder.sendSPSandPPS(from: sampleBuffer, captureTime: captureTime)
    }
    
    encoder.sendNALUs(from: sampleBuffer, isKeyFrame: isKeyFrame, captureTime: captureTime)
}

// MARK: - TCP Client with StreamDelegate
// MARK: - TCP Client with NWConnection (Low Latency)
class TCPClient {
    let address: String
    let port: UInt32
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.antigravity.tcp")
    
    // Backpressure
    private var pendingPackets = 0
    private let maxPendingPackets = 5 // Low buffer for real-time
    
    var logger: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    
    init(address: String, port: UInt32) {
        self.address = address
        self.port = port
    }
    
    func connect() {
        let host = NWEndpoint.Host(address)
        let port = NWEndpoint.Port(rawValue: UInt16(self.port))!
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Vital for Low Latency
        tcpOptions.enableKeepalive = true
        
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        
        connection = NWConnection(host: host, port: port, using: params)
        
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger?("Connected to \(self?.address ?? ""):\(self?.port ?? 0)")
                self?.onConnected?()
            case .failed(let error):
                self?.logger?("Connection failed: \(error)")
                self?.onDisconnected?(error.localizedDescription)
            case .cancelled:
                self?.logger?("Connection cancelled")
                self?.onDisconnected?(nil)
            case .waiting(let error):
                self?.logger?("Connection waiting: \(error)")
            default:
                break
            }
        }
        
        connection?.start(queue: queue)
        logger?("Connecting to \(address):\(port)...")
    }
    
    func disconnect() {
        connection?.cancel()
        connection = nil
        pendingPackets = 0
    }
    
    func send(data: Data, captureTime: TimeInterval) -> Bool {
        guard let connection = connection, connection.state == .ready else { return false }
        
        // 1. Backpressure Check
        if pendingPackets > maxPendingPackets {
             return false
        }
        
        // 2. Coalesce Header (Length + Timestamp) + Body
        // Header Structure: [Length (4 bytes)][Timestamp (8 bytes)]
        
        let packetBodySize = UInt32(data.count + 8) // +8 for timestamp
        var header = packetBodySize.bigEndian
        var packetData = Data(bytes: &header, count: 4)
        
        // Convert TimeInterval (Double) to UInt64 microseconds for transmission
        // Using since 1970 to match Windows std::time if needed, but relative time is fine for delta
        // Let's use CFAbsoluteTime (seconds since 2001) as base, convertible to system clock
        // Actually, best to just send the bits of the Double or use a fixed point.
        // Let's use microseconds (UInt64) relative to UNKNOWN epoch, just for delta measurement?
        // No, we need wall-clock sync.
        // Let's stick to simple: Send Double (8 bytes) directly, trusting endianness (ARM64/x64 both Little Endian)
        // OR better: Send microsecond timestamp (UInt64) to be safe.
        
        // Using UInt64 microseconds
        let timestampMicros = UInt64(captureTime * 1_000_000)
        var tsBigEndian = timestampMicros.bigEndian
        packetData.append(Data(bytes: &tsBigEndian, count: 8))
        
        packetData.append(data)
        
        // 3. Send
        pendingPackets += 1
        connection.send(content: packetData, completion: .contentProcessed({ [weak self] error in
            self?.queue.async {
                self?.pendingPackets -= 1
            }
            if let error = error {
                self?.logger?("Send error: \(error)")
            }
        }))
        
        return true
    }
}

// MARK: - Active Discovery Listener
class BeaconListener {
    var port: UInt16
    var deviceName: String
    var isStreaming: Bool = false
    
    // Magic: "AGCM"
    private let magic: [UInt8] = [0x41, 0x47, 0x43, 0x4D]
    
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.antigravity.beacon")
    
    var onLog: ((String) -> Void)?
    
    init(port: UInt16, deviceName: String) {
        self.port = port
        self.deviceName = deviceName
    }
    
    func start() {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }
            
            listener?.start(queue: queue)
            onLog?("Beacon Listener Started on 5001")
        } catch {
            onLog?("Failed to start listener: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        // Cancel all connections
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
    }
    
    func setStreaming(_ streaming: Bool) {
        isStreaming = streaming
    }
    
    private func handleConnection(_ connection: NWConnection) {
        // Retain connection
        connections.append(connection)
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled:
                self?.connections.removeAll { $0 === connection }
            case .failed(let error):
                self?.connections.removeAll { $0 === connection }
                self?.onLog?("Connection failed: \(error)")
            default: break
            }
        }
        
        connection.start(queue: queue)
        receiveLoop(connection)
    }
    
    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = content {
                self.processPacket(data, connection: connection)
                // Stateless: connection.cancel() is now handled inside processPacket -> sendPong
                return 
            }
            
            if error == nil {
                // Continue listening (only if no data received yet)
                self.receiveLoop(connection)
            } else {
                self.onLog?("Receive error: \(String(describing: error))")
            }
        }
    }
    
    private func processPacket(_ data: Data, connection: NWConnection) {
        // Validate PING: Magic(4) + Type(1)=0x01 + Ver(1)
        guard data.count >= 6 else { 
            connection.cancel() // Close if junk
            return 
        }
        
        if data[0] == 0x41 && data[1] == 0x47 && data[2] == 0x43 && data[3] == 0x4D {
            if data[4] == 0x01 { // PING
                onLog?("PING Received (\(data.count)b) -> Responding")
                sendPong(connection: connection) {
                    connection.cancel() // Close ONLY after send completes
                }
                return
            } else if data[4] == 0x03 { // SYNC_REQUEST
                handleSyncRequest(data, connection: connection)
                return
            }
        }
        
        connection.cancel() // Close if not PING/SYNC
    }
    
    private func handleSyncRequest(_ data: Data, connection: NWConnection) {
         // T2: Receive Timestamp
         let t2 = Int64(Date().timeIntervalSince1970 * 1_000_000)
         
         // Extract T1 (starts at index 5, 8 bytes)
         guard data.count >= 13 else { connection.cancel(); return }
         let t1Data = data.subdata(in: 5..<13)
         
         // Prepare Reply
         // Format: Magic(4) + Type(1)=0x04 + T1(8) + T2(8) + T3(8)
         var packet = Data(magic)
         packet.append(0x04) // SYNC_REPLY
         packet.append(t1Data) // Echo T1
         
         // T2
         withUnsafeBytes(of: t2) { packet.append(contentsOf: $0) }
         
         // T3: Send Timestamp
         let t3 = Int64(Date().timeIntervalSince1970 * 1_000_000)
         withUnsafeBytes(of: t3) { packet.append(contentsOf: $0) }
         
         connection.send(content: packet, completion: .contentProcessed({ [weak self] error in
             if let error = error {
                 self?.onLog?("Failed to send SYNC_REPLY: \(error)")
             }
             connection.cancel()
         }))
    }
    
    private func sendPong(connection: NWConnection, completion: @escaping () -> Void) {
        var packet = Data()
        // Magic
        packet.append(contentsOf: magic)
        // Type (2 = PONG)
        packet.append(0x02)
        // Version (1)
        packet.append(1)
        // State
        packet.append(isStreaming ? 1 : 0)
        // Name
        var nameBytes = Array(deviceName.utf8.prefix(32))
        while nameBytes.count < 32 { nameBytes.append(0) }
        packet.append(contentsOf: nameBytes)
        
        connection.send(content: packet, completion: .contentProcessed({ [weak self] error in
             if let error = error {
                 self?.onLog?("Failed to send PONG: \(error)")
             }
             completion() // Done
        }))
    }
    }

