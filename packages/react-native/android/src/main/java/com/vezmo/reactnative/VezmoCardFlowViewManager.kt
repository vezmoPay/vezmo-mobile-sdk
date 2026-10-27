package com.vezmo.reactnative

import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.VezmoCardFlowViewManagerDelegate
import com.facebook.react.viewmanagers.VezmoCardFlowViewManagerInterface

@ReactModule(name = VezmoCardFlowViewManager.NAME)
class VezmoCardFlowViewManager :
  SimpleViewManager<VezmoCardFlowView>(),
  VezmoCardFlowViewManagerInterface<VezmoCardFlowView> {
  private val delegate: ViewManagerDelegate<VezmoCardFlowView> = VezmoCardFlowViewManagerDelegate(this)

  override fun getDelegate(): ViewManagerDelegate<VezmoCardFlowView> = delegate

  override fun getName(): String = NAME

  override fun createViewInstance(context: ThemedReactContext): VezmoCardFlowView = VezmoCardFlowView(context)

  @ReactProp(name = "configJson")
  override fun setConfigJson(
    view: VezmoCardFlowView,
    value: String?,
  ) {
    view.setConfigJson(value)
  }

  @ReactProp(name = "intentJson")
  override fun setIntentJson(
    view: VezmoCardFlowView,
    value: String?,
  ) {
    view.setIntentJson(value)
  }

  override fun onDropViewInstance(view: VezmoCardFlowView) {
    view.dispose()
    super.onDropViewInstance(view)
  }

  override fun onAfterUpdateTransaction(view: VezmoCardFlowView) {
    super.onAfterUpdateTransaction(view)
    view.commit()
  }

  override fun presentCard(view: VezmoCardFlowView) {
    view.presentCard()
  }

  override fun confirmCard(view: VezmoCardFlowView) {
    view.confirmCard()
  }

  override fun presentBank(view: VezmoCardFlowView) {
    view.presentBank()
  }

  override fun confirmBank(view: VezmoCardFlowView) {
    view.confirmBank()
  }

  override fun resolveConfirmation(
    view: VezmoCardFlowView,
    clientSecret: String,
    errorMessage: String,
  ) {
    view.resolveConfirmation(clientSecret, errorMessage)
  }

  // Android brings the buyer back from a bank app or a pay-later provider by itself.
  override fun handleURL(
    view: VezmoCardFlowView,
    url: String,
  ) = Unit

  override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> =
    mutableMapOf(
      "topLoaded" to mapOf("registrationName" to "onLoaded"),
      "topLoadFailed" to mapOf("registrationName" to "onLoadFailed"),
      "topHeightChange" to mapOf("registrationName" to "onHeightChange"),
      "topCardOptionChange" to mapOf("registrationName" to "onCardOptionChange"),
      "topBankChange" to mapOf("registrationName" to "onBankChange"),
      "topWalletTap" to mapOf("registrationName" to "onWalletTap"),
      "topPaymentMethod" to mapOf("registrationName" to "onPaymentMethod"),
      "topConfirmResult" to mapOf("registrationName" to "onConfirmResult"),
    )

  companion object {
    const val NAME = "VezmoCardFlowView"
  }
}
