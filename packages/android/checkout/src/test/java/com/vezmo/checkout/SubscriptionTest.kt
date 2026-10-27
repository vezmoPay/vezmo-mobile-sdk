package com.vezmo.checkout

import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** GET /subscription-checkout/:token, as the API returns it (a 7-day free trial by default). */
private fun view(over: JSONObject.() -> Unit = {}): JSONObject =
    JSONObject(
        """{"subscriptionRef":"SUB-1","status":"INCOMPLETE","mode":"setup","publishableKey":"pk_test_x",
        "connectedAccountId":null,"amount":0,"recurringAmount":9.99,"currency":"USD","planName":"Club",
        "interval":"MONTH","intervalCount":1,"trialDays":7,"merchant":{"name":"Acme","logo":null,"color":null},
        "customer":{"email":"ana@example.com","name":"Ana"},
        "consentText":"I authorize Acme to charge my payment method ${'$'}9.99 every month after my 7-day free trial, until I cancel.",
        "localOffer":null,"livemode":false,"nextChargeAt":"2026-10-23T07:00:00.000Z","manageUrl":"https://acme.test/manage/x"}""",
    ).apply(over)

private fun firstPayment() = view { put("mode", "payment").put("amount", 9.99).put("trialDays", JSONObject.NULL) }

/** The subscription calls, faked; the one-time payment calls must not be used. */
private class FakeSubscriptionApi(var view: JSONObject = view()) : CheckoutApi {
    var load: () -> CheckoutConfig = { CheckoutConfig.fromSubscription(view) }
    var payAnswer: JSONObject? = null
    var payArgs: List<String?>? = null
    var confirmAnswer: CheckoutResult? = null
    var confirmError: VezmoApiError? = null
    val confirms = mutableListOf<String>()

    override suspend fun subscription(token: String, currency: String?) = load()

    override suspend fun subscriptionPay(token: String, paymentMethodId: String, localOffer: String?): PayResponse {
        payArgs = listOf(token, paymentMethodId, localOffer)
        return PayResponse.fromSubscription(payAnswer!!)
    }

    override suspend fun subscriptionConfirm(token: String, intentId: String): CheckoutResult {
        confirms += "$token:$intentId"
        confirmError?.let { throw it }
        return confirmAnswer!!
    }

    override suspend fun checkout(token: String, currency: String?): CheckoutConfig = error("one-time checkout used")

    override suspend fun pay(token: String, paymentMethodId: String, localOffer: String?, returnUrl: String?): PayResponse = error("one-time pay used")

    override suspend fun intent(token: String, localOffer: String?): SessionIntent = error("not used")

    override suspend fun startQr(method: QrMethod, start: QrStart): QrPayment = error("not used")

    override fun checkoutPageUrl(token: String) = ""

    override suspend fun confirm(token: String, paymentIntentId: String): Unit = error("one-time confirm used")

    override suspend fun status(token: String): SessionStatus = error("one-time status used")
}

private class CardFlow : CardFlowPort {
    var confirms = 0
    val resolved = mutableListOf<Pair<String?, String?>>()

    override fun presentCard() = Unit

    override fun confirmCard() {
        confirms++
    }

    override fun presentBank() = Unit

    override fun confirmBank() = Unit

    override fun resolveConfirmation(clientSecret: String?, errorMessage: String?) {
        resolved += clientSecret to errorMessage
    }
}

class SubscriptionTest {
    private class Setup(scope: TestScope, v: JSONObject = view()) {
        val api = FakeSubscriptionApi(v)
        val cardFlow = CardFlow()
        val session = CheckoutSession(api, "subtok", UnconfinedTestDispatcher(scope.testScheduler), subscription = true)
            .also { it.attachCardFlow(cardFlow) }

        /** The buyer types a card in the card form. */
        fun chooseCard() {
            session.changeCard()
            session.setCard(CardChoice("•••• 4242", null))
        }
    }

