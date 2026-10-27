package com.vezmo.checkout

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import com.stripe.android.PaymentConfiguration
import com.stripe.android.paymentelement.EmbeddedPaymentElement
import com.stripe.android.paymentelement.WalletButtonsPreview
import com.stripe.android.paymentelement.WalletButtonsViewClickHandler
import com.stripe.android.paymentelement.rememberEmbeddedPaymentElement
import com.stripe.android.paymentsheet.CreateIntentCallback
import com.stripe.android.paymentsheet.CreateIntentResult
import com.stripe.android.paymentsheet.PaymentSheet
import com.stripe.android.paymentsheet.PaymentSheetResult
import com.stripe.android.paymentsheet.model.PaymentOption
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal const val DEFAULT_ERROR = "Your payment couldn’t be completed. Please try again."

private const val TAG = "VezmoCheckout"

/** Who and how: a change rebuilds the engine (new keys, wallets or look), never a new amount. */
internal data class EngineSettings(
    val publishableKey: String,
    val connectedAccountId: String?,
    val merchantDisplayName: String,
    /** Google Pay for the express button, when the business offers it. */
    val googlePay: GooglePay?,
    val billingName: String?,
    val billingEmail: String?,
    val appearance: PaymentSheet.Appearance,
    /** Bumped by Try again after a failed load. */
    val attempt: Int,
) {
    data class GooglePay(val countryCode: String, val currencyCode: String, val testEnv: Boolean)
}

/**
 * What is charged: a change updates the engine in place (the buyer switched currency). Cards go to the card form, the
 * sheet's own Card row; Instant ACH to the engine's bank step, our Instant ACH row; every other method to the element's
 * rows. A subscription saves the card (or the bank account) for its renewals: a free trial only sets it up ([setup]); a
 * first payment keeps it ([saveForLater]).
 */
internal data class EngineIntent(
    val amount: Long,
    val currency: String,
    val elementTypes: List<String>,
    val card: Boolean,
    val setup: Boolean = false,
    val saveForLater: Boolean = false,
    val instantAch: Boolean = false,
) {
    /** What the bank step depends on: a change of the other methods leaves it alone. */
    val bank get() = copy(elementTypes = emptyList(), card = false)
}

internal fun engineIntent(charge: Charge, methods: SheetMethods, config: CheckoutConfig? = null) =
    EngineIntent(
        amount = charge.amountMinor,
        currency = charge.currency.lowercase(),
        elementTypes = methods.elementTypes.filter { it != "card" },
        card = "card" in methods.elementTypes,
        setup = config?.subscription?.trial == true,
        saveForLater = config?.subscription != null,
        instantAch = methods.instantAch,
    )

/**
 * The native payment engine, confirmed through Vezmo's server:
 *
 * - two flow controllers: one for cards only (its sheet is just the card form, which the sheet's Card row opens) and
 *   one with Google Pay that only draws the express button. Each has its own store, so both live in one activity.
 * - an embedded element for the methods with rows of their own (pay-later, Cash App), left unconfigured when there
 *   are none (an empty method list would show every method on the account).
 * - for Instant ACH, a third flow controller offering only the engine's bank step: its sheet goes straight to linking a
 *   US bank account, which our Instant ACH row opens.
 *
 * Payment flow: the buyer taps Pay → the engine makes a payment method and calls back → the session sends its id
 * (`pm_…`) to Vezmo, which prices and confirms the payment → the session answers with the intent's client secret → the
 * engine finishes any step left (3D Secure, Google Pay, a provider) and reports the result. A payment method, not a
 * confirmation token: Vezmo's server confirms every intent itself (manual confirmation), which refuses a token made on
 * the device.
 */
@OptIn(WalletButtonsPreview::class)
internal class Engine(val session: CheckoutSession) {
    lateinit var flow: PaymentSheet.FlowController
    lateinit var walletFlow: PaymentSheet.FlowController
    lateinit var bankFlow: PaymentSheet.FlowController
    lateinit var embedded: EmbeddedPaymentElement

    private var cardSecret: CompletableDeferred<CreateIntentResult>? = null
    private var elementSecret: CompletableDeferred<CreateIntentResult>? = null
    private var configuredWith: EngineSettings? = null
    private var cardConfiguration: PaymentSheet.Configuration? = null
    private var walletConfiguration: PaymentSheet.Configuration? = null
    private var elementConfiguration: EmbeddedPaymentElement.Configuration? = null

