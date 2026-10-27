#import "VezmoMethodsView.h"

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

static std::string VZString(id value)
{
  return [value isKindOfClass:[NSString class]] ? std::string([(NSString *)value UTF8String]) : std::string();
}

@interface VezmoMethodsView () <RCTVezmoMethodsViewViewProtocol>
@end

@implementation VezmoMethodsView {
  VezmoMethodsHost *_host;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<VezmoMethodsViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const VezmoMethodsViewProps>();
    _props = defaultProps;

    _host = [[VezmoMethodsHost alloc] initWithFrame:frame];
    __weak VezmoMethodsView *weakSelf = self;
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
  auto emitter = std::static_pointer_cast<const VezmoMethodsViewEventEmitter>(_eventEmitter);
  if ([name isEqualToString:@"loaded"]) {
    emitter->onLoaded({.ok = true});
  } else if ([name isEqualToString:@"loadFailed"]) {
    emitter->onLoadFailed({.message = VZString(body[@"message"])});
  } else if ([name isEqualToString:@"height"]) {
    emitter->onHeightChange({.height = [body[@"height"] doubleValue]});
  } else if ([name isEqualToString:@"paymentOption"]) {
    emitter->onPaymentOptionChange(
        {.paymentMethodType = VZString(body[@"paymentMethodType"]), .label = VZString(body[@"label"])});
  } else if ([name isEqualToString:@"paymentMethod"]) {
    emitter->onPaymentMethod({.id = VZString(body[@"id"])});
  } else if ([name isEqualToString:@"confirmResult"]) {
    emitter->onConfirmResult({.status = VZString(body[@"status"]), .message = VZString(body[@"message"])});
  }
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &oldViewProps = *std::static_pointer_cast<VezmoMethodsViewProps const>(_props);
  const auto &newViewProps = *std::static_pointer_cast<VezmoMethodsViewProps const>(props);

  if (oldViewProps.configJson != newViewProps.configJson || oldViewProps.intentJson != newViewProps.intentJson) {
    [_host setConfigJson:[NSString stringWithUTF8String:newViewProps.configJson.c_str()]
              intentJson:[NSString stringWithUTF8String:newViewProps.intentJson.c_str()]];
  }

  [super updateProps:props oldProps:oldProps];
}

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args
{
  RCTVezmoMethodsViewHandleCommand(self, commandName, args);
}

- (void)confirm
{
  [_host confirm];
}

- (void)resolveConfirmation:(NSString *)clientSecret errorMessage:(NSString *)errorMessage
{
  [_host resolveConfirmationWithClientSecret:clientSecret errorMessage:errorMessage];
}

- (void)clearSelection
{
  [_host clearSelection];
}

@end

Class<RCTComponentViewProtocol> VezmoMethodsViewCls(void)
{
  return VezmoMethodsView.class;
}
