import UIKit
import Foundation
import AVFoundation
import VideoToolbox
import Network

// MARK: - Connection State Enum
// Build Trigger: Active Discovery Final
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
    
    // UDP Beacon for device discovery
    private var beaconListener: BeaconListener?
    
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
        beaconListener?.start()
        log("UDP Listener started on port \(beaconPort)")
    }
    
    // Custom Logger
    func log(_ msg: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.debugTextView.text = "[\(timestamp)] \(msg)\n" + self.debugTextView.text
            // Keep only last 50 lines
            let lines = self.debugTextView.text.components(separatedBy: "\n")
            if lines.count > 50 {
                self.debugTextView.text = lines.prefix(50).joined(separator: "\n")
            }
        }
        print(msg)
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
        
        // Debug TextView
        debugTextView.frame = CGRect(x: 20, y: 150, width: view.bounds.width - 40, height: 200)
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
        case .connecting, .reconnecting:
            connectButton.setTitle("Cancel", for: .normal)
            connectButton.isEnabled = true
        case .connected:
            connectButton.setTitle("Disconnect", for: .normal)
            connectButton.isEnabled = true
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
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            log("Camera Output Added")
        }
        
        // Add Preview Layer
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)
    }
    
    private func setupEncoder() {
        videoEncoder = VideoEncoder()
        videoEncoder?.delegate = self
        videoEncoder?.errorHandler = { [weak self] error in
            self?.log("⚠️ Encoder Error: \(error)")
            self?.handleEncoderError()
        }
        log("Video Encoder Setup")
    }
    
    private func handleEncoderError() {
        // Recreate encoder on critical error
        log("Recreating encoder after error...")
        videoEncoder = VideoEncoder()
        videoEncoder?.delegate = self
        videoEncoder?.errorHandler = { [weak self] error in
            self?.log("⚠️ Encoder Error: \(error)")
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
        
        // Cycle colors: Red, Green, Blue every 30 frames
        let cycle = (frameCount / 30) % 3
        frameCount += 1
        
        // Approximate YUV values (BT.601)
        // Red:   Y=82,  U=90,  V=240
        // Green: Y=145, U=54,  V=34
        // Blue:  Y=41,  U=240, V=110
        
        var yVal: UInt8 = 0
        var uVal: UInt8 = 0
        var vVal: UInt8 = 0
        
        switch cycle {
        case 0: // Red
            yVal = 82; uVal = 90; vVal = 240
        case 1: // Green
            yVal = 145; uVal = 54; vVal = 34
        case 2: // Blue
            yVal = 41; uVal = 240; vVal = 110
        default: break
        }
        
        let width = 64
        let height = 64
        
        // Plane 0: Y
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for r in 0..<height {
                let rowPtr = yBase.advanced(by: r * yStride).assumingMemoryBound(to: UInt8.self)
                // Fill row
                memset(rowPtr, Int32(yVal), width)
            }
        }
        
        // Plane 1: UV (interleaved)
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            // UV is subsampled vertically by 2
            for r in 0..<(height/2) {
                let rowPtr = uvBase.advanced(by: r * uvStride).assumingMemoryBound(to: UInt8.self)
                // Write U, V, U, V...
                for c in 0..<(width/2) {
                    rowPtr[c*2] = uVal
                    rowPtr[c*2+1] = vVal
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

        // Encode Frame
        let force = needsKeyFrame
        if force { needsKeyFrame = false }
        videoEncoder?.encode(sampleBuffer, forceKeyframe: force)
    }
}

extension CameraViewController: VideoEncoderDelegate {
    func didEncode(nalData: Data, isKeyFrame: Bool) {
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
        let sent = tcpClient?.send(data: nalData) ?? false
        
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
    func didEncode(nalData: Data, isKeyFrame: Bool)
}

class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?
    var errorHandler: ((String) -> Void)?
    private var session: VTCompressionSession?
    
    init() {
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
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue]
        }
        
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: imageBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties as CFDictionary?, sourceFrameRefcon: nil, infoFlagsOut: nil)
        
        if status != noErr {
            errorHandler?("Encode frame failed: \(status)")
        }
    }
    
    func sendSPSandPPS(from sampleBuffer: CMSampleBuffer) {
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
                delegate?.didEncode(nalData: data, isKeyFrame: true)
            }
        }
    }
    
    func sendNALUs(from sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
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
            delegate?.didEncode(nalData: data, isKeyFrame: isKeyFrame)
            
            bufferOffset += 4 + Int(naluLength)
        }
    }
}

// C-style Callback function must be outside class or static
private func compressionCallback(outputCallbackRefCon: UnsafeMutableRawPointer?, sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    
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
        // print("Sending SPS/PPS (KeyFrame)")
        encoder.sendSPSandPPS(from: sampleBuffer)
    }
    
    encoder.sendNALUs(from: sampleBuffer, isKeyFrame: isKeyFrame)
}

