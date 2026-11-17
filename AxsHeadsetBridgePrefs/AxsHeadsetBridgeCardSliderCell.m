#import "AxsHeadsetBridgeCardSliderCell.h"
#import <UIKit/UIKit.h>
#include <math.h>

// UISlider's default accessibility step depends on its range; force one second.
@interface AxsHeadsetBridgeCardIntegerSlider : UISlider
@end

@implementation AxsHeadsetBridgeCardIntegerSlider
- (void)accessibilityIncrement {
    self.value = fminf(self.maximumValue, roundf(self.value) + 1.0f);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)accessibilityDecrement {
    self.value = fmaxf(self.minimumValue, roundf(self.value) - 1.0f);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
@end

@interface AxsHeadsetBridgeCardSliderCell ()
@property (nonatomic, strong) AxsHeadsetBridgeCardIntegerSlider *axs_headsetbridge_card_slider;
@property (nonatomic, strong) UILabel *axs_headsetbridge_card_valueLabel;
- (void)axs_headsetbridge_card_updateLabel;
- (void)axs_headsetbridge_card_sliderMoved:(UISlider *)sender;
- (void)axs_headsetbridge_card_sliderCommitted:(UISlider *)sender;
@end

@implementation AxsHeadsetBridgeCardSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier specifier:specifier];
    if (self) {
        _axs_headsetbridge_card_slider = [[AxsHeadsetBridgeCardIntegerSlider alloc] initWithFrame:CGRectZero];
        [_axs_headsetbridge_card_slider addTarget:self
            action:@selector(axs_headsetbridge_card_sliderMoved:)
            forControlEvents:UIControlEventValueChanged];
        [_axs_headsetbridge_card_slider addTarget:self
            action:@selector(axs_headsetbridge_card_sliderCommitted:)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [self.contentView addSubview:_axs_headsetbridge_card_slider];
        _axs_headsetbridge_card_valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _axs_headsetbridge_card_valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        _axs_headsetbridge_card_valueLabel.textColor = [UIColor secondaryLabelColor];
        _axs_headsetbridge_card_valueLabel.textAlignment = NSTextAlignmentRight;
        _axs_headsetbridge_card_valueLabel.adjustsFontSizeToFitWidth = YES;
        _axs_headsetbridge_card_valueLabel.minimumScaleFactor = 0.6;
        _axs_headsetbridge_card_valueLabel.isAccessibilityElement = NO;
        [self.contentView addSubview:_axs_headsetbridge_card_valueLabel];
        self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.textLabel.isAccessibilityElement = NO;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.isAccessibilityElement = NO;
        self.accessibilityElements = @[_axs_headsetbridge_card_slider];
        [self axs_headsetbridge_card_reloadState];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self axs_headsetbridge_card_reloadState];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.axs_headsetbridge_card_handler = nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    CGFloat available = MAX(0.0, width - 32.0);
    CGFloat valueWidth = MIN(58.0, available * 0.25);
    CGFloat titleWidth = MIN(100.0, available * 0.32);
    CGFloat sliderX = 16.0 + titleWidth + 8.0;
    CGFloat valueX = MAX(sliderX, width - 16.0 - valueWidth);
    self.textLabel.frame = CGRectMake(16.0, 0, titleWidth, height);
    self.axs_headsetbridge_card_slider.frame = CGRectMake(sliderX, MAX(0.0, (height - 31.0) / 2.0),
        MAX(0.0, valueX - 8.0 - sliderX), 31.0);
    self.axs_headsetbridge_card_valueLabel.frame = CGRectMake(valueX, 0, valueWidth, height);
}

- (void)axs_headsetbridge_card_reloadState {
    self.textLabel.text = self.specifier.name ?: @"关闭秒数";
    self.axs_headsetbridge_card_slider.accessibilityLabel = self.textLabel.text;
    self.axs_headsetbridge_card_slider.accessibilityHint = @"向上或向下轻扫，每次调整一秒并保存。";
    self.axs_headsetbridge_card_slider.minimumValue = 3.0f;
    self.axs_headsetbridge_card_slider.maximumValue = 50.0f;
    id initial = [self.specifier propertyForKey:@"default"];
    double value = self.axs_headsetbridge_card_handler
        ? [self.axs_headsetbridge_card_handler axs_headsetbridge_card_sliderValueForSpecifier:self.specifier]
        : ([initial isKindOfClass:[NSNumber class]] ? [initial doubleValue] : 5.0);
    if (!isfinite(value)) value = 5.0;
    self.axs_headsetbridge_card_slider.value = (float)round(fmax(3.0, fmin(50.0, value)));
    [self axs_headsetbridge_card_updateLabel];
}

- (void)axs_headsetbridge_card_updateLabel {
    UISlider *slider = self.axs_headsetbridge_card_slider;
    double value = slider.value;
    if (!isfinite(value)) value = 5.0;
    slider.value = (float)round(fmax(3.0, fmin(50.0, value)));
    NSString *text = [NSString stringWithFormat:@"%ld 秒", (long)lroundf(slider.value)];
    self.axs_headsetbridge_card_valueLabel.text = text;
    slider.accessibilityValue = text;
}

- (void)axs_headsetbridge_card_sliderMoved:(UISlider *)sender {
    [self axs_headsetbridge_card_updateLabel];
    // Touch drags only preview. VoiceOver/keyboard adjustments have no touch-up.
    if (!sender.isTracking) {
        [self axs_headsetbridge_card_sliderCommitted:sender];
    }
}

- (void)axs_headsetbridge_card_sliderCommitted:(UISlider *)sender {
    [self axs_headsetbridge_card_updateLabel];
    [self.axs_headsetbridge_card_handler axs_headsetbridge_card_setSliderValue:sender.value
        specifier:self.specifier];
}

@end
