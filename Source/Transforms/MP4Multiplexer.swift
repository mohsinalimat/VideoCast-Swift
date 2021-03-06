//
//  MP4Multiplexer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/02/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import AVFoundation

public typealias MP4SessionParameters = MetaData<(filename: String, fps: Int, width: Int, height: Int, videoCodecType: CMVideoCodecType)>

open class MP4Multiplexer: IOutputSession {
    private let writingQueue: DispatchQueue = .init(label: "com.videocast.mp4multiplexer")
    
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    
    private var vps: [UInt8] = .init()
    private var sps: [UInt8] = .init()
    private var pps: [UInt8] = .init()
    
    private let epoch: Date = .init()
    
    private var filename: String = ""
    private var fps: Int = 30
    private var width: Int = 0
    private var height: Int = 0
    private var videoCodecType: CMVideoCodecType = kCMVideoCodecType_H264
    private let framecount: Int = 0
    
    private var startedSession: Bool = false
    private var firstVideoBuffer: Bool = true
    private var firstAudioBuffer: Bool = true
    private var firstVideoFrameTime: CMTime? = nil
    private var lastVideoFrameTime: CMTime? = nil
    
    private var started: Bool = false
    private var exiting: Atomic<Bool> = .init(false)
    private var thread: Thread? = nil
    private let cond: NSCondition = .init()
    
    struct SampleInput {
        var buffer: CMBlockBuffer
        var timingInfo: CMSampleTimingInfo
        var size: Int
    }

    private var videoSamples: [SampleInput] = .init()
    private var audioSamples: [SampleInput] = .init()
    
    private var stopCallback: StopSessionCallback?
    
    public init() {
        
    }
    
    deinit {
        if startedSession {
            stop {}
        }
        
        audioFormat = nil
        videoFormat = nil
        assetWriter = nil
    }
    
    open func stop(_ callback: @escaping StopSessionCallback) {
        startedSession = false
        exiting.value = true
        cond.broadcast()

        stopCallback = callback
    }
    
    open func setSessionParameters(_ parameters: IMetaData) {
        guard let params = parameters as? MP4SessionParameters, let data = params.data else {
            Logger.debug("unexpected return")
            return
        }
        
        filename = data.filename
        fps = data.fps
        width = data.width
        height = data.height
        videoCodecType = data.videoCodecType
        Logger.info("(\(fps), \(width), \(height), \(videoCodecType)")
        
        if !started {
            started = true
            thread = Thread(block: writingThread)
            thread?.start()
        }
    }
    
