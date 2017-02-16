//
//  CameraViewController.m
//  LLSimpleCamera
//
//  Created by Ömer Faruk Gül on 24/10/14.
//  Copyright (c) 2014 Ömer Faruk Gül. All rights reserved.
//

#import "LLSimpleCamera.h"
#import <ImageIO/CGImageProperties.h>
#import "UIImage+FixOrientation.h"
#import "LLSimpleCamera+Helper.h"
#import "CALayer+Additions.h"

@interface LLSimpleCamera () <AVCaptureFileOutputRecordingDelegate, UIGestureRecognizerDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (strong, nonatomic) UIView *preview;
@property (strong, nonatomic) AVCaptureStillImageOutput *stillImageOutput;
@property (strong, nonatomic) AVCaptureDevice *audioCaptureDevice;
@property (strong, nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (strong, nonatomic) AVCaptureDeviceInput *audioDeviceInput;
@property (strong, nonatomic) UITapGestureRecognizer *tapGesture;
@property (strong, nonatomic) CALayer *focusBoxLayer;
@property (strong, nonatomic) CAAnimation *focusBoxAnimation;
@property (strong, nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (strong, nonatomic) UIPinchGestureRecognizer *pinchGesture;
@property (nonatomic, assign) CGFloat beginGestureScale;
@property (nonatomic, assign) CGFloat effectiveScale;
@property (nonatomic, copy) void (^didRecordCompletionBlock)(LLSimpleCamera *camera, NSURL *outputFileUrl, NSError *error);

@property (nonatomic) CFAbsoluteTime numFaceChangedTime;
@property (nonatomic) CFAbsoluteTime avfLastFrameTime;
@property (nonatomic, assign) NSInteger currentFaceID;
@property (nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property (nonatomic, assign) float avfProcessingInterval;
@property (nonatomic, strong) NSMutableDictionary* avfFaceLayers;

@end

NSString *const LLSimpleCameraErrorDomain = @"LLSimpleCameraErrorDomain";

@implementation LLSimpleCamera

#pragma mark - Initialize

- (instancetype)init
{
    return [self initWithVideoEnabled:NO];
}

- (instancetype)initWithVideoEnabled:(BOOL)videoEnabled
{
    return [self initWithQuality:AVCaptureSessionPresetHigh position:LLCameraPositionRear videoEnabled:videoEnabled];
}

- (instancetype)initWithQuality:(NSString *)quality position:(LLCameraPosition)position videoEnabled:(BOOL)videoEnabled
{
    self = [super initWithNibName:nil bundle:nil];
    if(self) {
        [self setupWithQuality:quality position:position videoEnabled:videoEnabled];
    }
    
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    if (self = [super initWithCoder:aDecoder]) {
        [self setupWithQuality:AVCaptureSessionPresetHigh
                      position:LLCameraPositionRear
                  videoEnabled:YES];
    }
    return self;
}

- (void)setupWithQuality:(NSString *)quality
                position:(LLCameraPosition)position
            videoEnabled:(BOOL)videoEnabled
{
    _cameraQuality = quality;
    _position = position;
    _fixOrientationAfterCapture = NO;
    _tapToFocus = YES;
    _useDeviceOrientation = NO;
    _flash = LLCameraFlashOff;
    _mirror = LLCameraMirrorAuto;
    _videoEnabled = videoEnabled;
    _recording = NO;
    _zoomingEnabled = YES;
    _effectiveScale = 1.0f;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    self.view.autoresizingMask = UIViewAutoresizingNone;
    
    self.preview = [[UIView alloc] initWithFrame:CGRectZero];
    self.preview.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.preview];
    
    // tap to focus
    self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(previewTapped:)];
    self.tapGesture.numberOfTapsRequired = 1;
    [self.tapGesture setDelaysTouchesEnded:NO];
    [self.preview addGestureRecognizer:self.tapGesture];
    
    //pinch to zoom
    if (_zoomingEnabled) {
        self.pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinchGesture:)];
        self.pinchGesture.delegate = self;
        [self.preview addGestureRecognizer:self.pinchGesture];
    }
    
    // add focus box to view
    [self addDefaultFocusBox];
}

#pragma mark Pinch Delegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if ( [gestureRecognizer isKindOfClass:[UIPinchGestureRecognizer class]] ) {
        _beginGestureScale = _effectiveScale;
    }
    return YES;
}

