package com.vezmo.checkout

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.core.content.IntentCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Takes a payment with the Vezmo payment sheet.
 *
 * ```
 * // In your activity's onCreate (it registers for the sheet's result, so it must be created early):
 * val vezmo = VezmoCheckout(this, VezmoConfiguration()) { result -> … }
 *
 * // When the buyer taps Pay, with the client token your server got from Vezmo:
 * lifecycleScope.launch {
 *     vezmo.prepare(clientToken)?.let { return@launch showError(it.message) }
 *     vezmo.present()
 * }
 *
 * // A subscription: its checkout token instead.
 * vezmo.prepare(subscriptionToken = checkoutToken)
 * ```
 *
 * In Compose, use [rememberVezmoCheckout].
 */
class VezmoCheckout internal constructor(
    configuration: VezmoConfiguration,
    private val launcher: ActivityResultLauncher<CheckoutRequest>,
    private val onResult: (CheckoutResult) -> Unit,
) {
    /**
     * The settings the next [prepare] uses. Apps pass them to the constructor and leave this alone. Setting it later
     * is for Vezmo's own wrappers (the Flutter plugin), whose settings arrive after the activity is created.
     */
    var configuration: VezmoConfiguration = configuration

    /**
     * @param activity your activity, in its `onCreate` (before it is started).
     * @param onResult called with the result each time the sheet closes. Never with an exception.
     */
    constructor(
        activity: ComponentActivity,
        configuration: VezmoConfiguration,
        onResult: (CheckoutResult) -> Unit,
    ) : this(configuration, activity.registerForActivityResult(CheckoutContract()) { onResult(it) }, onResult)

    private var prepared: CheckoutRequest? = null

    /**
     * Loads the checkout. Call it as soon as you have the token, then [present]. Pass exactly one token.
     *
     * @param clientToken from your server: the API checkout session's `clientToken` (a one-time payment).
     * @param subscriptionToken from your server: a subscription's `checkoutToken`, to start it in the app (the first
     *   payment, or a free trial with the card saved for the renewals).
     * @param merchantDisplayName shown at the top of the sheet. Defaults to the business name on the session.
     * @return null when the checkout is ready to pay, or why it can't be (expired, already paid, no connection…).
     */
    suspend fun prepare(
        clientToken: String? = null,
        subscriptionToken: String? = null,
        merchantDisplayName: String? = null,
    ): VezmoError? = withContext(Dispatchers.Main.immediate) {
        prepareOnMain(clientToken, subscriptionToken, merchantDisplayName)
    }

    private suspend fun prepareOnMain(
        clientToken: String?,
        subscriptionToken: String?,
        merchantDisplayName: String?,
    ): VezmoError? {
        // A session prepared before and never presented is let go.
        prepared?.let { PreparedSessions.take(it.token)?.dispose() }
        prepared = null
        if (clientToken.isNullOrBlank() == subscriptionToken.isNullOrBlank()) {
            return VezmoError(VezmoError.Code.Config, "Pass a clientToken or a subscriptionToken.")
        }
        val subscription = !subscriptionToken.isNullOrBlank()
        val token = (if (subscription) subscriptionToken else clientToken)!!.trim()
        // The settings as they are now, for this session and the sheet that shows it.
        val config = configuration
        val api = VezmoApi(config.apiBase ?: DEFAULT_API_BASE, sdk = config.sdk ?: DEFAULT_SDK)
        val session = CheckoutSession(api, token, subscription = subscription)
        session.load()
        val phase = session.state.value.phase
        if (phase is SessionPhase.Closed && phase.result is CheckoutResult.Failed) {
            session.dispose()
            return phase.result.error
        }
        PreparedSessions.put(session)
        prepared = CheckoutRequest(token, merchantDisplayName, config, subscription)
        return null
    }

    /** Opens the sheet. The result arrives in the callback you gave this [VezmoCheckout]. */
    fun present() {
        val request = prepared
        if (request == null) {
            onResult(CheckoutResult.Failed(VezmoError(VezmoError.Code.Config, "Call prepare() before present().")))
            return
        }
        prepared = null
        try {
            launcher.launch(request)
        } catch (e: IllegalStateException) {
            // The activity this was created in is gone (its result registration with it).
            PreparedSessions.take(request.token)?.dispose()
            onResult(CheckoutResult.Failed(VezmoError(VezmoError.Code.Config, "Present the sheet from an open activity.")))
        }
    }

    companion object {
        /** This SDK's version. */
        const val VERSION: String = BuildConfig.SDK_VERSION
    }
}

/**
 * A [VezmoCheckout] for a Compose screen: [VezmoCheckout.prepare] in a coroutine, then [VezmoCheckout.present].
 * [onResult] is called with the result each time the sheet closes.
 */
@Composable
fun rememberVezmoCheckout(
    configuration: VezmoConfiguration,
    onResult: (CheckoutResult) -> Unit,
): VezmoCheckout {
    val currentOnResult by rememberUpdatedState(onResult)
    val launcher = rememberLauncherForActivityResult(CheckoutContract()) { currentOnResult(it) }
    return remember(configuration, launcher) { VezmoCheckout(configuration, launcher) { currentOnResult(it) } }
}

/** What the sheet's activity needs: the session's token and how to show it. */
@kotlinx.parcelize.Parcelize
internal data class CheckoutRequest(
    /** A client token, or a subscription checkout's token when [subscription]. */
    val token: String,
    val merchantDisplayName: String?,
    val configuration: VezmoConfiguration,
    val subscription: Boolean = false,
) : android.os.Parcelable

internal class CheckoutContract : ActivityResultContract<CheckoutRequest, CheckoutResult>() {
    override fun createIntent(
        context: Context,
        input: CheckoutRequest,
    ): Intent = Intent(context, VezmoCheckoutActivity::class.java).putExtra(EXTRA_REQUEST, input)

    override fun parseResult(
        resultCode: Int,
        intent: Intent?,
    ): CheckoutResult =
        intent
            ?.takeIf { resultCode == Activity.RESULT_OK }
            ?.apply { setExtrasClassLoader(CheckoutResult::class.java.classLoader) }
            ?.let { IntentCompat.getParcelableExtra(it, EXTRA_RESULT, CheckoutResult::class.java) }
            ?: CheckoutResult.Canceled

    companion object {
        const val EXTRA_REQUEST = "com.vezmo.checkout.REQUEST"
        const val EXTRA_RESULT = "com.vezmo.checkout.RESULT"
    }
}

/**
 * Sessions loaded by [VezmoCheckout.prepare], handed to the sheet's activity in this process. After the process was
 * killed the activity loads the session again from its token.
 */
internal object PreparedSessions {
    private val sessions = mutableMapOf<String, CheckoutSession>()

    fun put(session: CheckoutSession) {
        sessions.put(session.token, session)?.takeIf { it !== session }?.dispose()
    }

    fun take(token: String): CheckoutSession? = sessions.remove(token)
}
