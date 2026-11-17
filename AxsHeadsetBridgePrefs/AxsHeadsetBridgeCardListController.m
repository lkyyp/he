#import "AxsHeadsetBridgeCardListController.h"
#import "AxsHeadsetBridgeCardPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#include <math.h>

// Reject strings/nonfinite values; store and display whole seconds only.
static NSInteger axs_headsetbridge_card_uiSeconds(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return 5;
    double seconds = [value doubleValue];
    if (!isfinite(seconds)) return 5;
    return (NSInteger)round(fmax(3.0, fmin(50.0, seconds)));
}

@implementation AxsHeadsetBridgeCardListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"AxsHeadsetBridgeCard"
                                                target:self] mutableCopy];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return nil;
    id value = axs_headsetbridge_card_readPreferences()[key];
    if ([key isEqualToString:@"cardSeconds"]) {
        return @(axs_headsetbridge_card_uiSeconds(value));
    }
    if ([key isEqualToString:@"cardEnabled"]) {
        return [value isKindOfClass:[NSNumber class]] ? @([value boolValue]) : @YES;
    }
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"cardSeconds"]) {
        value = @(axs_headsetbridge_card_uiSeconds(value));
    } else if ([key isEqualToString:@"cardEnabled"]) {
        value = [value isKindOfClass:[NSNumber class]] ? @([value boolValue]) : @YES;
    } else {
        return;
    }
    NSError *error = nil;
    if (!axs_headsetbridge_card_writePreference(key, value, &error)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
            message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [self reloadSpecifiers];
    }
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) {
        [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    }
    if ([cell isKindOfClass:[AxsHeadsetBridgeCardSliderCell class]]) {
        AxsHeadsetBridgeCardSliderCell *sliderCell = (AxsHeadsetBridgeCardSliderCell *)cell;
        sliderCell.axs_headsetbridge_card_handler = self;
        [sliderCell axs_headsetbridge_card_reloadState];
    }
}

- (double)axs_headsetbridge_card_sliderValueForSpecifier:(PSSpecifier *)specifier {
    return axs_headsetbridge_card_uiSeconds([self readPreferenceValue:specifier]);
}

- (void)axs_headsetbridge_card_setSliderValue:(double)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:@(axs_headsetbridge_card_uiSeconds(@(value))) specifier:specifier];
}

@end