- (void)handlePinchGesture:(UIPinchGestureRecognizer *)recognizer
{
    BOOL allTouchesAreOnThePreviewLayer = YES;
    NSUInteger numTouches = [recognizer numberOfTouches], i;
    for ( i = 0; i < numTouches; ++i ) {
        CGPoint location = [recognizer locationOfTouch:i inView:self.preview];
        CGPoint convertedLocation = [self.preview.layer convertPoint:location fromLayer:self.view.layer];
        if ( ! [self.preview.layer containsPoint:convertedLocation] ) {
            allTouchesAreOnThePreviewLayer = NO;
            break;
        }
    }
    
    if (allTouchesAreOnThePreviewLayer) {
        _effectiveScale = _beginGestureScale * recognizer.scale;
        if (_effectiveScale < 1.0f)
            _effectiveScale = 1.0f;
        if (_effectiveScale > self.videoCaptureDevice.activeFormat.videoMaxZoomFactor)
            _effectiveScale = self.videoCaptureDevice.activeFormat.videoMaxZoomFactor;
        NSError *error = nil;
        if ([self.videoCaptureDevice lockForConfiguration:&error]) {
            [self.videoCaptureDevice rampToVideoZoomFactor:_effectiveScale withRate:100];
            [self.videoCaptureDevice unlockForConfiguration];
        } else {
            [self passError:error];
        }
    }
}

#pragma mark - Camera

- (void)attachToViewController:(UIViewController *)vc withFrame:(CGRect)frame
{
    [vc addChildViewController:self];
    self.view.frame = frame;
    [vc.view addSubview:self.view];
    [self didMoveToParentViewController:vc];
}

- (void)start
{
    [LLSimpleCamera requestCameraPermission:^(BOOL granted) {
        if(granted) {
            // request microphone permission if video is enabled
            if(self.videoEnabled) {
                [LLSimpleCamera requestMicrophonePermission:^(BOOL granted) {
                    if(granted) {
                        [self initialize];
                    }
                    else {
                        NSError *error = [NSError errorWithDomain:LLSimpleCameraErrorDomain
                                                             code:LLSimpleCameraErrorCodeMicrophonePermission
                                                         userInfo:nil];
                        [self passError:error];
                    }
                }];
            }
            else {
                [self initialize];
            }
        }
        else {
            NSError *error = [NSError errorWithDomain:LLSimpleCameraErrorDomain
                                                 code:LLSimpleCameraErrorCodeCameraPermission
                                             userInfo:nil];
            [self passError:error];
        }
    }];
}

- (void)initialize
{
    if(!_session) {
        _session = [[AVCaptureSession alloc] init];
        _session.sessionPreset = self.cameraQuality;
        
        // preview layer
        CGRect bounds = self.preview.layer.bounds;
        _captureVideoPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
        _captureVideoPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        _captureVideoPreviewLayer.bounds = bounds;
        _captureVideoPreviewLayer.position = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
        [self.preview.layer addSublayer:_captureVideoPreviewLayer];
        
        AVCaptureDevicePosition devicePosition;
        switch (self.position) {
            case LLCameraPositionRear:
                if([self.class isRearCameraAvailable]) {
                    devicePosition = AVCaptureDevicePositionBack;
                } else {
                    devicePosition = AVCaptureDevicePositionFront;
                    _position = LLCameraPositionFront;
                }
                break;
            case LLCameraPositionFront:
                if([self.class isFrontCameraAvailable]) {
                    devicePosition = AVCaptureDevicePositionFront;
                } else {
                    devicePosition = AVCaptureDevicePositionBack;
                    _position = LLCameraPositionRear;
                }
                break;
            default:
                devicePosition = AVCaptureDevicePositionUnspecified;
                break;
        }
        
        if(devicePosition == AVCaptureDevicePositionUnspecified) {
            self.videoCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        } else {
            self.videoCaptureDevice = [self cameraWithPosition:devicePosition];
        }
        
        NSError *error = nil;
        _videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:_videoCaptureDevice error:&error];
        
        if (!_videoDeviceInput) {
            [self passError:error];
            return;
        }
        
        if([self.session canAddInput:_videoDeviceInput]) {
            [self.session  addInput:_videoDeviceInput];
            self.captureVideoPreviewLayer.connection.videoOrientation = [self orientationForConnection];
        }
        
        // add audio if video is enabled
        if(self.videoEnabled) {
            _audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            _audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:_audioCaptureDevice error:&error];
            if (!_audioDeviceInput) {
                [self passError:error];
            }
        
            if([self.session canAddInput:_audioDeviceInput]) {
                [self.session addInput:_audioDeviceInput];
            }
        
            _movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
            [_movieFileOutput setMovieFragmentInterval:kCMTimeInvalid];
            if([self.session canAddOutput:_movieFileOutput]) {
                [self.session addOutput:_movieFileOutput];
            }
        }
        
        // continiously adjust white balance
        self.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        
        // face detection output
        [self startFaceDetection];
        
        // image output
        self.stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        NSDictionary *outputSettings = [[NSDictionary alloc] initWithObjectsAndKeys: AVVideoCodecJPEG, AVVideoCodecKey, nil];
        [self.stillImageOutput setOutputSettings:outputSettings];
        [self.session addOutput:self.stillImageOutput];
    }
    
    //if we had disabled the connection on capture, re-enable it
    if (![self.captureVideoPreviewLayer.connection isEnabled]) {
        [self.captureVideoPreviewLayer.connection setEnabled:YES];
    }
    
    [self.session startRunning];
}

