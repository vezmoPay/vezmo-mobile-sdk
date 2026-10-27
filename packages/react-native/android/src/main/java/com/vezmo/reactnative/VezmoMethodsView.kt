package com.vezmo.reactnative

import android.annotation.SuppressLint
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.UIManagerHelper
import com.stripe.android.PaymentConfiguration
import com.stripe.android.paymentelement.EmbeddedPaymentElement
import com.stripe.android.paymentelement.rememberEmbeddedPaymentElement
import com.stripe.android.paymentsheet.CreateIntentCallback
import com.stripe.android.paymentsheet.CreateIntentResult
import com.stripe.android.paymentsheet.PaymentSheet
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.consumeAsFlow
import org.json.JSONObject

/**
 * The Vezmo methods view on Android: the processor's native embedded element in Compose for the methods with rows
 * of their own (pay-later, Cash App…), configured from JSON the JS layer builds and confirmed through Vezmo's server.
 * Cards and wallets are the card flow's ([VezmoCardFlowView]); with no other method the element is left unconfigured.
 *
 * Payment flow: the buyer picks a method and taps Pay → [confirm] → the element creates a payment method and calls
 * our callback → we hand its id to JS (`onPaymentMethod`) → JS sends it to Vezmo's API, which prices and
 * confirms the payment → JS answers with the intent's client secret ([resolveConfirmation]) → the element finishes
 * any step left (3D Secure, Google Pay, a provider) and reports `onConfirmResult`.
 *
 * Hosted in the app's own window (the Vezmo sheet is an overlay, not a separate dialog), so Compose finds the
 * activity's lifecycle and saved state through the view tree.
 */