    /** What the engine last finished setting up for (the settings, the amount, the reconfigure count). */
    private var configuredFor: Triple<EngineSettings, EngineIntent, Int>? = null
    private var bankConfiguration: PaymentSheet.Configuration? = null
    private var bankConfiguredWith: EngineSettings? = null
    private var bankConfiguredFor: Pair<EngineSettings, EngineIntent>? = null

    /**
     * The sheet is composed, so the flows have registered what they launch to finish a payment. Between the old
     * activity's sheet and the recreated one's they haven't: an answer from Vezmo then waits ([held]) for the new sheet.
     */
    private var isComposed = false
    private val held = mutableListOf<() -> Unit>()

    private fun whenComposed(deliver: () -> Unit) {
        if (isComposed) deliver() else held += deliver
    }

    /** The sheet is composed (its flows built and registered): answers held over a recreation go on now. */
    fun composed() {
        isComposed = true
        val waiting = held.toList()
        held.clear()
        waiting.forEach { it() }
    }

    fun decomposed() {
        isComposed = false
    }

    /** The settings the card flow and the element last finished loading with (the sheet shows placeholders until). */
    var cardLoaded by mutableStateOf<EngineSettings?>(null)
    var elementLoaded by mutableStateOf<EngineSettings?>(null)

    /**
     * The card flow and the element are set up for what the sheet shows now. False while they are set up again (the
     * buyer switched currency: the rows stay on screen) or after it failed: the engine refuses the card form and
     * payments meanwhile, so the sheet holds the Card row and Pay until then.
     */
    var cardReady by mutableStateOf(false)
    var elementReady by mutableStateOf(false)

    /** Bumped to set the engine up again for the same settings (the card form found it not set up after all). */
    var reconfigure by mutableIntStateOf(0)

    /** The bank step is set up for this payment: the Instant ACH row shows only then. */
    var bankOn by mutableStateOf(false)

    /** The bank step is set up for what the sheet shows now (see [cardReady]). */
    var bankReady by mutableStateOf(false)

    /** The settings the bank step last finished with (or found it isn't wanted): placeholders until then. */
    var bankLoaded by mutableStateOf<EngineSettings?>(null)

    /** The engine can take this way to pay now. */
    fun readyFor(method: Method) =
        when (method) {
            Method.Card -> cardReady
            Method.Element -> elementReady
            Method.InstantAch -> bankReady
            else -> true
        }

    /** The card form is being opened: a failure reported meanwhile is the form's, not a payment's. */
    private var openingCard = false
    private var openFailure: Throwable? = null

    /** After the engine is set up again, open the card form the buyer asked for. */
    private var reopenCard = false

    /** The element has rows of its own to draw. */
    var elementRows by mutableStateOf(false)

    /** Google Pay is set up; [walletsHeight] says whether the phone showed a button. */
    var walletsOn by mutableStateOf(false)

    /** The wallet flow is set up for what the sheet shows: a Google Pay tap before then would fail before Vezmo is asked. */
    var walletReady by mutableStateOf(false)
    var walletsHeight by mutableIntStateOf(0)

    /** Each card the card form reports, numbered so the same card reported again still counts. */
    var cardReport by mutableStateOf<Pair<PaymentOption?, Int>>(null to 0)

    fun reportCard(option: PaymentOption?) {
        cardReport = option to cardReport.second + 1
    }

    /** Each bank account the bank step reports, numbered the same way. */
    var bankReport by mutableStateOf<Pair<PaymentOption?, Int>>(null to 0)

    fun reportBank(option: PaymentOption?) {
        bankReport = option to bankReport.second + 1
    }

    val cardPort =
        object : CardFlowPort {
            // The Card row is off until the card flow is set up; a tap that gets here anyway is dropped.
            override fun presentCard() {
                if (cardReady) openCardForm(retry = true)
            }

            override fun confirmCard() {
                if (cardReady) flow.confirm() else session.post { session.engineNotReady() }
            }

            // The Instant ACH row is off until the bank step is set up.
            override fun presentBank() {
                if (bankReady) bankFlow.presentPaymentOptions()
            }

            override fun confirmBank() {
                if (bankReady) bankFlow.confirm() else session.post { session.engineNotReady(BANK_LOADING) }
            }