- (void)stop
{
    [self.session stopRunning];
    self.session = nil;
}

#pragma mark - FaceDetection

- (void)startFaceDetection {
    
    self.avfProcessingInterval = 1;
    self.avfFaceLayers = [NSMutableDictionary new];
    self.numFaceChangedTime = CFAbsoluteTimeGetCurrent();
    
    self.metadataOutput = [AVCaptureMetadataOutput new];
    
    if ([self.session canAddOutput:self.metadataOutput] == NO)
    {
        [self stopFaceDetection];
        return;
    }
    
    // Metadata processing will be fast, and mostly updating UI which should be done on the main thread
    // So just use the main dispatch queue instead of creating a separate one
    // (compare this to the expensive CoreImage face detection, done on a separate queue)
    [self.metadataOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    [self.session addOutput:self.metadataOutput];
    
    // We only want faces, if we don't set this we would detect everything available
    // (some objects may be expensive to detect, so best form is to select only what you need)
    self.metadataOutput.metadataObjectTypes = @[ AVMetadataObjectTypeFace ];
}

- (void)stopFaceDetection {
    
    [self removeAllFaces];
    if (self.metadataOutput)
    {
        [self.session removeOutput:self.metadataOutput];
    }
    
    self.metadataOutput = nil;
    self.avfFaceLayers = nil;
}

- (AVMetadataFaceObject *)findCurrentFaceObjectInFaces:(NSArray *)faces
                                                unseen:(NSMutableSet *)unseen
{
    AVMetadataFaceObject *currentFaceObject = nil;
    
    for(AVMetadataFaceObject *face in faces)
    {
        NSNumber* faceID = [NSNumber numberWithInteger:face.faceID];
        [unseen removeObject:faceID];
        
        if (face.faceID == self.currentFaceID)
        {
            currentFaceObject = face;
            break;
        }
    }
    
    if (!currentFaceObject)
    {
        currentFaceObject = (AVMetadataFaceObject *)[faces firstObject];
        //self.showsFaceBoxWhenEnabled = YES;
        [self performSelector:@selector(removeAllFacesAndHideFaceBoxes) withObject:nil afterDelay:2.0];
    }
    
    self.currentFaceID = currentFaceObject.faceID;
    return currentFaceObject;
}

- (void)transformLayer:(CALayer *)layer
    withMetaDataObject:(AVMetadataObject *)metaDataObject
{
    AVMetadataFaceObject *adjusted = (AVMetadataFaceObject*)[self.captureVideoPreviewLayer transformedMetadataObjectForMetadataObject:metaDataObject];
    CATransform3D transform = CATransform3DIdentity;
    layer.transform = transform;
    layer.frame = adjusted.bounds;
    layer.transform = transform;
}

- (CALayer *)layerForCurrentFaceID
{
    CALayer *layer = [self.avfFaceLayers objectForKey:@(self.currentFaceID)];
    if (!layer)
    {
        layer = [CALayer new];
        layer.borderWidth = 2.0;
        layer.borderColor = [[UIColor orangeColor] CGColor];
        
        [self.view.layer addSublayer:layer];
        [self.avfFaceLayers setObject:layer forKey:@(self.currentFaceID)];
    }
    return layer;
}

- (void)removeUnseenFaces:(NSMutableSet *)unseen
{
    for(NSNumber* faceID in unseen)
    {
        CALayer * layer = [self.avfFaceLayers objectForKey:faceID];
        if (layer)
        {
            [layer removeFromSuperlayer];
            [self.avfFaceLayers removeObjectForKey:faceID];
        }
    }
}

- (void)removeAllFacesAndHideFaceBoxes
{
    for(NSNumber* key in self.avfFaceLayers)
    {
        CALayer * layer = [self.avfFaceLayers objectForKey:key];
        if (layer && layer.superlayer != nil)
        {
            CGFloat bigScale = 1.15;
            CGSize bigSize = CGSizeMake(layer.frame.size.width * bigScale,
                                        layer.frame.size.height * bigScale);
            
            CABasicAnimation *bigAnimation = [layer resizeFromSize:bigSize
                                                            toSize:layer.frame.size
                                                          duration:0.2];
            
            bigAnimation.beginTime = 0.0;
            bigAnimation.fillMode = kCAFillModeForwards;
            bigAnimation.removedOnCompletion = NO;
            bigAnimation.repeatCount = 2;
            
            CGFloat smallScale = 0.7;
            CGSize smallSize = CGSizeMake(layer.frame.size.width * smallScale,
                                          layer.frame.size.height * smallScale);
            
            CABasicAnimation *smallAnimation = [layer resizeFromSize:layer.frame.size
                                                              toSize:smallSize
                                                            duration:0.15];
            smallAnimation.beginTime = 0.4;
            smallAnimation.fillMode = kCAFillModeForwards;
            smallAnimation.removedOnCompletion = NO;
            
            
            CABasicAnimation *opacityAnimation = [self fadeOutAnimation];
            opacityAnimation.beginTime = smallAnimation.beginTime;
            opacityAnimation.duration = smallAnimation.duration;
            
            
            CAAnimationGroup *smallGroup = [CAAnimationGroup animation];
            smallGroup.animations = @[bigAnimation, smallAnimation, opacityAnimation];
            smallGroup.duration = 0.55;
            smallGroup.beginTime = 0;
            smallGroup.fillMode = kCAFillModeForwards;
            smallGroup.removedOnCompletion = NO;
            [layer addAnimation:smallGroup forKey:@"smallGroup"];
            
            [NSTimer scheduledTimerWithTimeInterval:smallGroup.duration
                                             target:layer
                                           selector:@selector(removeFromSuperlayer)
                                           userInfo:nil
                                            repeats:NO];
            
        }
    }
    
    [self.avfFaceLayers removeAllObjects];
}

- (CABasicAnimation *)fadeOutAnimation
{
    CABasicAnimation *opacityAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    opacityAnimation.fromValue = @(1.0);
    opacityAnimation.removedOnCompletion = NO;
    opacityAnimation.fillMode = kCAFillModeForwards;
    opacityAnimation.toValue = @(0.0);
    
    return opacityAnimation;
}

- (void)removeAllFaces
{
    for(NSNumber* key in self.avfFaceLayers)
    {
        CALayer * layer = [self.avfFaceLayers objectForKey:key];
        if (layer && layer.superlayer != nil)
        {
            [layer removeFromSuperlayer];
        }
    }
    
    
    [self.avfFaceLayers removeAllObjects];
}

- (void)focusCameraOnFace:(AVMetadataFaceObject *)face
{
    // focus every .2 seconds
    
    if (CFAbsoluteTimeGetCurrent() > self.numFaceChangedTime + 0.2) {
        NSLog(@"!!!!Focusing on face!!!");
        CGPoint focusPoint = CGPointMake(CGRectGetMidX(face.bounds), CGRectGetMidY(face.bounds));
        [self focusAtPoint:focusPoint];
        
        self.numFaceChangedTime = CFAbsoluteTimeGetCurrent();
    }
}

-(void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)faces fromConnection:(AVCaptureConnection *)connection {
    
    NSLog(@"Detected faces!!!!");
    // do not refocus on faces if disabled
//    if (self.disabled)
//    {
//        [self removeAllFaces];
//        return;
//    }
    
    // We can assume all received metadata objects are AVMetadataFaceObject only
    // because we set the AVCaptureMetadataOutput's metadataObjectTypes
    // to solely provide AVMetadataObjectTypeFace (see setupAVFoundationFaceDetection)
    if (!connection.enabled) return; // don't update face graphics when preview is frozen
    
    if (self.avfFaceLayers.count == 0) {
        self.avfLastFrameTime = CFAbsoluteTimeGetCurrent();
    }
    else if(faces.count != 0)
    {
        CFAbsoluteTime curTime = CFAbsoluteTimeGetCurrent();
        self.avfProcessingInterval = self.avfProcessingInterval*0.75 + (curTime - self.avfLastFrameTime)*0.25;
        self.avfLastFrameTime = curTime;
    }
    
    // As we process faces below, remove them from this set so at the end we'll know which faces were lost
    NSMutableSet* unseen = [NSMutableSet setWithArray:self.avfFaceLayers.allKeys];
    
    // Begin display updates
    [CATransaction begin];
    
    [CATransaction setAnimationDuration:self.avfProcessingInterval];
    
    AVMetadataFaceObject *currentFaceObject = [self findCurrentFaceObjectInFaces:faces unseen:unseen];
    
    [self focusCameraOnFace:currentFaceObject];
    
    //if (self.showsFaceBoxWhenEnabled)
    {
        CALayer *layer = [self layerForCurrentFaceID];
        [self transformLayer:layer withMetaDataObject:currentFaceObject];
    }
    
    self.currentFaceID = currentFaceObject.faceID;
    
    [self removeUnseenFaces:unseen];
    
    [CATransaction commit];
}

#pragma mark - Image Capture

-(void)capture:(void (^)(LLSimpleCamera *camera, UIImage *image, NSDictionary *metadata, NSError *error))onCapture exactSeenImage:(BOOL)exactSeenImage animationBlock:(void (^)(AVCaptureVideoPreviewLayer *))animationBlock
{
    if(!self.session) {
        NSError *error = [NSError errorWithDomain:LLSimpleCameraErrorDomain
                                    code:LLSimpleCameraErrorCodeSession
                                userInfo:nil];
        onCapture(self, nil, nil, error);
        return;
    }
    
    // get connection and set orientation
    AVCaptureConnection *videoConnection = [self captureConnection];
    videoConnection.videoOrientation = [self orientationForConnection];
    
    BOOL flashActive = self.videoCaptureDevice.flashActive;
    if (!flashActive && animationBlock) {
        animationBlock(self.captureVideoPreviewLayer);
    }
    
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:videoConnection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        
         UIImage *image = nil;
         NSDictionary *metadata = nil;
         
         // check if we got the image buffer
         if (imageSampleBuffer != NULL) {
             CFDictionaryRef exifAttachments = CMGetAttachment(imageSampleBuffer, kCGImagePropertyExifDictionary, NULL);
             if(exifAttachments) {
                 metadata = (__bridge NSDictionary*)exifAttachments;
             }
             
             NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];
             image = [[UIImage alloc] initWithData:imageData];
             
             if(exactSeenImage) {
                 image = [self cropImage:image usingPreviewLayer:self.captureVideoPreviewLayer];
             }
             
             if(self.fixOrientationAfterCapture) {
                 image = [image fixOrientation];
             }
         }
         
         // trigger the block
         if(onCapture) {
             dispatch_async(dispatch_get_main_queue(), ^{
                onCapture(self, image, metadata, error);
             });
         }
     }];
}

