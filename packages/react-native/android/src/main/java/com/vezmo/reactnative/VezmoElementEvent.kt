package com.vezmo.reactnative

import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.events.Event

/** Any of the methods view's events (`topLoaded`, `topPaymentMethod`, …) with its payload. */
class VezmoElementEvent(
  surfaceId: Int,
  viewId: Int,
  private val name: String,
  private val payload: WritableMap,
) : Event<VezmoElementEvent>(surfaceId, viewId) {
  override fun getEventName(): String = name

  override fun getEventData(): WritableMap = payload
}
