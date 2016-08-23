import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore

private final class ThreadTaskQueue: NSObject {
    private var mutex: pthread_mutex_t
    private var condition: pthread_cond_t
    private var tasks: [() -> Void] = []
    private var shouldExit = false
    
    override init() {
        self.mutex = pthread_mutex_t()
        self.condition = pthread_cond_t()
        pthread_mutex_init(&self.mutex, nil)
        pthread_cond_init(&self.condition, nil)
        
        super.init()
    }
    
    deinit {
        pthread_mutex_destroy(&self.mutex)
        pthread_cond_destroy(&self.condition)
    }
    
    func loop() {
        while !self.shouldExit {
            pthread_mutex_lock(&self.mutex)
            
            if tasks.isEmpty {
                pthread_cond_wait(&self.condition, &self.mutex)
            }
            
            var task: (() -> Void)?
            if !self.tasks.isEmpty {
                task = self.tasks.removeFirst()
            }
            
            pthread_mutex_unlock(&self.mutex)
            
            if let task = task {
                autoreleasepool {
                    task()
                }
            }
        }
    }
    
    func enqueue(_ task: @escaping () -> Void) {
        pthread_mutex_lock(&self.mutex)
        self.tasks.append(task)
        pthread_cond_broadcast(&self.condition)
        pthread_mutex_unlock(&self.mutex)
    }
    
    func terminate() {
        pthread_mutex_lock(&self.mutex)
        self.shouldExit = true
        pthread_cond_broadcast(&self.condition)
        pthread_mutex_unlock(&self.mutex)
    }
}

private func contextForCurrentThread() -> FFMpegMediaFrameSourceContext? {
    return Thread.current.threadDictionary["FFMpegMediaFrameSourceContext"] as? FFMpegMediaFrameSourceContext
}

final class FFMpegMediaFrameSource: NSObject, MediaFrameSource {
    private let queue: Queue
    private let account: Account
    private let resource: MediaResource
    
    private let taskQueue: ThreadTaskQueue
    private let thread: Thread
    
    private let eventSinkBag = Bag<(MediaTrackEvent) -> Void>()
    private var generatingFrames = false
    private var requestedFrameGenerationTimestamp: Double?
    
    @objc private static func threadEntry(_ taskQueue: ThreadTaskQueue) {
        autoreleasepool {
            let context = FFMpegMediaFrameSourceContext(thread: Thread.current)
            let localStorage = Thread.current.threadDictionary
            localStorage["FFMpegMediaFrameSourceContext"] = context

            taskQueue.loop()
        }
    }
   
    init(queue: Queue, account: Account, resource: MediaResource) {
        self.queue = queue
        self.account = account
        self.resource = resource
        
        self.taskQueue = ThreadTaskQueue()
        
        self.thread = Thread(target: FFMpegMediaFrameSource.self, selector: #selector(FFMpegMediaFrameSource.threadEntry(_:)), object: taskQueue)
        self.thread.name = "FFMpegMediaFrameSourceContext"
        self.thread.start()
        
        super.init()
    }
    
    deinit {
        assert(self.queue.isCurrent())
        
        self.taskQueue.terminate()
    }
    
    func addEventSink(_ f: @escaping (MediaTrackEvent) -> Void) -> Int {
        assert(self.queue.isCurrent())
        
        return self.eventSinkBag.add(f)
    }
    
    func removeEventSink(_ index: Int) {
        assert(self.queue.isCurrent())
        
        self.eventSinkBag.remove(index)
    }
    
    func generateFrames(until timestamp: Double) {
        assert(self.queue.isCurrent())
        
        if self.requestedFrameGenerationTimestamp == nil || !self.requestedFrameGenerationTimestamp!.isEqual(to: timestamp) {
            self.requestedFrameGenerationTimestamp = timestamp
            
            self.internalGenerateFrames(until: timestamp)
        }
    }
    
    private func internalGenerateFrames(until timestamp: Double) {
        if self.generatingFrames {
            return
        }
        
        self.generatingFrames = true
        
        let account = self.account
        let resource = self.resource
        let queue = self.queue
        self.performWithContext { [weak self] context in
            context.initializeState(account: account, resource: resource)
            
            let frames = context.takeFrames(until: timestamp)
            
            queue.async { [weak self] in
                if let strongSelf = self {
                    strongSelf.generatingFrames = false
                    
                    for sink in strongSelf.eventSinkBag.copyItems() {
                        sink(.frames(frames))
                    }
                    
                    if strongSelf.requestedFrameGenerationTimestamp != nil && !strongSelf.requestedFrameGenerationTimestamp!.isEqual(to: timestamp) {
                        strongSelf.internalGenerateFrames(until: strongSelf.requestedFrameGenerationTimestamp!)
                    }
                }
            }
        }
    }
    
    func performWithContext(_ f: @escaping (FFMpegMediaFrameSourceContext) -> Void) {
        assert(self.queue.isCurrent())
        
        taskQueue.enqueue {
            if let context = contextForCurrentThread() {
                f(context)
            }
        }
    }
    
    func seek(timestamp: Double) -> Signal<MediaFrameSourceSeekResult, MediaFrameSourceSeekError> {
        assert(self.queue.isCurrent())
        
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            let queue = self.queue
            let account = self.account
            let resource = self.resource
            
            self.performWithContext { [weak self] context in
                context.initializeState(account: account, resource: resource)
                
                context.seek(timestamp: timestamp, completed: { [weak self] streamDescriptions, timestamp in
                    queue.async { [weak self] in
                        if let strongSelf = self {
                            var audioBuffer: MediaTrackFrameBuffer?
                            var videoBuffer: MediaTrackFrameBuffer?
                            
                            if let audio = streamDescriptions.audio {
                                audioBuffer = MediaTrackFrameBuffer(frameSource: strongSelf, decoder: audio.decoder, type: .audio, duration: audio.duration)
                            }
                            
                            if let video = streamDescriptions.video {
                                videoBuffer = MediaTrackFrameBuffer(frameSource: strongSelf, decoder: video.decoder, type: .video, duration: video.duration)
                            }
                            
                            strongSelf.requestedFrameGenerationTimestamp = nil
                            subscriber.putNext(MediaFrameSourceSeekResult(buffers: MediaPlaybackBuffers(audioBuffer: audioBuffer, videoBuffer: videoBuffer), timestamp: timestamp))
                            subscriber.putCompletion()
                        }
                    }
                })
            }
            
            return disposable
        }
    }
}