-(void)capture:(void (^)(LLSimpleCamera *camera, UIImage *image, NSDictionary *metadata, NSError *error))onCapture exactSeenImage:(BOOL)exactSeenImage {
    
    [self capture:onCapture exactSeenImage:exactSeenImage animationBlock:^(AVCaptureVideoPreviewLayer *layer) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        animation.duration = 0.1;
        animation.autoreverses = YES;
        animation.repeatCount = 0.0;
        animation.fromValue = [NSNumber numberWithFloat:1.0];
        animation.toValue = [NSNumber numberWithFloat:0.1];
        animation.fillMode = kCAFillModeForwards;
        animation.removedOnCompletion = NO;
        [layer addAnimation:animation forKey:@"animateOpacity"];
    }];
}

-(void)capture:(void (^)(LLSimpleCamera *camera, UIImage *image, NSDictionary *metadata, NSError *error))onCapture
{
    [self capture:onCapture exactSeenImage:NO];
}

#pragma mark - Video Capture

- (void)startRecordingWithOutputUrl:(NSURL *)url didRecord:(void (^)(LLSimpleCamera *camera, NSURL *outputFileUrl, NSError *error))completionBlock
{
    // check if video is enabled
    if(!self.videoEnabled) {
        NSError *error = [NSError errorWithDomain:LLSimpleCameraErrorDomain
                                             code:LLSimpleCameraErrorCodeVideoNotEnabled
                                         userInfo:nil];
        [self passError:error];
        return;
    }
    
    if(self.flash == LLCameraFlashOn) {
        [self enableTorch:YES];
    }
    
    // set video orientation
    for(AVCaptureConnection *connection in [self.movieFileOutput connections]) {
        for (AVCaptureInputPort *port in [connection inputPorts]) {
            // get only the video media types
            if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
                if ([connection isVideoOrientationSupported]) {
                    [connection setVideoOrientation:[self orientationForConnection]];
                }
            }
        }
    }
    
    self.didRecordCompletionBlock = completionBlock;
    
    [self.movieFileOutput startRecordingToOutputFileURL:url recordingDelegate:self];
}

