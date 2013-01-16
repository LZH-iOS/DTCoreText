//
//  TextView.m
//  CoreTextExtensions
//
//  Created by Oliver Drobnik on 1/9/11.
//  Copyright 2011 Drobnik.com. All rights reserved.
//

#import "DTAttributedTextContentView.h"
#import "DTCoreText.h"
#import <QuartzCore/QuartzCore.h>

#if !__has_feature(objc_arc)
#error THIS CODE MUST BE COMPILED WITH ARC ENABLED!
#endif

// Commented code useful to find deadlocks
#define SYNCHRONIZE_START(lock) /* NSLog(@"LOCK: FUNC=%s Line=%d", __func__, __LINE__), */dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define SYNCHRONIZE_END(lock) dispatch_semaphore_signal(lock) /*, NSLog(@"UN-LOCK")*/;

@interface DTAttributedTextContentView ()
{
	BOOL _drawDebugFrames;
	BOOL _shouldDrawImages;
	BOOL _shouldDrawLinks;
	BOOL _shouldLayoutCustomSubviews;
	
	NSMutableSet *customViews;
	NSMutableDictionary *customViewsForLinksIndex;
    
	BOOL _isTiling;
	
	DTCoreTextLayouter *_layouter;
	
	CGPoint _layoutOffset;
    CGSize _backgroundOffset;
	
	// lookup bitmask what delegate methods are implemented
	struct 
	{
		unsigned int delegateSupportsCustomViewsForAttachments:1;
		unsigned int delegateSupportsCustomViewsForLinks:1;
		unsigned int delegateSupportsGenericCustomViews:1;
		unsigned int delegateSupportsNotificationAfterDrawing:1;
		unsigned int delegateSupportsNotificationBeforeTextBoxDrawing:1;
	} _delegateFlags;
	
	__unsafe_unretained id <DTAttributedTextContentViewDelegate> _delegate;
}

@property (nonatomic, strong) NSMutableDictionary *customViewsForLinksIndex;
@property (nonatomic, strong) NSMutableDictionary *customViewsForAttachmentsIndex;

- (void)removeAllCustomViews;
- (void)removeSubviewsOutsideRect:(CGRect)rect;
- (void)removeAllCustomViewsForLinks;

@end

static Class _layerClassToUseForDTAttributedTextContentView = nil;

@implementation DTAttributedTextContentView (Tiling)

+ (void)setLayerClass:(Class)layerClass
{
	_layerClassToUseForDTAttributedTextContentView = layerClass;
}

+ (Class)layerClass
{
	if (_layerClassToUseForDTAttributedTextContentView)
	{
		return _layerClassToUseForDTAttributedTextContentView;
	}
	
	return [CALayer class];
}

@end


@implementation DTAttributedTextContentView
@synthesize selfLock;

- (void)setup
{
	self.contentMode = UIViewContentModeTopLeft; // to avoid bitmap scaling effect on resize
	_shouldLayoutCustomSubviews = YES;
	
	// by default we draw images, if custom views are supported (by setting delegate) this is disabled
	// if you still want images to be drawn together with text then set it back to YES after setting delegate
	_shouldDrawImages = YES;
	
	// by default we draw links. If you don't want that because you want to highlight the text in
	// DTLinkButton set this property to NO and create a highlighted version of the attributed string
	_shouldDrawLinks = YES;
	
	// possibly already set in NIB
	if (!self.backgroundColor)
	{
		self.backgroundColor = [DTColor whiteColor];
	}
	
	// set tile size if applicable
	CATiledLayer *layer = (id)self.layer;
	if ([layer isKindOfClass:[CATiledLayer class]])
	{
		// get larger dimension and multiply by scale
		UIScreen *mainScreen = [UIScreen mainScreen];
		CGFloat largerDimension = MAX(mainScreen.applicationFrame.size.width, mainScreen.applicationFrame.size.height);
		CGFloat scale = mainScreen.scale;
		
		// this way tiles cover entire screen regardless of orientation or scale
		CGSize tileSize = CGSizeMake(largerDimension * scale, largerDimension * scale);
		layer.tileSize = tileSize;
		
		_isTiling = YES;
	}
	
	[self selfLock];
}

- (id)initWithFrame:(CGRect)frame 
{
	if ((self = [super initWithFrame:frame])) 
	{
		[self setup];
	}
	return self;
}

