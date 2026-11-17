#pragma once

#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>

@protocol AxsHeadsetBridgeCardSliderCellHandler <NSObject>
- (double)axs_headsetbridge_card_sliderValueForSpecifier:(PSSpecifier *)specifier;
- (void)axs_headsetbridge_card_setSliderValue:(double)value specifier:(PSSpecifier *)specifier;
@end

@interface AxsHeadsetBridgeCardSliderCell : PSTableCell
@property (nonatomic, weak) id<AxsHeadsetBridgeCardSliderCellHandler> axs_headsetbridge_card_handler;
- (void)axs_headsetbridge_card_reloadState;
@end
