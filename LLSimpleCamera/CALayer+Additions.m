//
//  CALayer+Additions.m
//  LLSimpleCameraExample
//
//  Created by Pavel Sladek on 16/02/2017.
//  Copyright © 2017 Ömer Faruk Gül. All rights reserved.
//

#import "CALayer+Additions.h"

@implementation CALayer (Additions)

- (CABasicAnimation *)resizeFromSize:(CGSize)fromSize
                              toSize:(CGSize)toSize
                            duration:(CFTimeInterval)duration
{
    CGRect oldBounds = CGRectMake(0, 0, fromSize.width, fromSize.height);
    CGRect newBounds = oldBounds;
    newBounds.size = toSize;
    
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"bounds"];

    animation.fromValue = [NSValue valueWithCGRect:oldBounds];
    animation.toValue = [NSValue valueWithCGRect:newBounds];
    
    animation.duration = duration;
    
    return animation;
}

- (CABasicAnimation *)moveTo:(CGPoint)point
                    duration:(CFTimeInterval)duration
{
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"position"];
    animation.fromValue = [self valueForKey:@"position"];
    animation.toValue = [NSValue valueWithCGPoint:point];
    animation.duration = duration;
    
    self.position = point;
    
    return animation;
}

@end