- (id)initWithAttributedString:(NSAttributedString *)attributedString width:(CGFloat)width
{
	self = [self initWithFrame:CGRectMake(0, 0, width, 0)];
	
	if (self)
	{		
		// causes appropriate sizing
		self.attributedString = attributedString;
		[self sizeToFit];
	}
	
	return self;
}

- (void)awakeFromNib
{
	[self setup];
}

- (void)dealloc 
{
	[self removeAllCustomViews];
	
	dispatch_release(selfLock);
}

- (void)layoutSubviewsInRect:(CGRect)rect
{
	// if we are called for partial (non-infinate) we remove unneeded custom subviews first
	if (!CGRectIsInfinite(rect))
	{
		[self removeSubviewsOutsideRect:rect];
	}
	
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	
	DTCoreTextLayoutFrame *theLayoutFrame = self.layoutFrame;
	
	SYNCHRONIZE_START(selfLock)
	{
		NSAttributedString *layoutString = [theLayoutFrame attributedStringFragment];
		NSArray *lines;
		if (CGRectIsInfinite(rect))
		{
			lines = [theLayoutFrame lines];
		}
		else
		{
			lines = [theLayoutFrame linesVisibleInRect:rect];
		}
		
		// hide all customViews
		for (UIView *view in self.customViews)
		{
			view.hidden = YES;
		}
		
		for (DTCoreTextLayoutLine *oneLine in lines)
		{
			NSRange lineRange = [oneLine stringRange];
			
			NSUInteger skipRunsBeforeLocation = 0;
			
			for (DTCoreTextGlyphRun *oneRun in oneLine.glyphRuns)
			{
				// add custom views if necessary
				NSRange runRange = [oneRun stringRange];
				CGRect frameForSubview = CGRectZero;
				
				if (runRange.location>=skipRunsBeforeLocation)
				{
					// see if it's a link
					NSRange effectiveRangeOfLink;
					NSRange effectiveRangeOfAttachment;
					
					// make sure that a link is only as long as the area to the next attachment or the current attachment itself
					DTTextAttachment *attachment = [layoutString attribute:NSAttachmentAttributeName atIndex:runRange.location longestEffectiveRange:&effectiveRangeOfAttachment inRange:lineRange];
					
					// if there is no attachment then the effectiveRangeOfAttachment contains the range until the next attachment
					NSURL *linkURL = [layoutString attribute:DTLinkAttribute atIndex:runRange.location longestEffectiveRange:&effectiveRangeOfLink inRange:effectiveRangeOfAttachment];
					
					// avoid chaining together glyph runs for an attachment
					if (linkURL && !attachment)
					{
						// compute bounding frame over potentially multiple (chinese) glyphs
						skipRunsBeforeLocation = effectiveRangeOfLink.location+effectiveRangeOfLink.length;
						
						// make one link view for all glyphruns in this line
						frameForSubview = [oneLine frameOfGlyphsWithRange:effectiveRangeOfLink];
						runRange = effectiveRangeOfLink;
					}
					else
					{
						// individual glyph run
						
						if (attachment)
						{
							// frame might be different due to image vertical alignment
							CGFloat ascender = [attachment ascentForLayout];
							CGFloat descender = [attachment descentForLayout];
							
							frameForSubview = CGRectMake(oneRun.frame.origin.x, oneLine.baselineOrigin.y - ascender, oneRun.frame.size.width, ascender+descender);
						}
						else 
						{
							frameForSubview = oneRun.frame;
						}
					}
					
					if (CGRectIsEmpty(frameForSubview))
					{
						continue;
					}
					
					NSNumber *indexKey = [NSNumber numberWithInteger:runRange.location];
					
					// offset layout if necessary
					if (!CGPointEqualToPoint(_layoutOffset, CGPointZero))
					{
						frameForSubview.origin.x += _layoutOffset.x;
						frameForSubview.origin.y += _layoutOffset.y;
					}
					
					// round frame
					frameForSubview.origin.x = floorf(frameForSubview.origin.x);
					frameForSubview.origin.y = ceilf(frameForSubview.origin.y);
					frameForSubview.size.width = roundf(frameForSubview.size.width);
					frameForSubview.size.height = roundf(frameForSubview.size.height);
					
					
					if (CGRectGetMinY(frameForSubview)> CGRectGetMaxY(rect) || CGRectGetMaxY(frameForSubview) < CGRectGetMinY(rect))
					{
						// is still outside even though the bounds of the line already intersect visible area
						continue;
					}
					
					if (_delegateFlags.delegateSupportsCustomViewsForAttachments || _delegateFlags.delegateSupportsGenericCustomViews)
					{
						if (attachment)
						{
							indexKey = [NSNumber numberWithInteger:[attachment hash]];
							
							UIView *existingAttachmentView = [self.customViewsForAttachmentsIndex objectForKey:indexKey];
							
							if (existingAttachmentView)
							{
								existingAttachmentView.hidden = NO;
								existingAttachmentView.frame = frameForSubview;
								
								existingAttachmentView.alpha = 1;
								[existingAttachmentView setNeedsLayout];
								[existingAttachmentView setNeedsDisplay];
								
								linkURL = nil; // prevent adding link button on top of image view
							}
							else
							{
								UIView *newCustomAttachmentView = nil;
								
								
								if (_delegateFlags.delegateSupportsCustomViewsForAttachments)
								{
									newCustomAttachmentView = [_delegate attributedTextContentView:self viewForAttachment:attachment frame:frameForSubview];
								}
								else if (_delegateFlags.delegateSupportsGenericCustomViews)
								{
									NSAttributedString *string = [layoutString attributedSubstringFromRange:runRange]; 
									newCustomAttachmentView = [_delegate attributedTextContentView:self viewForAttributedString:string frame:frameForSubview];
								}
								
								if (newCustomAttachmentView)
								{
									// delegate responsible to set frame
									if (newCustomAttachmentView)
									{
										newCustomAttachmentView.tag = [indexKey integerValue];
										[self addSubview:newCustomAttachmentView];
										
										[self.customViews addObject:newCustomAttachmentView];
										[self.customViewsForAttachmentsIndex setObject:newCustomAttachmentView forKey:indexKey];
										
										linkURL = nil; // prevent adding link button on top of image view
									}
								}
							}
						}
					}
					
					
					if (linkURL && (_delegateFlags.delegateSupportsCustomViewsForLinks || _delegateFlags.delegateSupportsGenericCustomViews))
					{
						UIView *existingLinkView = [self.customViewsForLinksIndex objectForKey:indexKey];
						
						if (existingLinkView)
						{						
							existingLinkView.frame = frameForSubview;
							existingLinkView.hidden = NO;
						}
						else
						{
							UIView *newCustomLinkView = nil;
							
							if (_delegateFlags.delegateSupportsCustomViewsForLinks)
							{
								NSDictionary *attributes = [layoutString attributesAtIndex:runRange.location effectiveRange:NULL];
								
								NSString *guid = [attributes objectForKey:DTGUIDAttribute];
								newCustomLinkView = [_delegate attributedTextContentView:self viewForLink:linkURL identifier:guid frame:frameForSubview];
							}
							else if (_delegateFlags.delegateSupportsGenericCustomViews)
							{
								NSAttributedString *string = [layoutString attributedSubstringFromRange:runRange]; 
								newCustomLinkView = [_delegate attributedTextContentView:self viewForAttributedString:string frame:frameForSubview];
							}
							
							// delegate responsible to set frame
							if (newCustomLinkView)
							{
								newCustomLinkView.tag = runRange.location;
								[self addSubview:newCustomLinkView];
								
								[self.customViews addObject:newCustomLinkView];
								[self.customViewsForLinksIndex setObject:newCustomLinkView forKey:indexKey];
							}
						}
					}
				}
			}
		}
		
		[CATransaction commit];
	}
	SYNCHRONIZE_END(selfLock)
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	
	if (_shouldLayoutCustomSubviews)
	{
		[self layoutSubviewsInRect:CGRectInfinite];
	}
}

- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)ctx
{
	// needs clearing of background
	CGRect rect = CGContextGetClipBoundingBox(ctx);
	
	if (_backgroundOffset.height || _backgroundOffset.width)
	{
		CGContextSetPatternPhase(ctx, _backgroundOffset);
	}
	
	CGContextSetFillColorWithColor(ctx, [self.backgroundColor CGColor]);
	CGContextFillRect(ctx, rect);
	
	// offset layout if necessary
	if (!CGPointEqualToPoint(_layoutOffset, CGPointZero))
	{
		CGAffineTransform transform = CGAffineTransformMakeTranslation(_layoutOffset.x, _layoutOffset.y);
		CGContextConcatCTM(ctx, transform);
	}
	
	DTCoreTextLayoutFrame *theLayoutFrame = self.layoutFrame;
	
	// need to prevent updating of string and drawing at the same time
	SYNCHRONIZE_START(selfLock)
	{
		[theLayoutFrame drawInContext:ctx drawImages:_shouldDrawImages drawLinks:_shouldDrawLinks];
		
		if (_delegateFlags.delegateSupportsNotificationAfterDrawing)
		{
			[_delegate attributedTextContentView:self didDrawLayoutFrame:theLayoutFrame inContext:ctx];
		}
	}
	SYNCHRONIZE_END(selfLock)
}