- (void)stopRecording
{
    if(!self.videoEnabled) {
        return;
    }
    
    [self.movieFileOutput stopRecording];
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections
{
    self.recording = YES;
    if(self.onStartRecording) self.onStartRecording(self);
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    self.recording = NO;
    [self enableTorch:NO];
    
    if(self.didRecordCompletionBlock) {
        self.didRecordCompletionBlock(self, outputFileURL, error);
    }
}

- (void)enableTorch:(BOOL)enabled
{
    // check if the device has a torch, otherwise don't do anything
    if([self isTorchAvailable]) {
        AVCaptureTorchMode torchMode = enabled ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
        NSError *error;
        if ([self.videoCaptureDevice lockForConfiguration:&error]) {
            [self.videoCaptureDevice setTorchMode:torchMode];
            [self.videoCaptureDevice unlockForConfiguration];
        } else {
            [self passError:error];
        }
    }
}

#pragma mark - Helpers

- (void)passError:(NSError *)error
{
    if(self.onError) {
        __weak typeof(self) weakSelf = self;
        self.onError(weakSelf, error);
    }
}

- (AVCaptureConnection *)captureConnection
{
    AVCaptureConnection *videoConnection = nil;
    for (AVCaptureConnection *connection in self.stillImageOutput.connections) {
        for (AVCaptureInputPort *port in [connection inputPorts]) {
            if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
                videoConnection = connection;
                break;
            }
        }
        if (videoConnection) {
            break;
        }
    }
    
    return videoConnection;
}