            override fun resolveConfirmation(clientSecret: String?, errorMessage: String?) {
                val result = answer(clientSecret, errorMessage)
                whenComposed {
                    cardSecret?.complete(result)
                    cardSecret = null
                }
            }
        }

    val elementPort =
        object : ElementPort {
            override fun confirm() {
                if (elementReady) embedded.confirm() else session.post { session.engineNotReady() }
            }

            override fun clearSelection() = embedded.clearPaymentOption()

            override fun resolveConfirmation(clientSecret: String?, errorMessage: String?) {
                val result = answer(clientSecret, errorMessage)
                whenComposed {
                    elementSecret?.complete(result)
                    elementSecret = null
                }
            }
        }

    private fun answer(clientSecret: String?, errorMessage: String?): CreateIntentResult =
        if (!clientSecret.isNullOrEmpty()) {
            CreateIntentResult.Success(clientSecret = clientSecret)
        } else {
            val message = errorMessage?.ifEmpty { null } ?: DEFAULT_ERROR
            CreateIntentResult.Failure(cause = Exception(message), displayMessage = message)
        }

    /** The engine made a payment method: hand its id to the session and wait for Vezmo's answer. */
    suspend fun awaitClientSecret(card: Boolean, paymentMethodId: String): CreateIntentResult =
        withContext(Dispatchers.Main.immediate) {
            val deferred = CompletableDeferred<CreateIntentResult>()
            // A confirm still waiting is superseded by this one.
            val superseded = CreateIntentResult.Failure(cause = Exception("superseded"), displayMessage = DEFAULT_ERROR)
            if (card) {
                cardSecret?.complete(superseded)
                cardSecret = deferred
            } else {
                elementSecret?.complete(superseded)
                elementSecret = deferred
            }
            session.post { session.onPaymentMethod(paymentMethodId) }
            deferred.await()
        }

    /**
     * Opens the card form. The engine refuses when it isn't set up after all ("not configured", in its own words, never
     * shown): it is set up again and the form opened once more; failing that, the buyer reads ours.
     */
    private fun openCardForm(retry: Boolean) {
        openFailure = null
        openingCard = true
        flow.presentPaymentOptions() // a refusal is reported at once, to onFlowResult
        openingCard = false
        val failure = openFailure ?: return
        Log.w(TAG, "The card form couldn't open", failure)
        if (retry) {
            reopenCard = true
            cardReady = false
            reconfigure++
        } else {
            session.engineNotReady()
        }
    }

    fun onFlowResult(result: PaymentSheetResult) {
        if (openingCard) {
            if (result is PaymentSheetResult.Failed) openFailure = result.error
            return
        }
        when (result) {
            is PaymentSheetResult.Completed -> report(ConfirmStatus.Completed, "")
            is PaymentSheetResult.Canceled -> report(ConfirmStatus.Canceled, "")
            is PaymentSheetResult.Failed -> {
                Log.w(TAG, "The card flow failed", result.error)
                report(ConfirmStatus.Failed, result.error.localizedMessage ?: DEFAULT_ERROR)
            }
        }
    }

    fun onElementResult(result: EmbeddedPaymentElement.Result) =
        when (result) {
            is EmbeddedPaymentElement.Result.Completed -> report(ConfirmStatus.Completed, "")
            is EmbeddedPaymentElement.Result.Canceled -> report(ConfirmStatus.Canceled, "")
            is EmbeddedPaymentElement.Result.Failed -> report(ConfirmStatus.Failed, result.error.localizedMessage ?: DEFAULT_ERROR)
        }

    private fun report(status: ConfirmStatus, message: String) = session.post { session.onConfirmResult(status, message) }

