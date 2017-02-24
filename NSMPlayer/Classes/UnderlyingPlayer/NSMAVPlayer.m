//
//  NSMAVPlayer.m
//  AVFoundataion_Playback
//
//  Created by chengqihan on 2017/2/9.
//  Copyright © 2017年 chengqihan. All rights reserved.
//

#import "NSMAVPlayer.h"
#import <Bolts/Bolts.h>
#import "NSMAVPlayerView.h"
#import "NSMPlayerProtocol.h"
#import "NSMPlayerLogging.h"
#import "NSMPlayerAsset.h"
#import "NSMUnderlyingPlayer.h"

@interface NSMAVPlayer ()

@property (nonatomic, strong) AVURLAsset *asset;
@property (nonatomic, strong) id timeObserverToken;
@property (nonatomic, strong) BFTaskCompletionSource *prepareSouce;
@property (nonatomic, strong) NSMPlayerAsset *currentAsset;
@property (nonatomic, strong) NSProgress *playbackProgress;
@property (nonatomic, strong) NSProgress *bufferProgress;

@end

@implementation NSMAVPlayer

@dynamic playerView, playerType ,playerError, currentStatus, autoPlay, loopPlayback, preload, allowWWAN;

#pragma mark - Properties

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        _playbackProgress = [NSProgress progressWithTotalUnitCount:0];
        _bufferProgress = [NSProgress progressWithTotalUnitCount:0];
    }
    return self;
}


- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerPlaybackStallingNotification object:self userInfo:nil];
}

// Will attempt load and test these asset keys before playing
+ (NSArray *)assetKeysRequiredToPlay {
    return @[@"tracks", @"playable", @"hasProtectedContent"];
}


#pragma mark - Asset Loading

- (BFTask *)asynchronouslyLoadURLAsset:(AVURLAsset *)newAsset {
    BFTaskCompletionSource *source = [BFTaskCompletionSource taskCompletionSource];
    self.prepareSouce = source;
    /*
     Using AVAsset now runs the risk of blocking the current thread
     (the main UI thread) whilst I/O happens to populate the
     properties. It's prudent to defer our work until the properties
     we need have been loaded.
     */
    [newAsset loadValuesAsynchronouslyForKeys:self.class.assetKeysRequiredToPlay completionHandler:^{
        
        /*
         The asset invokes its completion handler on an arbitrary queue.
         To avoid multiple threads using our internal state at the same time
         we'll elect to use the main thread at all times, let's dispatch
         our handler to the main queue.
         */
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (newAsset != self.asset) {
                /*
                 self.asset has already changed! No point continuing because
                 another newAsset will come along in a moment.
                 */
                [source setError:[NSError errorWithDomain:NSMUnderlyingPlayerErrorDomain code:0 userInfo:@{NSLocalizedFailureReasonErrorKey : @"asset has already changed"}]];
                return;
            }
            
            /*
             Test whether the values of each of the keys we need have been
             successfully loaded.
             */
            for (NSString *key in self.class.assetKeysRequiredToPlay) {
                NSError *error = nil;
                AVKeyValueStatus status = [newAsset statusOfValueForKey:key error:&error];
                if (status == AVKeyValueStatusFailed) {
                    [source setError:error];
                    return;
                }
            }
            
            // We can't play this asset.
            if (!newAsset.playable || newAsset.hasProtectedContent) {
                [source setError:[NSError errorWithDomain:NSMUnderlyingPlayerErrorDomain code:0 userInfo:@{NSLocalizedFailureReasonErrorKey : @"Can't use this AVAsset because it isn't playable or has protected content"}]];
                return;
            }
            
            /*
             We can play this asset. Create a new AVPlayerItem and make it
             our player's current item.
             */
            [self setupAVPlayerWithAsset:newAsset];
            
        });
    }];
    return source.task;
}

- (void)setupAVPlayerWithAsset:(AVAsset *)asset {
    NSAssert([NSThread currentThread] == [NSThread mainThread], @"You should register for KVO change notifications and unregister from KVO change notifications on the main thread. ");
    
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
    // ensure that this is done before the playerItem is associated with the player
    //inspect whether if paused <rate == 0>
    
    [playerItem addObserver:self forKeyPath:@"status" options:0 context:nil];
    [playerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:0 context:nil];
    
    //waitingBufferToPlay
    [playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:0 context:nil];
    [playerItem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:0 context:nil];
    
    //playToEndTime
    /* Note that NSNotifications posted by AVPlayerItem may be posted on a different thread from the one on which the observer was registered. */
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemFailedToPlayToEndTime:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    
    
    [self removeTimeObserverToken];
    [self removeCurrentItemObserver];
    
    if (self.avplayer == nil) {
        self.avplayer = [[AVPlayer alloc] init];
    }
    
    
    [self.avplayer replaceCurrentItemWithPlayerItem:playerItem];
    
    // Invoke callback every one second
    [self addTimeObserverToken];
}

