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
    
    // ... [UI Elements omitted for brevity in replace tool, but will be preserved] ...

    // ... [viewDidLoad, log, setupUI, connectTapped, setupCamera, setupEncoder, startCapture, connectToServer omitted] ...

// ... [extension CVPixelBuffer helper omitted] ...

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
