//
//  CALayer+Additions.h
//  LLSimpleCameraExample
//
//  Created by Pavel Sladek on 16/02/2017.
//  Copyright © 2017 Ömer Faruk Gül. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface CALayer (Additions)

- (CABasicAnimation *)resizeFromSize:(CGSize)fromSize
                              toSize:(CGSize)toSize
                            duration:(CFTimeInterval)duration;

- (CABasicAnimation *)moveTo:(CGPoint)point
                    duration:(CFTimeInterval)duration;

@end