    @Test
    fun `a free trial - nothing due today, cards and Google Pay only, a setup intent saved for later`() {
        val config = CheckoutConfig.fromSubscription(view())
        val charge = chargeOf(config, false)
        val methods = sheetMethods(config, charge)
        assertEquals(0L, charge.amountMinor)
        assertEquals(SheetMethods(listOf("card"), googlePay = true, upi = false, pix = false), methods)
        assertEquals(EngineIntent(0, "usd", emptyList(), card = true, setup = true, saveForLater = true), engineIntent(charge, methods, config))
        assertEquals("$9.99 / month", planPriceText(config.subscription!!, Locale.US))
        assertEquals("$9.99 every 3 months", planPriceText(config.subscription!!.copy(intervalCount = 3), Locale.US))
        // A merchant-of-record business: no connected account, never the text "null".
        assertNull(config.connectedAccountId)
        assertEquals("Acme", config.merchantName)
        assertEquals("Ana", config.customerName)
    }

    @Test
    fun `Instant ACH when the business offers it for the plan - set up for a trial, kept for the renewals`() {
        val trial = CheckoutConfig.fromSubscription(view { put("instantAchEnabled", true) })
        val trialCharge = chargeOf(trial, false)
        val setup = engineIntent(trialCharge, sheetMethods(trial, trialCharge), trial)
        assertTrue(setup.instantAch)
        assertTrue(setup.setup)
        val paid = CheckoutConfig.fromSubscription(firstPayment().put("instantAchEnabled", true))
        val charge = chargeOf(paid, false)
        val intent = engineIntent(charge, sheetMethods(paid, charge), paid)
        assertTrue(intent.instantAch)
        assertTrue(intent.saveForLater)
        assertFalse(intent.setup)
        assertFalse(sheetMethods(CheckoutConfig.fromSubscription(view()), trialCharge).instantAch)
    }

    @Test
    fun `a first payment keeps the card for renewals, a one-time payment does not`() {
        val config = CheckoutConfig.fromSubscription(firstPayment())
        val charge = chargeOf(config, false)
        val intent = engineIntent(charge, sheetMethods(config, charge), config)
        assertEquals(999L, intent.amount)
        assertFalse(intent.setup)
        assertTrue(intent.saveForLater)
        val oneTime = config.copy(subscription = null)
        assertFalse(engineIntent(charge, sheetMethods(oneTime, charge), oneTime).saveForLater)
    }

    @Test
    fun `starts a free trial - Vezmo confirms it, the result names the subscription`() = runTest {
        val t = Setup(this)
        t.session.load()
        t.chooseCard()
        t.api.payAnswer = JSONObject(
            """{"state":"succeeded","subscriptionRef":"SUB-1","subscriptionStatus":"trialing","paymentId":null,
            "transactionId":null,"clientSecret":"seti_1_secret_a","method":{"type":"card","brand":"visa","last4":"4242","wallet":null}}""",
        )
        t.session.pay()
        assertEquals(1, t.cardFlow.confirms)
        t.session.onPaymentMethod("pm_1")
        assertEquals(listOf("subtok", "pm_1", null), t.api.payArgs)
        assertEquals(listOf<Pair<String?, String?>>("seti_1_secret_a" to null), t.cardFlow.resolved)
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertEquals(
            SessionPhase.Done(CheckoutResult.Succeeded(null, null, SubscriptionResult("SUB-1", SubscriptionResult.Status.Trialing))),
            t.session.state.value.phase,
        )
        t.session.dispose()
    }

    @Test
    fun `3D Secure on the first payment - finished on the device, then recorded with confirm`() = runTest {
        val t = Setup(this, firstPayment())
        t.session.load()
        t.chooseCard()
        t.api.payAnswer = JSONObject(
            """{"state":"requires_action","subscriptionRef":"SUB-1","intentId":"pi_9","clientSecret":"pi_9_secret_b","method":null}""",
        )
        t.api.confirmAnswer = resultFromSubscriptionConfirm("active", "SUB-1", "pay_9", "VT9")
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        assertEquals(listOf<Pair<String?, String?>>("pi_9_secret_b" to null), t.cardFlow.resolved)
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertEquals(listOf("subtok:pi_9"), t.api.confirms)
        assertEquals(
            SessionPhase.Done(CheckoutResult.Succeeded("pay_9", "VT9", SubscriptionResult("SUB-1", SubscriptionResult.Status.Active))),
            t.session.state.value.phase,
        )
        t.session.dispose()
    }

