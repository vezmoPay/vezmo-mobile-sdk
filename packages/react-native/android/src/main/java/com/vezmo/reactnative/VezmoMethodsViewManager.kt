package com.vezmo.reactnative

import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.VezmoMethodsViewManagerDelegate
import com.facebook.react.viewmanagers.VezmoMethodsViewManagerInterface

@ReactModule(name = VezmoMethodsViewManager.NAME)
class VezmoMethodsViewManager :
  SimpleViewManager<VezmoMethodsView>(),
  VezmoMethodsViewManagerInterface<VezmoMethodsView> {
  private val delegate: ViewManagerDelegate<VezmoMethodsView> = VezmoMethodsViewManagerDelegate(this)

  override fun getDelegate(): ViewManagerDelegate<VezmoMethodsView> = delegate

  override fun getName(): String = NAME

  override fun createViewInstance(context: ThemedReactContext): VezmoMethodsView = VezmoMethodsView(context)

  @ReactProp(name = "configJson")
  override fun setConfigJson(
    view: VezmoMethodsView,
    value: String?,
  ) {
    view.setConfigJson(value)
  }

  @ReactProp(name = "intentJson")
  override fun setIntentJson(
    view: VezmoMethodsView,
    value: String?,
  ) {
    view.setIntentJson(value)
  }

  override fun onDropViewInstance(view: VezmoMethodsView) {
    view.dispose()
    super.onDropViewInstance(view)
  }

  override fun onAfterUpdateTransaction(view: VezmoMethodsView) {
    super.onAfterUpdateTransaction(view)
    view.commit()
  }

  override fun confirm(view: VezmoMethodsView) {
    view.confirm()
  }

  override fun clearSelection(view: VezmoMethodsView) {
    view.clearSelection()
  }

  override fun resolveConfirmation(
    view: VezmoMethodsView,
    clientSecret: String,
    errorMessage: String,
  ) {
    view.resolveConfirmation(clientSecret, errorMessage)
  }

  override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> =
    mutableMapOf(
      "topLoaded" to mapOf("registrationName" to "onLoaded"),
      "topLoadFailed" to mapOf("registrationName" to "onLoadFailed"),
      "topHeightChange" to mapOf("registrationName" to "onHeightChange"),
      "topPaymentOptionChange" to mapOf("registrationName" to "onPaymentOptionChange"),
      "topPaymentMethod" to mapOf("registrationName" to "onPaymentMethod"),
      "topConfirmResult" to mapOf("registrationName" to "onConfirmResult"),
    )

  companion object {
    const val NAME = "VezmoMethodsView"
  }
}