// MARK: - TCP Client with StreamDelegate
class TCPClient: NSObject, StreamDelegate {
    let address: String
    let port: UInt32
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var isConnected = false
    
    var logger: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    
    init(address: String, port: UInt32) {
        self.address = address
        self.port = port
        super.init()
    }
    
    func connect() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, address as CFString, port, &readStream, &writeStream)
        
        inputStream = readStream?.takeRetainedValue()
        outputStream = writeStream?.takeRetainedValue()
        
        guard let input = inputStream, let output = outputStream else {
            logger?("Failed to create streams")
            onDisconnected?("Failed to create streams")
            return
        }
        
        // Set delegate to handle stream events
        input.delegate = self
        output.delegate = self
        
        // Schedule on main run loop for event handling
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        
        input.open()
        output.open()
        
        logger?("TCP connecting to \(address):\(port)")
    }
    
    func disconnect() {
        isConnected = false
        
        inputStream?.delegate = nil
        outputStream?.delegate = nil
        
        inputStream?.close()
        outputStream?.close()
        
        inputStream?.remove(from: .main, forMode: .common)
        outputStream?.remove(from: .main, forMode: .common)
        
        inputStream = nil
        outputStream = nil
    }
    
    // MARK: - StreamDelegate
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream == outputStream && !isConnected {
                isConnected = true
                logger?("Stream opened successfully")
                onConnected?()
            }
            
        case .errorOccurred:
            let error = aStream.streamError?.localizedDescription ?? "Unknown error"
            logger?("Stream error: \(error)")
            if isConnected {
                disconnect()
                onDisconnected?(error)
            } else {
                onDisconnected?("Connection failed: \(error)")
            }
            
        case .endEncountered:
            logger?("Stream ended")
            if isConnected {
                disconnect()
                onDisconnected?("Connection closed by server")
            }
            
        case .hasBytesAvailable:
            // We don't expect incoming data, but drain it to prevent buffer issues
            if aStream == inputStream {
                var buffer = [UInt8](repeating: 0, count: 1024)
                inputStream?.read(&buffer, maxLength: buffer.count)
            }
            
        case .hasSpaceAvailable:
            // Output stream has space - could be used for flow control
            break
            
        default:
            break
        }
    }
    
    func send(data: Data) -> Bool {
        guard let outputStream = outputStream, isConnected else { return false }
        
        // 1. Pre-check space (optimization)
        if !outputStream.hasSpaceAvailable {
             return false
        }
        
        // 2. Coalesce Header + Body into one buffer to minimize syscalls and lower fragmentation risk
        let packetSize = data.count
        let totalSize = 4 + packetSize
        var packetData = Data(count: totalSize)
        
        // Write Length Header (Big Endian)
        var lengthBE = UInt32(packetSize).bigEndian
        withUnsafeBytes(of: &lengthBE) { packetData.replaceSubrange(0..<4, with: $0) }
        
        // Write Body
        packetData.replaceSubrange(4..<totalSize, with: data)
        
        // 3. Write Loop - Ensure EVERY byte is sent
        var bytesWritten = 0
        while bytesWritten < totalSize {
            let result = packetData.withUnsafeBytes { ptr -> Int in
                let remaining = totalSize - bytesWritten
                // Advanced pointer arithmetic
                let startAddress = ptr.baseAddress!.advanced(by: bytesWritten).assumingMemoryBound(to: UInt8.self)
                return outputStream.write(startAddress, maxLength: remaining)
            }
            
            if result < 0 {
                logger?("TCP Write Error")
                // Notify disconnection on write error
                DispatchQueue.main.async {
                    self.disconnect()
                    self.onDisconnected?("Write error")
                }
                return false
            }
            if result == 0 {
                // Stream full? If we are in middle of packet, we MUST block/retry or else stream corrupts.
                // But typically 0 means closed.
                return false
            }
            bytesWritten += result
        }
        
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
            
            listener?.start(queue: .global())
            // print("BeaconListener started")
        } catch {
            print("Failed to start listener: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
    
    func setStreaming(_ streaming: Bool) {
        isStreaming = streaming
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        receiveLoop(connection)
    }
    
    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = content {
                self.processPacket(data, connection: connection)
            }
            
            if error == nil {
                // Continue listening for next packet
                self.receiveLoop(connection)
            } else {
                print("Beacon receive error: \(String(describing: error))")
            }
        }
    }
    
    private func processPacket(_ data: Data, connection: NWConnection) {
        // Validate PING: Magic(4) + Type(1)=0x01 + Ver(1)
        guard data.count >= 6 else { return }
        
        if data[0] == 0x41 && data[1] == 0x47 && data[2] == 0x43 && data[3] == 0x4D &&
           data[4] == 0x01 { // PING
            
            sendPong(connection: connection)
        }
    }
    
    private func sendPong(connection: NWConnection) {
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
        
        connection.send(content: packet, completion: .contentProcessed({ error in
             // Sent
        }))
    }
}