- (void)setVideoCaptureDevice:(AVCaptureDevice *)videoCaptureDevice
{
    _videoCaptureDevice = videoCaptureDevice;
    
    if(videoCaptureDevice.flashMode == AVCaptureFlashModeAuto) {
        _flash = LLCameraFlashAuto;
    } else if(videoCaptureDevice.flashMode == AVCaptureFlashModeOn) {
        _flash = LLCameraFlashOn;
    } else if(videoCaptureDevice.flashMode == AVCaptureFlashModeOff) {
        _flash = LLCameraFlashOff;
    } else {
        _flash = LLCameraFlashOff;
    }
    
    _effectiveScale = 1.0f;
    
    // trigger block
    if(self.onDeviceChange) {
        __weak typeof(self) weakSelf = self;
        self.onDeviceChange(weakSelf, videoCaptureDevice);
    }
}

- (BOOL)isFlashAvailable
{
    return self.videoCaptureDevice.hasFlash && self.videoCaptureDevice.isFlashAvailable;
}

- (BOOL)isTorchAvailable
{
    return self.videoCaptureDevice.hasTorch && self.videoCaptureDevice.isTorchAvailable;
}

- (BOOL)updateFlashMode:(LLCameraFlash)cameraFlash
{
    if(!self.session)
        return NO;
    
    AVCaptureFlashMode flashMode;
    
    if(cameraFlash == LLCameraFlashOn) {
        flashMode = AVCaptureFlashModeOn;
    } else if(cameraFlash == LLCameraFlashAuto) {
        flashMode = AVCaptureFlashModeAuto;
    } else {
        flashMode = AVCaptureFlashModeOff;
    }
    
    if([self.videoCaptureDevice isFlashModeSupported:flashMode]) {
        NSError *error;
        if([self.videoCaptureDevice lockForConfiguration:&error]) {
            self.videoCaptureDevice.flashMode = flashMode;
            [self.videoCaptureDevice unlockForConfiguration];
            
            _flash = cameraFlash;
            return YES;
        } else {
            [self passError:error];
            return NO;
        }
    }
    else {
        return NO;
    }
}

- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)whiteBalanceMode
{
    if ([self.videoCaptureDevice isWhiteBalanceModeSupported:whiteBalanceMode]) {
        NSError *error;
        if ([self.videoCaptureDevice lockForConfiguration:&error]) {
            [self.videoCaptureDevice setWhiteBalanceMode:whiteBalanceMode];
            [self.videoCaptureDevice unlockForConfiguration];
        } else {
            [self passError:error];
        }
    }
}