- (void)drawRect:(CGRect)rect
{
	CGContextRef context = UIGraphicsGetCurrentContext();
	[self.layoutFrame drawInContext:context drawImages:YES drawLinks:YES];
}

- (CGSize)sizeThatFits:(CGSize)size
{
	if (size.width==0)
	{
		size.width = self.bounds.size.width;
	}
	
	CGSize neededSize = CGSizeMake(size.width, CGRectGetMaxY(self.layoutFrame.frame) + _edgeInsets.bottom);
	
	return neededSize;
}

- (CGSize)suggestedFrameSizeToFitEntireStringConstraintedToWidth:(CGFloat)width
{
	if (!isnormal(width))
	{
		width = self.bounds.size.width;
	}
	
	CGSize neededSize = [self.layouter suggestedFrameSizeToFitEntireStringConstraintedToWidth:width-_edgeInsets.left-_edgeInsets.right];
	
	// add vertical insets
	neededSize.height += _edgeInsets.top + _edgeInsets.bottom;
	
	return neededSize;
}

- (CGSize)attributedStringSizeThatFits:(CGFloat)width
{
	if (!isnormal(width))
	{
		width = self.bounds.size.width;
	}
	
	// attributedStringSizeThatFits: returns an unreliable measure prior to 4.2 for very long documents.
	CGSize neededSize = [self.layouter suggestedFrameSizeToFitEntireStringConstraintedToWidth:width-_edgeInsets.left-_edgeInsets.right];
	return neededSize;
}


- (NSString *)description
{
	NSString *extract = [[[_layoutFrame attributedStringFragment] string] substringFromIndex:[self.layoutFrame visibleStringRange].location];
	
	if ([extract length]>10)
	{
		extract = [extract substringToIndex:10];
	}
	
	return [NSString stringWithFormat:@"<%@ %@ range:%@ '%@...'>", [self class], NSStringFromCGRect(self.frame),NSStringFromRange([self.layoutFrame visibleStringRange]), extract];
}

- (void)relayoutText
{
    // Make sure we actually have a superview before attempting to relayout the text.
    if (self.superview) {
        // need new layouter
        self.layouter = nil;
        self.layoutFrame = nil;
        
        // remove all links because they might have merged or split
        [self removeAllCustomViewsForLinks];
        
        if (_attributedString)
        {
            // triggers new layout
            CGSize neededSize = [self sizeThatFits:self.bounds.size];
            
            // set frame to fit text preserving origin
            // call super to avoid endless loop
            [self willChangeValueForKey:@"frame"];
            super.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, neededSize.width, neededSize.height);
            [self didChangeValueForKey:@"frame"];
        }
        
        [self setNeedsDisplay];
        [self setNeedsLayout];
    }
}

- (void)removeAllCustomViewsForLinks
{
	NSArray *linkViews = [customViewsForLinksIndex allValues];
	
	for (UIView *customView in linkViews)
	{
		[customView removeFromSuperview];
		[customViews removeObject:customView];
	}
	
	[customViewsForLinksIndex removeAllObjects];
}

- (void)removeAllCustomViews
{
	NSSet *allCustomViews = [NSSet setWithSet:customViews];
	for (UIView *customView in allCustomViews)
	{
		[customView removeFromSuperview];
		[customViews removeObject:customView];
	}
	
	[customViewsForAttachmentsIndex removeAllObjects];
	[customViewsForLinksIndex removeAllObjects];
}