    /** Sets the engine up for these settings (rebuilt when they change) and this amount. */
    suspend fun configure(context: Context, settings: EngineSettings, intent: EngineIntent) {
        // The sheet's activity was recreated: this engine and the flows' own setup (kept by the engine across it) are
        // already set up for exactly this. Setting them up again could cut into a payment in flight.
        val wanted = Triple(settings, intent, reconfigure)
        if (wanted == configuredFor) return
        configuredFor = null
        val rebuild = settings != configuredWith
        if (rebuild) {
            // Placeholders until it is built again, even for settings it last finished with (the buyer switched currency
            // and back before the first switch was set up: those rows would show over a flow still being set up).
            cardLoaded = null
            elementLoaded = null
            PaymentConfiguration.init(context.applicationContext, settings.publishableKey, settings.connectedAccountId)
            cardConfiguration = sheetConfiguration(settings, wallets = false)
            walletConfiguration = settings.googlePay?.let { sheetConfiguration(settings, wallets = true) }
            elementConfiguration = elementConfiguration(settings)
            configuredWith = settings
        }
        // None is ready for this amount until set up for it (the element waits for the card flow).
        cardReady = false
        elementReady = false
        walletReady = false

        if (!intent.card) {
            walletsOn = false
        } else {
            val cards = intentConfiguration(intent, listOf("card"))
            val error = configureOne(flow, cards, cardConfiguration!!)
            if (error != null) {
                reopenCard = false
                Log.w(TAG, "The card form couldn't load", error)
                session.setElementError(error.localizedMessage ?: DEFAULT_ERROR)
                return
            }
            cardReady = true
            // A wallet that can't load is left out; the card still works.
            walletsOn = walletConfiguration?.let { configureOne(walletFlow, cards, it) == null } ?: false
            walletReady = walletsOn
            reportCard(flow.getPaymentOption())
        }
        cardLoaded = settings
        if (reopenCard) {
            reopenCard = false
            openCardForm(retry = false)
        }

        elementRows = intent.elementTypes.isNotEmpty()
        if (elementRows) {
            when (val result = embedded.configure(intentConfiguration(intent, intent.elementTypes), elementConfiguration!!)) {
                is EmbeddedPaymentElement.ConfigureResult.Succeeded -> if (rebuild) session.setElementError(null)
                is EmbeddedPaymentElement.ConfigureResult.Failed -> {
                    Log.w(TAG, "The payment options couldn't load", result.error)
                    session.setElementError(result.error.localizedMessage ?: DEFAULT_ERROR)
                    return
                }
            }
        }
        elementReady = true
        elementLoaded = settings
        configuredFor = wanted
    }

    /**
     * Sets the bank step up for this payment (beside the rest of the engine, which it doesn't hold up). One the engine
     * can't offer (it decides which payments its bank step takes) leaves Instant ACH out; everything else is unaffected.
     */
    suspend fun configureBank(context: Context, settings: EngineSettings, intent: EngineIntent) {
        // As in [configure]: after a recreation the bank step is already set up for exactly this.
        val wanted = settings to intent.bank
        if (wanted == bankConfiguredFor) return
        bankConfiguredFor = null
        bankReady = false
        if (!intent.instantAch) {
            bankOn = false
            reportBank(null)
        } else {
            if (settings != bankConfiguredWith) {
                bankLoaded = null
                PaymentConfiguration.init(context.applicationContext, settings.publishableKey, settings.connectedAccountId)
                bankConfiguration = bankConfiguration(settings)
                bankConfiguredWith = settings
            }
            val error = configureOne(bankFlow, intentConfiguration(intent, listOf("link")), bankConfiguration!!)
            if (error != null) Log.i(TAG, "Instant ACH isn't available for this payment", error)
            bankOn = error == null
            bankReady = bankOn
            reportBank(if (bankOn) bankFlow.getPaymentOption() else null)
        }
        bankLoaded = settings
        bankConfiguredFor = wanted
    }

    private suspend fun configureOne(
        flow: PaymentSheet.FlowController,
        intent: PaymentSheet.IntentConfiguration,
        configuration: PaymentSheet.Configuration,
    ): Throwable? {
        val done = CompletableDeferred<Throwable?>()
        flow.configureWithIntentConfiguration(intent, configuration) { success, error ->
            done.complete(if (success) null else error ?: Exception(DEFAULT_ERROR))
        }
        return done.await()
    }

    /** What is charged, with the method types each part of the engine shows. */
    private fun intentConfiguration(intent: EngineIntent, types: List<String>) =
        PaymentSheet.IntentConfiguration(
            mode = if (intent.setup) {
                PaymentSheet.IntentConfiguration.Mode.Setup(
                    currency = intent.currency,
                    setupFutureUse = PaymentSheet.IntentConfiguration.SetupFutureUse.OffSession,
                )
            } else {
                PaymentSheet.IntentConfiguration.Mode.Payment(
                    amount = intent.amount,
                    currency = intent.currency,
                    setupFutureUse = if (intent.saveForLater) PaymentSheet.IntentConfiguration.SetupFutureUse.OffSession else null,
                    // Vezmo's server makes every intent with automatic_async capture; the engine must say the same.
                    captureMethod = PaymentSheet.IntentConfiguration.CaptureMethod.AutomaticAsync,
                )
            },
            paymentMethodTypes = types,
        )

