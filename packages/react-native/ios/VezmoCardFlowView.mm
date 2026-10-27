#import "VezmoCardFlowView.h"

#import <react/renderer/components/VezmoReactNativeSpec/ComponentDescriptors.h>
#import <react/renderer/components/VezmoReactNativeSpec/EventEmitters.h>
#import <react/renderer/components/VezmoReactNativeSpec/Props.h>
#import <react/renderer/components/VezmoReactNativeSpec/RCTComponentViewHelpers.h>

#import "RCTFabricComponentsPlugins.h"

#if __has_include(<VezmoReactNative/VezmoReactNative-Swift.h>)
#import <VezmoReactNative/VezmoReactNative-Swift.h>
#else
#import "VezmoReactNative-Swift.h"
#endif

using namespace facebook::react;

static std::string VZCardString(id value)
{
  return [value isKindOfClass:[NSString class]] ? std::string([(NSString *)value UTF8String]) : std::string();
}

@interface VezmoCardFlowView () <RCTVezmoCardFlowViewViewProtocol>
@end

@implementation VezmoCardFlowView {
  VezmoCardFlowHost *_host;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<VezmoCardFlowViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const VezmoCardFlowViewProps>();
    _props = defaultProps;

    _host = [[VezmoCardFlowHost alloc] initWithFrame:frame];
    __weak VezmoCardFlowView *weakSelf = self;
    _host.onEvent = ^(NSString *name, NSDictionary *body) {
      [weakSelf emit:name body:body];
    };
    self.contentView = _host;
  }
  return self;
}

- (void)emit:(NSString *)name body:(NSDictionary *)body
{
  if (!_eventEmitter) {
    return;
  }
  auto emitter = std::static_pointer_cast<const VezmoCardFlowViewEventEmitter>(_eventEmitter);
  if ([name isEqualToString:@"loaded"]) {
    emitter->onLoaded({.ok = true});
  } else if ([name isEqualToString:@"loadFailed"]) {
    emitter->onLoadFailed({.message = VZCardString(body[@"message"])});
  } else if ([name isEqualToString:@"height"]) {
    emitter->onHeightChange({.height = [body[@"height"] doubleValue]});
  } else if ([name isEqualToString:@"cardOption"]) {
    emitter->onCardOptionChange({.label = VZCardString(body[@"label"]), .image = VZCardString(body[@"image"])});
  } else if ([name isEqualToString:@"bankChange"]) {
    emitter->onBankChange({.available = [body[@"available"] boolValue], .label = VZCardString(body[@"label"])});
  } else if ([name isEqualToString:@"walletTap"]) {
    emitter->onWalletTap({.wallet = VZCardString(body[@"wallet"])});
  } else if ([name isEqualToString:@"paymentMethod"]) {
    emitter->onPaymentMethod({.id = VZCardString(body[@"id"])});
  } else if ([name isEqualToString:@"confirmResult"]) {
    emitter->onConfirmResult({.status = VZCardString(body[@"status"]), .message = VZCardString(body[@"message"])});
  }
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &oldViewProps = *std::static_pointer_cast<VezmoCardFlowViewProps const>(_props);
  const auto &newViewProps = *std::static_pointer_cast<VezmoCardFlowViewProps const>(props);

  if (oldViewProps.configJson != newViewProps.configJson || oldViewProps.intentJson != newViewProps.intentJson) {
    [_host setConfigJson:[NSString stringWithUTF8String:newViewProps.configJson.c_str()]
              intentJson:[NSString stringWithUTF8String:newViewProps.intentJson.c_str()]];
  }

  [super updateProps:props oldProps:oldProps];
}

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args
{
  RCTVezmoCardFlowViewHandleCommand(self, commandName, args);
}

- (void)presentCard
{
  [_host presentCard];
}

- (void)confirmCard
{
  [_host confirmCard];
}

- (void)presentBank
{
  [_host presentBank];
}

- (void)confirmBank
{
  [_host confirmBank];
}

- (void)resolveConfirmation:(NSString *)clientSecret errorMessage:(NSString *)errorMessage
{
  [_host resolveConfirmationWithClientSecret:clientSecret errorMessage:errorMessage];
}

- (void)handleURL:(NSString *)url
{
  [_host handleURL:url];
}

@end

Class<RCTComponentViewProtocol> VezmoCardFlowViewCls(void)
{
  return VezmoCardFlowView.class;
}