@SuppressLint("ViewConstructor")
class VezmoMethodsView(
  private val reactContext: ThemedReactContext,
) : FrameLayout(reactContext) {
  /** What the element is set up with. */
  private data class Setup(
    val configuration: EmbeddedPaymentElement.Configuration,
    val intent: PaymentSheet.IntentConfiguration,
    /** The element has rows to draw; with none it is left unconfigured (an empty list would show every method). */
    val rows: Boolean,
  )

  private sealed interface Command {
    data class Configure(
      val setup: Setup,
    ) : Command

    data class Update(
      val setup: Setup,
    ) : Command

    data object Confirm : Command

    data object Clear : Command
  }

  private val commands = Channel<Command>(Channel.UNLIMITED)
  private var configJson = ""
  private var intentJson = ""
  private var configDirty = false
  private var intentDirty = false
  private var elementConfiguration: EmbeddedPaymentElement.Configuration? = null
  private var pendingSecret: CompletableDeferred<CreateIntentResult>? = null
  private var composeView: ComposeView? = null
  private var lastHeightDp = -1f

  fun setConfigJson(value: String?) {
    if (value != null && value != configJson) {
      configJson = value
      configDirty = true
    }
  }

  fun setIntentJson(value: String?) {
    if (value != null && value != intentJson) {
      intentJson = value
      intentDirty = true
    }
  }

  /** After a batch of prop changes: rebuild for new keys or settings, update in place for a new amount. */
  fun commit() {
    if (!configDirty && !intentDirty) return
    val config = parseJson(configJson) ?: return
    val intent = parseJson(intentJson) ?: return
    val publishableKey = config.text("publishableKey") ?: ""
    if (publishableKey.isEmpty()) {
      emit("topLoadFailed", Arguments.createMap().apply { putString("message", "Missing checkout keys.") })
      return
    }
    val types = intent.optJSONArray("paymentMethodTypes")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
    val rebuild = configDirty || elementConfiguration == null
    if (rebuild) {
      PaymentConfiguration.init(
        reactContext.applicationContext,
        publishableKey,
        config.text("stripeAccount"),
      )
      elementConfiguration = configuration(config)
    }
    val setup =
      Setup(
        configuration = elementConfiguration!!,
        intent = intentConfiguration(intent, types),
        rows = types.isNotEmpty(),
      )
    commands.trySend(if (rebuild) Command.Configure(setup) else Command.Update(setup))
    configDirty = false
    intentDirty = false
  }

  fun confirm() {
    commands.trySend(Command.Confirm)
  }

  fun clearSelection() {
    commands.trySend(Command.Clear)
  }

  fun resolveConfirmation(
    clientSecret: String,
    errorMessage: String,
  ) {
    val deferred = pendingSecret ?: return
    pendingSecret = null
    deferred.complete(
      if (clientSecret.isNotEmpty()) {
        CreateIntentResult.Success(clientSecret = clientSecret)
      } else {
        CreateIntentResult.Failure(
          cause = Exception(errorMessage),
          displayMessage = errorMessage.ifEmpty { DEFAULT_ERROR },
        )
      },
    )
  }

  // React Native lays out its own views only: a child added here (the Compose host) is never measured unless asked.
  // Measure and lay it out whenever it requests a layout, as native views inside React Native must.
  private val measureAndLayout =
    Runnable {
      measure(
        MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
        MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY),
      )
      layout(left, top, right, bottom)
    }

  override fun requestLayout() {
    super.requestLayout()
    post(measureAndLayout)
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    if (composeView != null) return
    val activity = reactContext.currentActivity as? ComponentActivity
    composeView =
      ComposeView(reactContext).also { view ->
        // The activity's owners, set on the view and provided to the composition: React Native may detach and
        // re-attach this view (a payment step in front of it), and the element must find them every time.
        if (activity != null) {
          view.setViewTreeLifecycleOwner(activity)
          view.setViewTreeViewModelStoreOwner(activity)
          view.setViewTreeSavedStateRegistryOwner(activity)
        }
        // Kept across detach and re-attach (the element's state survives a payment step); released in [dispose].
        view.setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
        view.setContent { Content(activity) }
        addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
      }
  }

  /** React Native dropped this view (the sheet closed). */
  fun dispose() {
    composeView?.disposeComposition()
    composeView = null
    pendingSecret?.complete(CreateIntentResult.Failure(cause = Exception("closed"), displayMessage = DEFAULT_ERROR))
    pendingSecret = null
  }

  @Composable
  private fun Content(activity: ComponentActivity?) {
    if (activity == null) {
      LaunchedEffect(Unit) {
        emit("topLoadFailed", Arguments.createMap().apply { putString("message", "The payment form needs an activity.") })
      }
      return
    }
    val builder =
      remember {
        EmbeddedPaymentElement.Builder(
          createIntentCallback = CreateIntentCallback { paymentMethod, _ -> awaitClientSecret(paymentMethod.id.orEmpty()) },
          resultCallback = { result -> emitResult(result) },
        )
      }
    CompositionLocalProvider(
      LocalActivityResultRegistryOwner provides activity,
      LocalViewModelStoreOwner provides activity,
      LocalLifecycleOwner provides activity,
    ) {
      val embedded = rememberEmbeddedPaymentElement(builder)
      val density = LocalDensity.current

      LaunchedEffect(embedded) {
        commands.consumeAsFlow().collect { command ->
          when (command) {
            is Command.Configure -> configure(embedded, command.setup, loaded = true)
            is Command.Update -> configure(embedded, command.setup, loaded = false)
            is Command.Confirm -> embedded.confirm()
            is Command.Clear -> embedded.clearPaymentOption()
          }
        }
      }
      LaunchedEffect(embedded) {
        embedded.paymentOption.collect { option ->
          emit(
            "topPaymentOptionChange",
            Arguments.createMap().apply {
              putString("paymentMethodType", option?.paymentMethodType ?: "")
              putString("label", option?.label ?: "")
            },
          )
        }
      }
      Box(
        Modifier
          .fillMaxWidth()
          .wrapContentHeight(align = Alignment.Top, unbounded = true)
          .onSizeChanged { size ->
            val heightDp = with(density) { size.height.toDp().value }
            if (heightDp != lastHeightDp) {
              lastHeightDp = heightDp
              emit("topHeightChange", Arguments.createMap().apply { putDouble("height", heightDp.toDouble()) })
            }
          },
      ) {
        embedded.Content()
      }
    }
  }

  /** Sets up the element when it has rows; reports loaded once. */
  private suspend fun configure(
    embedded: EmbeddedPaymentElement,
    setup: Setup,
    loaded: Boolean,
  ) {
    if (setup.rows) {
      report(embedded.configure(intentConfiguration = setup.intent, configuration = setup.configuration), loaded)
    } else if (loaded) {
      emit("topLoaded", Arguments.createMap().apply { putBoolean("ok", true) })
    }
  }

  private fun report(
    result: EmbeddedPaymentElement.ConfigureResult,
    loaded: Boolean,
  ) {
    when (result) {
      is EmbeddedPaymentElement.ConfigureResult.Succeeded ->
        if (loaded) emit("topLoaded", Arguments.createMap().apply { putBoolean("ok", true) })
      is EmbeddedPaymentElement.ConfigureResult.Failed ->
        emit(
          "topLoadFailed",
          Arguments.createMap().apply { putString("message", result.error.localizedMessage ?: DEFAULT_ERROR) },
        )
    }
  }

  private suspend fun awaitClientSecret(paymentMethodId: String): CreateIntentResult {
    val deferred = CompletableDeferred<CreateIntentResult>()
    post {
      // A confirm still waiting is superseded by this one.
      pendingSecret?.complete(CreateIntentResult.Failure(cause = Exception("superseded"), displayMessage = DEFAULT_ERROR))
      pendingSecret = deferred
      emit("topPaymentMethod", Arguments.createMap().apply { putString("id", paymentMethodId) })
    }
    return deferred.await()
  }

  private fun emitResult(result: EmbeddedPaymentElement.Result) {
    val map = Arguments.createMap()
    when (result) {
      is EmbeddedPaymentElement.Result.Completed -> {
        map.putString("status", "completed")
        map.putString("message", "")
      }
      is EmbeddedPaymentElement.Result.Canceled -> {
        map.putString("status", "canceled")
        map.putString("message", "")
      }
      is EmbeddedPaymentElement.Result.Failed -> {
        map.putString("status", "failed")
        map.putString("message", result.error.localizedMessage ?: DEFAULT_ERROR)
      }
    }
    emit("topConfirmResult", map)
  }

  private fun emit(
    name: String,
    payload: WritableMap,
  ) {
    val dispatcher = UIManagerHelper.getEventDispatcherForReactTag(reactContext, id) ?: return
    dispatcher.dispatchEvent(VezmoElementEvent(UIManagerHelper.getSurfaceId(reactContext), id, name, payload))
  }

  @SuppressLint("RestrictedApi")
  private fun configuration(config: JSONObject): EmbeddedPaymentElement.Configuration {
    val builder =
      EmbeddedPaymentElement.Configuration
        .Builder(config.text("merchantDisplayName") ?: "")
        // Our own Pay button confirms; the card form only collects details.
        .formSheetAction(EmbeddedPaymentElement.FormSheetAction.Continue)
        // Vezmo is white label: no processor wallet of its own in the sheet.
        .link(PaymentSheet.LinkConfiguration(display = PaymentSheet.LinkConfiguration.Display.Never))
        .embeddedViewDisplaysMandateText(true)
    config.optJSONObject("googlePay")?.let { gp ->
      builder.googlePay(
        PaymentSheet.GooglePayConfiguration(
          environment =
            if (gp.optBoolean("testEnv")) {
              PaymentSheet.GooglePayConfiguration.Environment.Test
            } else {
              PaymentSheet.GooglePayConfiguration.Environment.Production
            },
          countryCode = gp.text("merchantCountryCode") ?: "US",
          currencyCode = gp.text("currencyCode"),
        ),
      )
    }
    config.optJSONObject("billing")?.let { b ->
      builder.defaultBillingDetails(
        PaymentSheet.BillingDetails(
          name = b.text("name"),
          email = b.text("email"),
        ),
      )
    }
    config.optJSONObject("appearance")?.let { builder.appearance(appearance(it)) }
    return builder.build()
  }
}