    @Test
    fun `a decline at our confirm after 3D Secure (the engine completed) - the sheet stays ready, in Vezmo's words`() = runTest {
        val t = Setup(this, firstPayment())
        t.session.load()
        t.chooseCard()
        t.api.payAnswer = JSONObject(
            """{"state":"requires_action","subscriptionRef":"SUB-1","clientSecret":"pi_9_secret_b","method":null}""",
        )
        t.api.confirmError = VezmoApiError(VezmoError.Code.Declined, "Payment declined by your bank (issuer).", 400)
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertEquals(listOf("subtok:pi_9"), t.api.confirms)
        assertEquals(
            SessionPhase.Ready(VezmoError(VezmoError.Code.Declined, "Payment declined by your bank (issuer).")),
            t.session.state.value.phase,
        )
        t.session.dispose()
    }

    @Test
    fun `declined after 3D Secure on the device - the reason is Vezmo's, from its confirm step`() = runTest {
        val t = Setup(this, firstPayment())
        t.session.load()
        t.chooseCard()
        t.api.payAnswer = JSONObject(
            """{"state":"requires_action","subscriptionRef":"SUB-1","clientSecret":"pi_9_secret_b","method":null}""",
        )
        t.api.confirmError = VezmoApiError(VezmoError.Code.Declined, "The payment was not completed.", 400)
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        t.session.onConfirmResult(ConfirmStatus.Failed, "Your payment method was declined.")
        assertEquals(listOf("subtok:pi_9"), t.api.confirms)
        assertEquals(
            SessionPhase.Ready(VezmoError(VezmoError.Code.Declined, "The payment was not completed.")),
            t.session.state.value.phase,
        )
        t.session.dispose()
    }

    @Test
    fun `a used or unknown subscription link closes the sheet as expired`() = runTest {
        val t = Setup(this)
        t.api.load = { throw VezmoApiError(VezmoError.Code.Expired, "This subscription link is no longer valid.", 404) }
        t.session.load()
        val closed = t.session.state.value.phase as SessionPhase.Closed
        assertEquals(VezmoError.Code.Expired, (closed.result as CheckoutResult.Failed).error.code)
        t.session.dispose()
    }

    @Test
    fun `the API reads a 404 as an expired link and an already set up subscription as already paid`() = runTest {
        fun api(status: Int, body: String) = VezmoApi("https://api.test/v1", { _, _, _, _ -> VezmoApi.Response(status, body) }, Dispatchers.Unconfined)
        val gone = runCatching { api(404, """{"message":"Not found"}""").subscription("t") }.exceptionOrNull() as VezmoApiError
        assertEquals(VezmoError.Code.Expired, gone.code)
        val done = runCatching { api(400, """{"message":"This subscription is already set up."}""").subscription("t") }.exceptionOrNull() as VezmoApiError
        assertEquals(VezmoError.Code.AlreadyPaid, done.code)
        val config = api(200, """{"success":true,"data":${view()}}""").subscription("t")
        assertEquals("SUB-1", config.subscription?.ref)
        assertTrue(config.subscription!!.trial)
    }

    @Test
    fun `reads a free trial's setup intent for confirm`() {
        assertEquals("seti_1AbC", intentIdOf("seti_1AbC_secret_xyz"))
        assertEquals("pi_1AbC", intentIdOf("pi_1AbC_secret_xyz"))
    }

    @Test
    fun `dates in the buyer's own format`() {
        val utc = TimeZone.getTimeZone("UTC")
        assertEquals("Oct 23, 2026", dateText("2026-10-23T07:00:00.000Z", Locale.US, utc))
        assertEquals("23 Oct 2026", dateText("2026-10-23T07:00:00Z", Locale.UK, utc))
        assertEquals("", dateText(null))
        assertEquals("", dateText("soon"))
    }
}
