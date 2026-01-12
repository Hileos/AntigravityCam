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
    
    // Config
    private var serverIP = "192.168.1.100" 
    private let serverPort: UInt32 = 5000
    
    // UI Elements
    private let ipTextField: UITextField = {
        let tf = UITextField()
        tf.placeholder = "Enter PC IP (e.g. 192.168.1.100)"
        tf.borderStyle = .roundedRect
        tf.backgroundColor = .white
        tf.textColor = .black
        tf.text = "192.168.1.100" // Default
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
        
        // Request KeyFrame on next frame
        self.needsKeyFrame = true
        self.log("KeyFrame requested for next frame")
    }
}

extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let force = needsKeyFrame
        if force { needsKeyFrame = false }
        videoEncoder?.encode(sampleBuffer, forceKeyframe: force)
    }
}

extension CameraViewController: VideoEncoderDelegate {
    func didEncode(nalData: Data) {
        tcpClient?.send(data: nalData)
    }
}

// MARK: - Video Encoder
protocol VideoEncoderDelegate: AnyObject {
    func didEncode(nalData: Data)
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber) // 2 seconds
        // Bitrate: 3 Mbps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 3_000_000 as CFNumber) 
        
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
}

// C-style Callback function
private func compressionCallback(outputCallbackRefCon: UnsafeMutableRawPointer?, sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
    guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    
    // Extract NALUs
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
        let rawDict = CFArrayGetValueAtIndex(attachments, 0)
        let dict = unsafeBitCast(rawDict, to: CFDictionary.self)
        let isKeyFrame = CFDictionaryContainsKey(dict, unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self)) == false
        
        if isKeyFrame {
            print("Sending SPS/PPS (KeyFrame)")
            encoder.sendSPSandPPS(from: sampleBuffer)
        }
    }
    
    encoder.sendNALUs(from: sampleBuffer)
}

extension VideoEncoder {
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
                delegate?.didEncode(nalData: data)
            }
        }
    }
    
    func sendNALUs(from sampleBuffer: CMSampleBuffer) {
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
            delegate?.didEncode(nalData: data)
            
            bufferOffset += 4 + Int(naluLength)
        }
    }
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
    
    func send(data: Data) {
        guard let outputStream = outputStream else { return }
        
        if !outputStream.hasSpaceAvailable {
             // logger?("Socket busy/full") // Too spammy
             return 
        }
        
        // logger?("Sending \(data.count) bytes...") // Very spammy
        
        // Send Length (4 bytes Big Endian)
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        
        // Write Length
        let lBytes = lengthData.withUnsafeBytes { outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: 4) }
        if lBytes < 0 { logger?("Error writing length") }
        
        // Write Data
        let dBytes = data.withUnsafeBytes { outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count) }
         if dBytes < 0 { logger?("Error writing data") }
    }
}