    open func setBandwidthCallback(_ callback: @escaping BandwidthCallback) {
        
    }
    
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        if let videMetadata = metadata as? VideoBufferMetadata {
            self.pushVideoBuffer(data, size: size, metadata: videMetadata)
        } else if let sounMetadata = metadata as? AudioBufferMetadata {
            self.pushAudioBuffer(data, size: size, metadata: sounMetadata)
        }
    }
    
    private func pushVideoBuffer(_ data: UnsafeRawPointer, size: Int, metadata: VideoBufferMetadata) {
        let data = data.assumingMemoryBound(to: UInt8.self)
        let isVLC: Bool
        var nalType: NalType = .unknown
        
        let nal_type: UInt8
        switch videoCodecType {
        case kCMVideoCodecType_H264:
            nal_type = data[4] & 0x1F
            isVLC = nal_type <= 5
            switch nal_type {
            case 7:
                nalType = .sps
            case 8:
                nalType = .pps
            default:
                break
            }
        case kCMVideoCodecType_HEVC:
            nal_type = (data[4] & 0x7E) >> 1
            isVLC = nal_type <= 31
            switch nal_type {
            case 32:
                nalType = .vps
            case 33:
                nalType = .sps
            case 34:
                nalType = .pps
            default:
                break
            }
        default:
            Logger.error("unsupported codec type: \(videoCodecType)")
            return
        }
        
        firstVideoBuffer = false
        
        if !isVLC {
            switch nalType {
            case .vps:
                if vps.isEmpty {
                    let buf = UnsafeBufferPointer<UInt8>(start: data.advanced(by: 4), count: size-4)
                    vps.append(contentsOf: buf)
                }
            case .sps:
                if sps.isEmpty {
                    let buf = UnsafeBufferPointer<UInt8>(start: data.advanced(by: 4), count: size-4)
                    sps.append(contentsOf: buf)
                }
            case .pps:
                if pps.isEmpty {
                    let buf = UnsafeBufferPointer<UInt8>(start: data.advanced(by: 4), count: size-4)
                    pps.append(contentsOf: buf)
                }
            default:
                break
            }
            if videoInput == nil {
                createAVCC()
            }
        } else {
            var bufferOut: CMBlockBuffer?
            let memoryBlock = UnsafeMutableRawPointer.allocate(bytes: size, alignedTo: MemoryLayout<UInt8>.alignment)
            memoryBlock.initializeMemory(as: UInt8.self, from: data, count: size)
            CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, memoryBlock, size, kCFAllocatorDefault, nil, 0, size, kCMBlockBufferAssureMemoryNowFlag, &bufferOut)
            guard let buffer = bufferOut else {
                Logger.debug("unexpected return")
                return
            }
            
            var timingInfo: CMSampleTimingInfo = .init()
            timingInfo.presentationTimeStamp = metadata.pts
            timingInfo.decodeTimeStamp = metadata.dts.isNumeric ? metadata.dts : metadata.pts
            
            guard let assetWriter = assetWriter else { return }
            if assetWriter.status == .unknown {
                if assetWriter.startWriting() {
                    assetWriter.startSession(atSourceTime: timingInfo.decodeTimeStamp)
                    Logger.debug("startSession: \(timingInfo.decodeTimeStamp)")
                    startedSession = true
                } else {
                    Logger.error("could not start writing video: \(String(describing: assetWriter.error))")
                }
            }
            
            if nil == firstVideoFrameTime {
                firstVideoFrameTime = timingInfo.decodeTimeStamp
            }
            lastVideoFrameTime = timingInfo.presentationTimeStamp
            
            writingQueue.async { [weak self] in
                guard let strongSelf = self, !strongSelf.exiting.value else { return }
                
                strongSelf.videoSamples.insert(.init(buffer: buffer, timingInfo: timingInfo, size: size), at: 0)
                strongSelf.cond.signal()
            }
        }
    }
    
    private func pushAudioBuffer(_ data: UnsafeRawPointer, size: Int, metadata: AudioBufferMetadata) {
        guard let assetWriter = assetWriter else { return }

        let data = data.assumingMemoryBound(to: UInt8.self)
        
        if let _ = audioFormat {
            guard let firstVideoFrameTime = firstVideoFrameTime,
                firstVideoFrameTime < metadata.pts else {
                return
            }
            var bufferOut: CMBlockBuffer?
            let memoryBlock = UnsafeMutableRawPointer.allocate(bytes: size, alignedTo: MemoryLayout<UInt8>.alignment)
            memoryBlock.initializeMemory(as: UInt8.self, from: data, count: size)
            CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, memoryBlock, size, kCFAllocatorDefault, nil, 0, size, kCMBlockBufferAssureMemoryNowFlag, &bufferOut)
            guard let buffer = bufferOut else {
                Logger.debug("unexpected return")
                return
            }
            
            var timingInfo: CMSampleTimingInfo = .init()
            timingInfo.presentationTimeStamp = metadata.pts
            timingInfo.decodeTimeStamp = metadata.dts.isNumeric ? metadata.dts : metadata.pts
            
            writingQueue.async { [weak self] in
                guard let strongSelf = self, !strongSelf.exiting.value else { return }
                
                strongSelf.audioSamples.insert(.init(buffer: buffer, timingInfo: timingInfo, size: size), at: 0)
                strongSelf.cond.signal()
            }
        } else {
            let md = metadata
            guard let metaData = md.data else {
                Logger.debug("unexpected return")
                return
            }
            
            var asbd: AudioStreamBasicDescription = .init()
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFormatFlags = 0
            asbd.mFramesPerPacket = 1024
            asbd.mSampleRate = Float64(metaData.frequencyInHz)
            asbd.mChannelsPerFrame = UInt32(metaData.channelCount)
            
            CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nil, size, data, nil, &audioFormat)
            
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)

            audio.expectsMediaDataInRealTime = true
            
            if assetWriter.canAdd(audio) {
                assetWriter.add(audio)
                audioInput = audio
            } else {
                Logger.error("cannot add audio input")
            }
        }
    }
    
    private func writingThread() {
        let fileUrl = URL(fileURLWithPath: filename)
        do {
            let writer = try AVAssetWriter(url: fileUrl, fileType: .mp4)
            
            let fileManager = FileManager()
            let filePath = fileUrl.path
            if fileManager.fileExists(atPath: filePath) {
                try fileManager.removeItem(at: fileUrl)
            }
            
            assetWriter = writer
            assetWriter?.shouldOptimizeForNetworkUse = false
            
        } catch {
            Logger.error("Could not create AVAssetWriter: \(error)")
            return
        }
        
        while !exiting.value {
            cond.lock()
            defer {
                cond.unlock()
            }
            
            writingQueue.sync {
                writeSample(.video)
                writeSample(.audio)
            }
            
            if videoSamples.count < 2 && audioSamples.count < 2 && !exiting.value {
                cond.wait()
            }
        }
        
        while videoSamples.count > 0 || audioSamples.count > 0 {
            writingQueue.sync {
                writeSample(.video)
                writeSample(.audio)
            }
        }
        
        /*videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        assetWriter?.endSession(atSourceTime: lastVideoFrameTime)*/
        assetWriter?.finishWriting(completionHandler: { [weak self] in
            guard let strongSelf = self else { return }
            Logger.debug("Stopped writing video file")
            if strongSelf.assetWriter?.status == .failed {
                Logger.error("creating video file failed: \(String(describing: strongSelf.assetWriter?.error))")
            }
            strongSelf.stopCallback?()
        })

    }
    
    private func writeSample(_ mediaType: AVMediaType) {
        let samples = (mediaType == .video) ? videoSamples : audioSamples
        if samples.count > 1 || (exiting.value && samples.count > 0) {
            guard let format = (mediaType == .video) ? videoFormat : audioFormat else { return }
            guard var sampleInput = (mediaType == .video) ? videoSamples.popLast() : audioSamples.popLast() else {
                Logger.debug("unexpected return")
                return
            }
            let nextSampleInput = samples.last ?? sampleInput
            guard let assetWriter = assetWriter else {
                Logger.debug("unexpected return")
                return
            }
            
            var sampleOut: CMSampleBuffer?
            var size: Int = sampleInput.size
            
            sampleInput.timingInfo.duration = nextSampleInput.timingInfo.decodeTimeStamp - sampleInput.timingInfo.decodeTimeStamp
            if CMTimeCompare(kCMTimeZero, sampleInput.timingInfo.duration) == 0 {
                // last sample
                sampleInput.timingInfo.duration = .init(value: 1, timescale: 100000)
            }
            
            CMSampleBufferCreate(kCFAllocatorDefault, sampleInput.buffer, true, nil, nil, format, 1, 1, &sampleInput.timingInfo, 1, &size, &sampleOut)
            
            guard let sample = sampleOut else {
                Logger.debug("unexpected return")
                return
            }
            CMSampleBufferMakeDataReady(sample)
            
            guard let input = (mediaType == .video) ? videoInput : audioInput else {
                Logger.debug("unexpected return")
                return
            }
            
            if mediaType == .audio {
                if firstAudioBuffer {
                    firstAudioBuffer = false
                    primeAudio(audioSample: sample)
                }
            }
            
            guard assetWriter.status == .writing else {
                Logger.debug("unexpected return")
                return
            }
            let mediaType = mediaType.rawValue
            Logger.verbose("Appending \(mediaType)")
            if input.isReadyForMoreMediaData {
                if !input.append(sample) {
                    Logger.error("could not append \(mediaType): \(String(describing: assetWriter.error))")
                }
            } else {
                Logger.warn("\(mediaType) input not ready for more media data, dropping buffer")
            }
            Logger.verbose("Done \(mediaType)")
        }
    }
    
    private func createAVCC() {
        guard let assetWriter = assetWriter else { return }
        switch videoCodecType {
        case kCMVideoCodecType_H264:
            guard !sps.isEmpty && !pps.isEmpty else { return }
        case kCMVideoCodecType_HEVC:
            guard !vps.isEmpty && !sps.isEmpty && !pps.isEmpty else { return }
        default:
            Logger.error("unsupported codec type: \(videoCodecType)")
            return
        }
        
        let pointerVPS = UnsafePointer<UInt8>(vps)
        let pointerSPS = UnsafePointer<UInt8>(sps)
        let pointerPPS = UnsafePointer<UInt8>(pps)
        
        var dataParamArray = [pointerSPS, pointerPPS]
        var sizeParamArray = [sps.count, pps.count]
        if videoCodecType == kCMVideoCodecType_HEVC {
            dataParamArray.insert(pointerVPS, at: 0)
            sizeParamArray.insert(vps.count, at: 0)
        }
        
        let paramterSetPointers = UnsafePointer<UnsafePointer<UInt8>>(dataParamArray)
        let parameterSetSizes = UnsafePointer<Int>(sizeParamArray)
        
        switch videoCodecType {
        case kCMVideoCodecType_H264:
            let ret = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, dataParamArray.count, paramterSetPointers, parameterSetSizes, 4, &videoFormat)
            guard ret == noErr else {
                Logger.error("could not create video format for h264")
                return
            }
        case kCMVideoCodecType_HEVC:
            if #available(iOS 11.0, *) {
                let ret = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, dataParamArray.count, paramterSetPointers, parameterSetSizes, 4, nil, &videoFormat)
                guard ret == noErr else {
                    Logger.error("could not create video format for hevc")
                    return
                }
            } else {
                Logger.error("unsupported codec type: \(videoCodecType)")
                return
            }
        default:
            return
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        
        if assetWriter.canAdd(video) {
            assetWriter.add(video)
            videoInput = video
        } else {
            Logger.error("cannot add video input")
        }
    }
    
    private func primeAudio(audioSample: CMSampleBuffer) {
        var attachmentMode: CMAttachmentMode = .init()
        let trimDuration = CMGetAttachment(audioSample, kCMSampleBufferAttachmentKey_TrimDurationAtStart, &attachmentMode)
        
        if trimDuration == nil {
            Logger.debug("Prime audio")
            let trimTime: CMTime = .init(seconds: 0.1, preferredTimescale: 1000000000)
            let timeDict = CMTimeCopyAsDictionary(trimTime, kCFAllocatorDefault)
            CMSetAttachment(audioSample, kCMSampleBufferAttachmentKey_TrimDurationAtStart, timeDict, kCMAttachmentMode_ShouldPropagate)
        }
    }
}