- (void)setMirror:(LLCameraMirror)mirror
{
    _mirror = mirror;

    if(!self.session) {
        return;
    }

    AVCaptureConnection *videoConnection = [_movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    AVCaptureConnection *pictureConnection = [_stillImageOutput connectionWithMediaType:AVMediaTypeVideo];

    switch (mirror) {
        case LLCameraMirrorOff: {
            if ([videoConnection isVideoMirroringSupported]) {
                [videoConnection setVideoMirrored:NO];
            }
            
            if ([pictureConnection isVideoMirroringSupported]) {
                [pictureConnection setVideoMirrored:NO];
            }
            break;
        }

        case LLCameraMirrorOn: {
            if ([videoConnection isVideoMirroringSupported]) {
                [videoConnection setVideoMirrored:YES];
            }
            
            if ([pictureConnection isVideoMirroringSupported]) {
                [pictureConnection setVideoMirrored:YES];
            }
            break;
        }

        case LLCameraMirrorAuto: {
            BOOL shouldMirror = (_position == LLCameraPositionFront);
            if ([videoConnection isVideoMirroringSupported]) {
                [videoConnection setVideoMirrored:shouldMirror];
            }
            
            if ([pictureConnection isVideoMirroringSupported]) {
                [pictureConnection setVideoMirrored:shouldMirror];
            }
            break;
        }
    }

    return;
}

- (LLCameraPosition)togglePosition
{
    if(!self.session) {
        return self.position;
    }
    
    if(self.position == LLCameraPositionRear) {
        self.cameraPosition = LLCameraPositionFront;
    } else {
        self.cameraPosition = LLCameraPositionRear;
    }
    
    return self.position;
}

- (void)setCameraPosition:(LLCameraPosition)cameraPosition
{
    if(_position == cameraPosition || !self.session) {
        return;
    }
    
    if(cameraPosition == LLCameraPositionRear && ![self.class isRearCameraAvailable]) {
        return;
    }
    
    if(cameraPosition == LLCameraPositionFront && ![self.class isFrontCameraAvailable]) {
        return;
    }
    
    [self.session beginConfiguration];
    
    // remove existing input
    [self.session removeInput:self.videoDeviceInput];
    
    // get new input
    AVCaptureDevice *device = nil;
    if(self.videoDeviceInput.device.position == AVCaptureDevicePositionBack) {
        device = [self cameraWithPosition:AVCaptureDevicePositionFront];
    } else {
        device = [self cameraWithPosition:AVCaptureDevicePositionBack];
    }
    
    if(!device) {
        return;
    }
    
    // add input to session
    NSError *error = nil;
    AVCaptureDeviceInput *videoInput = [[AVCaptureDeviceInput alloc] initWithDevice:device error:&error];
    if(error) {
        [self passError:error];
        [self.session commitConfiguration];
        return;
    }
    
    _position = cameraPosition;
    
    [self.session addInput:videoInput];
    [self.session commitConfiguration];
    
    self.videoCaptureDevice = device;
    self.videoDeviceInput = videoInput;

    [self setMirror:_mirror];
}


// Find a camera with the specified AVCaptureDevicePosition, returning nil if one is not found
- (AVCaptureDevice *)cameraWithPosition:(AVCaptureDevicePosition) position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices) {
        if (device.position == position) return device;
    }
    return nil;
}

#pragma mark - Focus

- (void)previewTapped:(UIGestureRecognizer *)gestureRecognizer
{
    if(!self.tapToFocus) {
        return;
    }
    
    CGPoint touchedPoint = [gestureRecognizer locationInView:self.preview];
    CGPoint pointOfInterest = [self convertToPointOfInterestFromViewCoordinates:touchedPoint
                                                                   previewLayer:self.captureVideoPreviewLayer
                                                                          ports:self.videoDeviceInput.ports];
    [self focusAtPoint:pointOfInterest];
    [self showFocusBox:touchedPoint];
}

