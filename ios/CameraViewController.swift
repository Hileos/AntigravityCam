import UIKit
import Foundation
import AVFoundation
import VideoToolbox

class CameraViewController: UIViewController {
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var tcpClient: TCPClient?
    private var videoEncoder: VideoEncoder?
    private var needsKeyFrame = false
    private var isDroppingFrames = false // Recovery State
    private var frameCount: Int = 0 
    
    // Config
    private var serverIP = "192.168.1.2" 
    private let serverPort: UInt32 = 5000
    
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
    }
    
    // Custom Logger
    func log(_ msg: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.debugTextView.text = "[\(timestamp)] \(msg)\n" + self.debugTextView.text
            // Keep only last 20 lines
            // if self.debugTextView.text.components(separatedBy: "\n").count > 20 { ... } 
        }
        print(msg)
    }
    
    private func setupUI() {
        view.backgroundColor = .black
        
        // Simple Label
        let label = UILabel()
        label.text = "Antigravity Cam"
        label.textColor = .white
        label.frame = CGRect(x: 20, y: 50, width: 300, height: 40)
        view.addSubview(label)
        
        // IP Text Field
        ipTextField.frame = CGRect(x: 20, y: 100, width: 200, height: 40)
        view.addSubview(ipTextField)
        
        // Connect Button
        let btn = UIButton(type: .system)
        btn.setTitle("Connect", for: .normal)
        btn.frame = CGRect(x: 230, y: 100, width: 100, height: 40)
        btn.backgroundColor = .white
        btn.layer.cornerRadius = 5
        btn.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        view.addSubview(btn)
        
        // Debug TextView
        debugTextView.frame = CGRect(x: 20, y: 150, width: view.bounds.width - 40, height: 200)
        view.addSubview(debugTextView)
    }
    
    @objc private func connectTapped() {
        guard let ip = ipTextField.text, !ip.isEmpty else {
            log("IP is empty")
            return
        }
        serverIP = ip
        log("Connecting to \(serverIP)...")
        view.endEditing(true) // Dismiss keyboard
        connectToServer()
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
        log("Video Encoder Setup")
    }
    
    private func startCapture() {
        DispatchQueue.global().async {
            self.captureSession.startRunning()
            DispatchQueue.main.async { self.log("Camera Session Running") }
        }
    }
    
    private func connectToServer() {
        tcpClient = TCPClient(address: serverIP, port: serverPort)
        tcpClient?.logger = self.log
        tcpClient?.connect()
        
        self.log("Connecting...")
        
        // Delay keyframe request to ensure TCP socket is ready
        // The encoder callback will send SPS/PPS when the keyframe is encoded
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
             self.needsKeyFrame = true
             self.log("Socket ready. Requesting KeyFrame (SPS/PPS will be sent with it).")
        }
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
    private var session: VTCompressionSession?
    
    init() {
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
            print("Failed to create encoder: \(status)")
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
        
        VTCompressionSessionEncodeFrame(session, imageBuffer: imageBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties as CFDictionary?, sourceFrameRefcon: nil, infoFlagsOut: nil)
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
    guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    
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

// MARK: - TCP Client
class TCPClient {
    let address: String
    let port: UInt32
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    var logger: ((String) -> Void)?
    
    init(address: String, port: UInt32) {
        self.address = address
        self.port = port
    }
    
    func connect() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, address as CFString, port, &readStream, &writeStream)
        
        inputStream = readStream?.takeRetainedValue()
        outputStream = writeStream?.takeRetainedValue()
        
        inputStream?.schedule(in: .current, forMode: .common)
        outputStream?.schedule(in: .current, forMode: .common)
        
        inputStream?.open()
        outputStream?.open()
        
        logger?("TCP connecting to \(address):\(port)")
    }
    
    func send(data: Data) -> Bool {
        guard let outputStream = outputStream else { return false }
        
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