//- (CGFloat)bufferPercentage {
////    NSMPlayerLogInfo(@"bufferPercentage == %@",@(_bufferPercentage));
//    return _bufferPercentage;
//}
#pragma mark - NSMUnderlyingPlayerProtocol

/**
 Preparing an Asset for Use
 If you want to prepare an asset for playback, you should load its tracks property
 */
- (void)replaceCurrentAssetWithAsset:(NSMPlayerAsset *)asset {
    self.currentAsset = asset;
}


- (BFTask *)prepare {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.currentAsset.assetURL options:nil];
    self.asset = asset;
    return [self asynchronouslyLoadURLAsset:asset];
}


- (void)play {
    [self.avplayer play];
}

- (void)pause {
    [self.avplayer pause];
}

- (void)setRate:(CGFloat)rate {
    self.avplayer.rate = rate;
}
//- (void)suspendPlayingback {
//    [self setRate:0.0];
//    [self removeTimeObserverToken];
//}

- (BFTask *)seekToTime:(NSTimeInterval)seconds {
    CMTime time = CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC);
    BFTaskCompletionSource *tcs = [BFTaskCompletionSource taskCompletionSource];
    [self.avplayer seekToTime:time completionHandler:^(BOOL finished) {
        if (finished) {
            [tcs setResult:nil];
        }
    }];
    return tcs.task;
}

//- (NSTimeInterval)currentTime {
//    if (self.avplayer) {
//        NSTimeInterval currentTime = CMTimeGetSeconds(self.avplayer.currentTime);
////        NSMPlayerLogInfo(@"currentTime == %@",@(currentTime));
//        return currentTime;
//    }
//    return 0;
//}

/**
 You should register for KVO change notifications and unregister from KVO change notifications on the main thread.
 * so releasePlayer method should invoke on the main thread
 */
- (void)releasePlayer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self removeCurrentItemObserver];
        [self removeTimeObserverToken];
        [self.avplayer replaceCurrentItemWithPlayerItem:nil];
        self.avplayer = nil;
    });
}

- (void)setVolume:(CGFloat)volume {
    self.avplayer.volume = volume;
}

- (CGFloat)volume {
    return self.avplayer.volume;
}

- (void)setMuted:(BOOL)on {
    self.avplayer.muted = on;
}

- (BOOL)isMuted {
    return self.avplayer.isMuted;
}


- (CGFloat)rate {
    return self.avplayer.rate;
}

//- (NSTimeInterval)duration {
//    if (AVPlayerItemStatusReadyToPlay == self.avplayer.status) {
//        NSMPlayerLogDebug(@"duration == %@ currentItem == %@", @(CMTimeGetSeconds(self.avplayer.currentItem.duration)), self.avplayer.currentItem);
//        return CMTimeGetSeconds(self.avplayer.currentItem.duration);
//    }
//    return 0;
//}

- (void)setPlayerView:(id<NSMVideoPlayerViewProtocol>)playerView {
    [playerView setPlayer:self.avplayer];
}

#pragma mark - - NSKeyValueObserving

// AV Foundation does not specify what thread that the notification is sent on
// if you want to update the user interface, you must make sure that any relevant code is invoked on the main thread
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"status"]) {
        //POST
//        NSMPlayerLogDebug(@"currentItem status %@",@(self.avplayer.currentItem.status));
        if (self.avplayer.currentItem.status == AVPlayerItemStatusReadyToPlay){
            //Prepared finish
            if (self.prepareSouce && !self.prepareSouce.task.isCompleted) {
//                NSMVideoAssetInfo *assetInfo = [[NSMVideoAssetInfo alloc] init];
               NSTimeInterval duration = CMTimeGetSeconds(self.avplayer.currentItem.duration);
//                assetInfo.duration = CMTimeGetSeconds(self.avplayer.currentItem.duration);
                self.bufferProgress.totalUnitCount = self.playbackProgress.totalUnitCount = duration;
                [self.prepareSouce setResult:@YES];
            }
        } else if (AVPlayerItemStatusFailed == self.avplayer.currentItem.status) {
            //If the receiver's status is AVPlayerStatusFailed, this describes the error that caused the failure
            NSMPlayerLogError(@"AVPlayerStatusFailed error:%@",self.avplayer.error);
            [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerFailedNotification object:self userInfo:@{NSMUnderlyingPlayerErrorKey : self.avplayer.error}];
        }
    } else if ([keyPath isEqualToString:@"loadedTimeRanges"]) {
        //The array contains NSValue objects containing a CMTimeRange value indicating the times ranges for which the player item has media data readily available. The time ranges returned may be discontinuous.
        NSArray *loadedTimeRanges = self.avplayer.currentItem.loadedTimeRanges;
        if (loadedTimeRanges) {
            CMTimeRange timeRange = [loadedTimeRanges.firstObject CMTimeRangeValue];
            CGFloat rangeStartSeconds = CMTimeGetSeconds(timeRange.start);
            CGFloat rangeDurationSeconds = CMTimeGetSeconds(timeRange.duration);
//            NSMPlayerLogDebug(@"rangeStartSeconds:%f rangeDurationSeconds:%f",rangeStartSeconds,rangeDurationSeconds);
//            _bufferPercentage = (rangeStartSeconds + rangeDurationSeconds) / self.duration;
            self.bufferProgress.completedUnitCount = rangeStartSeconds + rangeDurationSeconds;
            //            [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerLoadedTimeRangesDidChangeNotification object:self userInfo:@{NSMUnderlyingPlayerLoadedTimeRangesKey : loadedTimeRanges.firstObject}];
        }
        
    } else if ([keyPath isEqualToString:@"playbackBufferEmpty"]) {
        //indicates that playback has consumed all buffered media and that playback will stall or end
        if (self.avplayer.currentItem.isPlaybackBufferEmpty) {
//            NSMPlayerLogDebug(@"playbackBufferEmpty:%@",@(self.avplayer.currentItem.playbackBufferEmpty));
            [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerPlaybackBufferEmptyNotification object:self userInfo:nil];
        } else {
//            NSMPlayerLogDebug(@"playbackBufferEmpty:%@",@(self.avplayer.currentItem.playbackBufferEmpty));
        }
        
    } else if ([keyPath isEqualToString:@"playbackLikelyToKeepUp"]) {
        //Indicates whether the item will likely play through without stalling
        if (self.avplayer.currentItem.isPlaybackLikelyToKeepUp) {
//            NSMPlayerLogDebug(@"playbackLikelyToKeepUp:%@",@(self.avplayer.currentItem.playbackLikelyToKeepUp));
            [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerPlaybackLikelyToKeepUpNotification object:self userInfo:nil];
        } else {
            [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerPlaybackBufferEmptyNotification object:self userInfo:nil];
//            NSMPlayerLogDebug(@"playbackLikelyToKeepUp:%@",@(self.avplayer.currentItem.playbackLikelyToKeepUp));
        }
    }
}