- (void)addDefaultFocusBox
{
    CALayer *focusBox = [[CALayer alloc] init];
    focusBox.cornerRadius = 5.0f;
    focusBox.bounds = CGRectMake(0.0f, 0.0f, 70, 60);
    focusBox.borderWidth = 3.0f;
    focusBox.borderColor = [[UIColor yellowColor] CGColor];
    focusBox.opacity = 0.0f;
    [self.view.layer addSublayer:focusBox];
    
    CABasicAnimation *focusBoxAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    focusBoxAnimation.duration = 0.75;
    focusBoxAnimation.autoreverses = NO;
    focusBoxAnimation.repeatCount = 0.0;
    focusBoxAnimation.fromValue = [NSNumber numberWithFloat:1.0];
    focusBoxAnimation.toValue = [NSNumber numberWithFloat:0.0];
    
    [self alterFocusBox:focusBox animation:focusBoxAnimation];
}

- (void)alterFocusBox:(CALayer *)layer animation:(CAAnimation *)animation
{
    self.focusBoxLayer = layer;
    self.focusBoxAnimation = animation;
}

- (void)focusAtPoint:(CGPoint)point
{
    if ([self.videoCaptureDevice isAdjustingFocus] || [self.videoCaptureDevice isAdjustingExposure]) {
        return;
    }
    
    AVCaptureDevice *device = self.videoCaptureDevice;
    if (device.isFocusPointOfInterestSupported && [device isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        NSError *error;
        if ([device lockForConfiguration:&error]) {
            device.focusPointOfInterest = point;
            device.focusMode = AVCaptureFocusModeAutoFocus;
            [device unlockForConfiguration];
        } else {
            [self passError:error];
        }
    }
}

- (void)showFocusBox:(CGPoint)point
{
    if(self.focusBoxLayer) {
        // clear animations
        [self.focusBoxLayer removeAllAnimations];
        
        // move layer to the touch point
        [CATransaction begin];
        [CATransaction setValue: (id) kCFBooleanTrue forKey: kCATransactionDisableActions];
        self.focusBoxLayer.position = point;
        [CATransaction commit];
    }
    
    if(self.focusBoxAnimation) {
        // run the animation
        [self.focusBoxLayer addAnimation:self.focusBoxAnimation forKey:@"animateOpacity"];
    }
}

#pragma mark - UIViewController

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    
    self.preview.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height);
    
    CGRect bounds = self.preview.bounds;
    self.captureVideoPreviewLayer.bounds = bounds;
    self.captureVideoPreviewLayer.position = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    
    self.captureVideoPreviewLayer.connection.videoOrientation = [self orientationForConnection];
}

- (AVCaptureVideoOrientation)orientationForConnection
{
    AVCaptureVideoOrientation videoOrientation = AVCaptureVideoOrientationPortrait;
    
    if(self.useDeviceOrientation) {
        switch ([UIDevice currentDevice].orientation) {
            case UIDeviceOrientationLandscapeLeft:
                // yes to the right, this is not bug!
                videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                break;
            case UIDeviceOrientationLandscapeRight:
                videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                break;
            case UIDeviceOrientationPortraitUpsideDown:
                videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                break;
            default:
                videoOrientation = AVCaptureVideoOrientationPortrait;
                break;
        }
    }
    else {
        switch ([[UIApplication sharedApplication] statusBarOrientation]) {
            case UIInterfaceOrientationLandscapeLeft:
                videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                break;
            case UIInterfaceOrientationLandscapeRight:
                videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                break;
            default:
                videoOrientation = AVCaptureVideoOrientationPortrait;
                break;
        }
    }
    
    return videoOrientation;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
    
    // layout subviews is not called when rotating from landscape right/left to left/right
    if (UIInterfaceOrientationIsLandscape(self.interfaceOrientation) && UIInterfaceOrientationIsLandscape(toInterfaceOrientation)) {
        [self.view setNeedsLayout];
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Class Methods

+ (void)requestCameraPermission:(void (^)(BOOL granted))completionBlock
{
    if ([AVCaptureDevice respondsToSelector:@selector(requestAccessForMediaType: completionHandler:)]) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            // return to main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                if(completionBlock) {
                    completionBlock(granted);
                }
            });
        }];
    } else {
        completionBlock(YES);
    }
}

+ (void)requestMicrophonePermission:(void (^)(BOOL granted))completionBlock
{
    if([[AVAudioSession sharedInstance] respondsToSelector:@selector(requestRecordPermission:)]) {
        [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
            // return to main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                if(completionBlock) {
                    completionBlock(granted);
                }
            });
        }];
    }
}

+ (BOOL)isFrontCameraAvailable
{
    return [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceFront];
}

+ (BOOL)isRearCameraAvailable
{
    return [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceRear];
}

@end
