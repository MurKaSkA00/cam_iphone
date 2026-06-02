#import <Preferences/PSListController.h>

@interface MPURootListController : PSListController
@end

@implementation MPURootListController
- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}
@end