    /** The same business, look and billing details for both flows; Google Pay only for the wallet flow. */
    @SuppressLint("RestrictedApi")
    private fun sheetConfiguration(settings: EngineSettings, wallets: Boolean): PaymentSheet.Configuration {
        val builder = PaymentSheet.Configuration
            .Builder(settings.merchantDisplayName)
            // Vezmo is white label: no processor wallet of its own.
            .link(PaymentSheet.LinkConfiguration(display = PaymentSheet.LinkConfiguration.Display.Never))
            .paymentMethodLayout(PaymentSheet.PaymentMethodLayout.Vertical)
            .appearance(settings.appearance)
        settings.googlePay?.takeIf { wallets }?.let { gp ->
            builder.googlePay(
                PaymentSheet.GooglePayConfiguration(
                    environment = if (gp.testEnv) {
                        PaymentSheet.GooglePayConfiguration.Environment.Test
                    } else {
                        PaymentSheet.GooglePayConfiguration.Environment.Production
                    },
                    countryCode = gp.countryCode,
                    currencyCode = gp.currencyCode,
                ),
            )
        }
        billing(settings)?.let { builder.defaultBillingDetails(it) }
        return builder.build()
    }

    /**
     * The bank step: the engine's bank payments run on its own wallet, which must be on for them; its button is never
     * shown (Vezmo is white label: the buyer sees our Instant ACH row and the bank step, nothing else). The buyer's email
     * from the session is used as is, so the step asks only for the bank.
     */
    @SuppressLint("RestrictedApi")
    private fun bankConfiguration(settings: EngineSettings): PaymentSheet.Configuration {
        val hidden = PaymentSheet.WalletButtonsConfiguration(
            visibility = PaymentSheet.WalletButtonsConfiguration.Visibility(
                paymentElement = mapOf(
                    PaymentSheet.WalletButtonsConfiguration.Wallet.Link to PaymentSheet.WalletButtonsConfiguration.PaymentElementVisibility.Never,
                ),
            ),
        )
        val builder = PaymentSheet.Configuration
            .Builder(settings.merchantDisplayName)
            .link(PaymentSheet.LinkConfiguration(display = PaymentSheet.LinkConfiguration.Display.WalletButtonHidden))
            .walletButtons(hidden)
            .paymentMethodLayout(PaymentSheet.PaymentMethodLayout.Vertical)
            .appearance(settings.appearance)
        billing(settings)?.let { builder.defaultBillingDetails(it) }
        if (settings.billingEmail != null) {
            builder.billingDetailsCollectionConfiguration(
                PaymentSheet.BillingDetailsCollectionConfiguration(
                    email = PaymentSheet.BillingDetailsCollectionConfiguration.CollectionMode.Never,
                    attachDefaultsToPaymentMethod = true,
                ),
            )
        }
        return builder.build()
    }

    @SuppressLint("RestrictedApi")
    private fun elementConfiguration(settings: EngineSettings): EmbeddedPaymentElement.Configuration {
        val builder = EmbeddedPaymentElement.Configuration
            .Builder(settings.merchantDisplayName)
            // Our own Pay button confirms; a form only collects details.
            .formSheetAction(EmbeddedPaymentElement.FormSheetAction.Continue)
            // Vezmo is white label: no processor wallet of its own in the sheet.
            .link(PaymentSheet.LinkConfiguration(display = PaymentSheet.LinkConfiguration.Display.Never))
            .embeddedViewDisplaysMandateText(true)
            .appearance(settings.appearance)
        billing(settings)?.let { builder.defaultBillingDetails(it) }
        return builder.build()
    }

    private fun billing(settings: EngineSettings) =
        if (settings.billingName != null || settings.billingEmail != null) {
            PaymentSheet.BillingDetails(name = settings.billingName, email = settings.billingEmail)
        } else {
            null
        }