- (void)removeSubviewsOutsideRect:(CGRect)rect
{
	NSSet *allCustomViews = [NSSet setWithSet:customViews];
	for (UIView *customView in allCustomViews)
	{
		if (CGRectGetMinY(customView.frame)> CGRectGetMaxY(rect) || CGRectGetMaxY(customView.frame) < CGRectGetMinY(rect))
		{
			NSNumber *indexKey = [NSNumber numberWithInteger:customView.tag];
			
			[customView removeFromSuperview];
			[customViews removeObject:customView];
			
			[customViewsForAttachmentsIndex removeObjectForKey:indexKey];
			[customViewsForLinksIndex removeObjectForKey:indexKey];
		}
	}
}

#pragma mark Properties
- (void)setEdgeInsets:(UIEdgeInsets)edgeInsets
{
	if (!UIEdgeInsetsEqualToEdgeInsets(edgeInsets, _edgeInsets))
	{
		_edgeInsets = edgeInsets;
		
		[self relayoutText];
	}
}

- (void)setAttributedString:(NSAttributedString *)string
{
	if (_attributedString != string)
	{
		
		_attributedString = [string copy];
		
		// new layout invalidates all positions for custom views
		[self removeAllCustomViews];
		
		[self relayoutText];
	}
}

- (void)setFrame:(CGRect)frame //relayoutText:(BOOL)relayoutText
{
	CGRect oldFrame = self.frame;
	
	[super setFrame:frame];
	
	if (!_layoutFrame) 
	{
		return;	
	}

	// having a layouter means we are responsible for layouting yourselves
	// relayout only if frame size has been changed
	if (!CGSizeEqualToSize(oldFrame.size, frame.size))
	{
		[self relayoutText];
	}
}

//- (void)setFrame:(CGRect)frame
//{
//	// sizeToFit also calls this, but we want to be able to avoid relayouting
//	[self setFrame:frame relayoutText:_relayoutTextOnFrameChange];
//}

- (void)setDrawDebugFrames:(BOOL)drawDebugFrames
{
	if (_drawDebugFrames != drawDebugFrames)
	{
		_drawDebugFrames = drawDebugFrames;
		
		[self setNeedsDisplay];
	}
}

- (void)setShouldDrawImages:(BOOL)shouldDrawImages
{
	if (_shouldDrawImages != shouldDrawImages)
	{
		_shouldDrawImages = shouldDrawImages;
		
		[self setNeedsDisplay];
	}
}

- (void)setBackgroundColor:(DTColor *)newColor
{
	super.backgroundColor = newColor;
	
	if ([newColor alphaComponent]<1.0)
	{
		self.opaque = NO;
	}
	else 
	{
		self.opaque = YES;
	}
}


- (DTCoreTextLayouter *)layouter
{
	SYNCHRONIZE_START(selfLock)
	{
		if (!_layouter)
		{
			if (_attributedString)
			{
				_layouter = [[DTCoreTextLayouter alloc] initWithAttributedString:_attributedString];
			}
		}
	}
	SYNCHRONIZE_END(selfLock)
	
	return _layouter;
}

- (void)setLayouter:(DTCoreTextLayouter *)layouter
{
	SYNCHRONIZE_START(selfLock)
	{
		if (_layouter != layouter)
		{
			_layouter = layouter;
		}
	}
	SYNCHRONIZE_END(selfLock)
}

- (DTCoreTextLayoutFrame *)layoutFrame
{
	DTCoreTextLayouter *theLayouter = self.layouter;
	
	if (!_layoutFrame)
	{
		// prevent unnecessary locking if we don't need to create new layout frame
		SYNCHRONIZE_START(selfLock)
		{
			// Test again - small window where another thread could have been setting this value
			if (!_layoutFrame)
			{
				// we can only layout if we have our own layouter
				if (theLayouter)
				{
					CGRect rect = UIEdgeInsetsInsetRect(self.bounds, _edgeInsets);
					rect.size.height = CGFLOAT_OPEN_HEIGHT; // necessary height set as soon as we know it.
					
					_layoutFrame = [theLayouter layoutFrameWithRect:rect range:NSMakeRange(0, 0)];
					
					if (_delegateFlags.delegateSupportsNotificationBeforeTextBoxDrawing)
					{
						__unsafe_unretained DTAttributedTextContentView *weakself = self;
						
						[_layoutFrame setTextBlockHandler:^(DTTextBlock *textBlock, CGRect frame, CGContextRef context, BOOL *shouldDrawDefaultBackground) {
							BOOL result = [weakself->_delegate attributedTextContentView:weakself shouldDrawBackgroundForTextBlock:textBlock frame:frame context:context forLayoutFrame:weakself->_layoutFrame];
							
							if (shouldDrawDefaultBackground)
							{
								*shouldDrawDefaultBackground = result;
							}
							
						}];
					}
				}
			}
		}
		SYNCHRONIZE_END(selfLock)
	}
	
	return _layoutFrame;
}