#pragma mark - NSNotification

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerDidPlayToEndTimeNotification object:self userInfo:nil];
}

- (void)playerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSLog(@"playerItemFailedToPlayToEndTime == %@",notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]);
    [[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerFailedNotification object:self userInfo:@{NSMUnderlyingPlayerErrorKey : notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]}];
}

- (void)dealloc {
    [self removeTimeObserverToken];
    [self removeCurrentItemObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)removeTimeObserverToken {
    if (self.timeObserverToken) {
        /*
         * 只能保证调用下面方法的时候，只能保证这个方法 - (id)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue usingBlock:(void (^)(CMTime time))block 中的block不会被再次触发，而不能保证已经触发的 block 中断执行，可以用这个做到 dispatch_sync(queue, ^{} 。
         */
        [self.avplayer removeTimeObserver:self.timeObserverToken];
        self.timeObserverToken = nil;
    }
}

- (void)addTimeObserverToken {
    __weak __typeof(self) weakself = self;
    dispatch_queue_t mainQueue = dispatch_get_main_queue();
    self.timeObserverToken = [self.avplayer addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1, NSEC_PER_SEC) queue:mainQueue usingBlock:^(CMTime time) {
        NSTimeInterval currenTimeInterval = CMTimeGetSeconds(time);
        NSMPlayerLogDebug(@"currenTimeInterval : %.2f",currenTimeInterval);
        //[[NSNotificationCenter defaultCenter] postNotificationName:NSMUnderlyingPlayerPlayheadDidChangeNotification object:weakself userInfo:@{NSMUnderlyingPlayerPeriodicPlayTimeChangeKey : @(currenTimeInterval)}];
        weakself.playbackProgress.completedUnitCount = currenTimeInterval;
    }];
}

- (void)removeCurrentItemObserver {
    if (self.avplayer.currentItem) {
        NSAssert([NSThread currentThread] == [NSThread mainThread], @"You should register for KVO change notifications and unregister from KVO change notifications on the main thread. ");
        [self.avplayer.currentItem removeObserver:self forKeyPath:@"status" context:nil];
        [self.avplayer.currentItem removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
        [self.avplayer.currentItem removeObserver:self forKeyPath:@"playbackBufferEmpty" context:nil];
        [self.avplayer.currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:nil];
    }
}

- (void)setPlayerRenderView:(id<NSMVideoPlayerViewProtocol>)playerRenderView {
    [playerRenderView setPlayer:self];
}

- (UIImage *)thumnailImageWithTime:(CMTime)requestTime {
    AVAsset *myAsset = self.asset;
    if ([[myAsset tracksWithMediaType:AVMediaTypeVideo] count] > 0) {
        AVAssetImageGenerator *imageGenerator =
        [AVAssetImageGenerator assetImageGeneratorWithAsset:myAsset];
        NSError *error;
        CMTime actualTime;
        CGImageRef halfWayImage = [imageGenerator copyCGImageAtTime:requestTime actualTime:&actualTime error:&error];
        if (halfWayImage != NULL) {
            return [UIImage imageWithCGImage:halfWayImage];
        }
    }
    return nil;
}


@end