    /** The express Google Pay button, when the phone has it. */
    @Composable
    fun WalletButtons(modifier: Modifier = Modifier) {
        val handler = remember {
            WalletButtonsViewClickHandler { wallet ->
                if (!walletReady) {
                    // Still being set up for this amount or currency (the buyer just switched, or it's still loading on
                    // a slow network): the wallet would fail before Vezmo is asked. Our words; the next tap pays.
                    session.post { session.engineNotReady(WALLET_LOADING) }
                    true // handled here: the wallet doesn't start
                } else {
                    session.walletStarted(wallet)
                    false // not handled here: the wallet goes on to pay
                }
            }
        }
        Box(modifier.fillMaxWidth().onSizeChanged { walletsHeight = it.height }) {
            walletFlow.WalletButtons(handler)
        }
    }

    /** The element's own rows (pay-later, Cash App). */
    @Composable
    fun ElementRows() {
        embedded.Content()
    }
}

/**
 * Creates the engine with the sheet. The flow controllers and the element must be created unconditionally, as part of
 * the sheet's first composition, in the sheet's activity. [kept]: the engine from before the activity was recreated,
 * so a confirmation waiting on Vezmo's answer still reaches the engine that asked for it.
 */
@Composable
internal fun rememberEngine(session: CheckoutSession, kept: Engine? = null): Engine {
    val engine = remember(session, kept) { kept ?: Engine(session) }
    val cardBuilder = remember(engine) {
        PaymentSheet.FlowController
            .Builder(
                resultCallback = { engine.onFlowResult(it) },
                paymentOptionResultCallback = { engine.reportCard(it.paymentOption) },
            ).createIntentCallback(CreateIntentCallback { pm, _ -> engine.awaitClientSecret(card = true, pm.id.orEmpty()) })
    }
    val walletBuilder = remember(engine) {
        PaymentSheet.FlowController
            .Builder(
                resultCallback = { engine.onFlowResult(it) },
                paymentOptionResultCallback = { },
            ).createIntentCallback(CreateIntentCallback { pm, _ -> engine.awaitClientSecret(card = true, pm.id.orEmpty()) })
    }
    // Instant ACH's bank step confirms through the card flow's Vezmo step too.
    val bankBuilder = remember(engine) {
        PaymentSheet.FlowController
            .Builder(
                resultCallback = { engine.onFlowResult(it) },
                paymentOptionResultCallback = { engine.reportBank(it.paymentOption) },
            ).createIntentCallback(CreateIntentCallback { pm, _ -> engine.awaitClientSecret(card = true, pm.id.orEmpty()) })
    }
    val elementBuilder = remember(engine) {
        EmbeddedPaymentElement.Builder(
            createIntentCallback = CreateIntentCallback { pm, _ -> engine.awaitClientSecret(card = false, pm.id.orEmpty()) },
            resultCallback = { engine.onElementResult(it) },
        )
    }
    engine.flow = cardBuilder.build()
    engine.walletFlow = walletBuilder.build()
    engine.bankFlow = bankBuilder.build()
    engine.embedded = rememberEmbeddedPaymentElement(elementBuilder)

    // The card the card form reports, with the network's logo, for the sheet's Card row.
    val (option, _) = engine.cardReport
    val card = option?.takeIf { it.paymentMethodType == "card" }
    val painter = card?.iconPainter
    LaunchedEffect(engine.cardReport) {
        session.setCard(card?.let { CardChoice(it.label, painter) })
    }
    // The bank account the bank step linked, for our Instant ACH row: its last four only.
    LaunchedEffect(engine.bankReport) {
        session.setBank(bankLabel(engine.bankReport.first?.label)?.let { CardChoice(it, null) })
    }
    LaunchedEffect(engine.embedded) {
        engine.embedded.paymentOption.collect { session.setOption(it?.let { o -> o.label }) }
    }
    DisposableEffect(engine) {
        session.attachCardFlow(engine.cardPort)
        session.attachElement(engine.elementPort)
        // After the flows built above registered what they launch (their effects run first).
        engine.composed()
        onDispose {
            engine.decomposed()
            // A kept engine outlives this composition (the activity is being recreated): it stays attached, so Vezmo's
            // answer to a payment in flight reaches it, and waits there for the recreated sheet (see `composed`).
            if (kept == null) {
                session.attachCardFlow(null)
                session.attachElement(null)
            }
        }
    }
    return engine
}