- (void)setLayoutFrame:(DTCoreTextLayoutFrame *)layoutFrame
{
	SYNCHRONIZE_START(selfLock)
	{
		if (_layoutFrame != layoutFrame)
		{
			[self removeAllCustomViewsForLinks];
			
			if (layoutFrame)
			{
				[self setNeedsLayout];
				[self setNeedsDisplay];
			}
			_layoutFrame = layoutFrame;
		}
	}
	SYNCHRONIZE_END(selfLock)
}

- (NSMutableSet *)customViews
{
	if (!customViews)
	{
		customViews = [[NSMutableSet alloc] init];
	}
	
	return customViews;
}

- (NSMutableDictionary *)customViewsForLinksIndex
{
	if (!customViewsForLinksIndex)
	{
		customViewsForLinksIndex = [[NSMutableDictionary alloc] init];
	}
	
	return customViewsForLinksIndex;
}

- (NSMutableDictionary *)customViewsForAttachmentsIndex
{
	if (!customViewsForAttachmentsIndex)
	{
		customViewsForAttachmentsIndex = [[NSMutableDictionary alloc] init];
	}
	
	return customViewsForAttachmentsIndex;
}

- (void)setDelegate:(id<DTAttributedTextContentViewDelegate>)delegate
{
	_delegate = delegate;
	
	_delegateFlags.delegateSupportsCustomViewsForAttachments = [_delegate respondsToSelector:@selector(attributedTextContentView:viewForAttachment:frame:)];
	_delegateFlags.delegateSupportsCustomViewsForLinks = [_delegate respondsToSelector:@selector(attributedTextContentView:viewForLink:identifier:frame:)];
	_delegateFlags.delegateSupportsGenericCustomViews = [_delegate respondsToSelector:@selector(attributedTextContentView:viewForAttributedString:frame:)];
	_delegateFlags.delegateSupportsNotificationAfterDrawing = [_delegate respondsToSelector:@selector(attributedTextContentView:didDrawLayoutFrame:inContext:)];
	_delegateFlags.delegateSupportsNotificationBeforeTextBoxDrawing = [_delegate respondsToSelector:@selector(attributedTextContentView:shouldDrawBackgroundForTextBlock:frame:context:forLayoutFrame:)];
	
	if (!_delegateFlags.delegateSupportsCustomViewsForLinks && !_delegateFlags.delegateSupportsGenericCustomViews)
	{
		[self removeAllCustomViewsForLinks];
	}
	
	// we don't draw the images if imageViews are provided by the delegate method
	// if you want images to be drawn even though you use custom views, set it back to YES after setting delegate
	if (_delegateFlags.delegateSupportsGenericCustomViews || _delegateFlags.delegateSupportsCustomViewsForAttachments)
	{
		_shouldDrawImages = NO;
	}
	else
	{
		_shouldDrawImages = YES;
	}
}


- (dispatch_semaphore_t)selfLock
{
	if (!selfLock)
	{
		selfLock = dispatch_semaphore_create(1);
	}
	
	return selfLock;
}


@synthesize layouter = _layouter;
@synthesize layoutFrame = _layoutFrame;
@synthesize attributedString = _attributedString;
@synthesize delegate = _delegate;
@synthesize edgeInsets = _edgeInsets;
@synthesize drawDebugFrames = _drawDebugFrames;
@synthesize shouldDrawImages = _shouldDrawImages;
@synthesize shouldDrawLinks = _shouldDrawLinks;
@synthesize shouldLayoutCustomSubviews = _shouldLayoutCustomSubviews;
@synthesize layoutOffset = _layoutOffset;
@synthesize backgroundOffset = _backgroundOffset;

@synthesize customViews;
@synthesize customViewsForLinksIndex;
@synthesize customViewsForAttachmentsIndex;

@end
