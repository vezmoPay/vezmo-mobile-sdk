package com.vezmo.checkout

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private val BASE = config(enabledMethods = setOf("card", "klarna"), localOffer = null)

/** The API, faked: each answer can be swapped, every call is recorded. */
private class FakeApi : CheckoutApi {
    val calls = mutableListOf<String>()
    var checkout: suspend () -> CheckoutConfig = { BASE }
    var pay: () -> PayResponse = { error("no pay answer") }
    val statuses = ArrayDeque<SessionStatus>()
    var status = SessionStatus("succeeded", "pay_1", "VT1")
    var payArgs: List<String?>? = null
    var qrArgs: Pair<QrMethod, QrStart>? = null
    var confirmError: VezmoApiError? = null
    var intentError: VezmoApiError? = null

    override suspend fun checkout(token: String, currency: String?): CheckoutConfig {
        calls += "checkout"
        return checkout()
    }

    override suspend fun pay(token: String, paymentMethodId: String, localOffer: String?, returnUrl: String?): PayResponse {
        calls += "pay"
        payArgs = listOf(token, paymentMethodId, localOffer, returnUrl)
        return pay()
    }

    override suspend fun intent(token: String, localOffer: String?): SessionIntent {
        calls += "intent:$token:$localOffer"
        intentError?.let { throw it }
        return SessionIntent("pi_7", "pi_7_secret_q", "acct_1", false)
    }

    override suspend fun startQr(method: QrMethod, start: QrStart): QrPayment {
        qrArgs = method to start
        return QrPayment("requires_action", null, null, "upi://pay?pa=x", null)
    }

    override fun checkoutPageUrl(token: String) = "https://api.test/v1/secure-payments/$token"

    override suspend fun confirm(token: String, paymentIntentId: String) {
        calls += "confirm:$token:$paymentIntentId"
        confirmError?.let { throw it }
    }

    override suspend fun status(token: String): SessionStatus {
        calls += "status"
        return statuses.removeFirstOrNull() ?: status
    }

    override suspend fun subscription(token: String, currency: String?): CheckoutConfig = error("not a subscription")

    override suspend fun subscriptionPay(token: String, paymentMethodId: String, localOffer: String?): PayResponse = error("not a subscription")

    override suspend fun subscriptionConfirm(token: String, intentId: String): CheckoutResult = error("not a subscription")
}

private class FakeElement : ElementPort {
    var confirms = 0
    var clears = 0
    val resolved = mutableListOf<Pair<String?, String?>>()

    override fun confirm() {
        confirms++
    }

    override fun resolveConfirmation(clientSecret: String?, errorMessage: String?) {
        resolved += clientSecret to errorMessage
    }

    override fun clearSelection() {
        clears++
    }
}

private class FakeCardFlow : CardFlowPort {
    var presents = 0
    var confirms = 0
    var bankPresents = 0
    var bankConfirms = 0
    val resolved = mutableListOf<Pair<String?, String?>>()

    override fun presentCard() {
        presents++
    }

    override fun confirmCard() {
        confirms++
    }

    override fun presentBank() {
        bankPresents++
    }

    override fun confirmBank() {
        bankConfirms++
    }

    override fun resolveConfirmation(clientSecret: String?, errorMessage: String?) {
        resolved += clientSecret to errorMessage
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
private class Setup(scope: TestScope) {
    val api = FakeApi()
    val element = FakeElement()
    val cardFlow = FakeCardFlow()
    val session = CheckoutSession(api, "tok", UnconfinedTestDispatcher(scope.testScheduler)).also {
        it.attachElement(element)
        it.attachCardFlow(cardFlow)
    }
    val snap get() = session.state.value
}

class CheckoutSessionTest {
    private fun test(block: suspend TestScope.(Setup) -> Unit) = runTest {
        val t = Setup(this)
        t.session.load()
        try {
            block(t)
        } finally {
            t.session.dispose()
        }
    }

    @Test
    fun `loads the session and offers card plus the enabled methods`() = test { t ->
        assertEquals(SessionPhase.Ready(null), t.snap.phase)
        assertEquals(Charge(4900, "USD", null), t.snap.charge)
        assertEquals(listOf("card", "klarna"), t.snap.methods?.elementTypes)
    }

    @Test
    fun `a payment the server finished - hands the engine the secret, the result is the server's`() = test { t ->
        val method = PaidMethod("card", "visa", "4242", null)
        t.api.pay = { PayResponse("succeeded", "pay_1", "VT1", "pi_1_secret_a", method) }
        t.session.setOption("Klarna")
        t.session.pay()
        assertEquals(1, t.element.confirms)
        // A method that leaves the app: the engine's own way back into the sheet goes to Vezmo with it.
        t.session.onPaymentMethod("pm_1", "stripesdk://payment_return_url/com.acme.shop")
        // The receipt's Visa mark and last four come from the server's reading of the payment.
        assertEquals(method, t.snap.paidMethod)
        assertEquals(listOf("tok", "pm_1", null, "stripesdk://payment_return_url/com.acme.shop"), t.api.payArgs)
        assertEquals(listOf<Pair<String?, String?>>("pi_1_secret_a" to null), t.element.resolved)
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), t.snap.phase)
        assertFalse(t.api.calls.any { it.startsWith("confirm") })
    }

    @Test
    fun `3D Secure finished on the device is recorded with confirm, then read back`() = test { t ->
        t.api.pay = { PayResponse("requires_action", "pay_1", null, "pi_9_secret_b", null) }
        t.session.setOption("Klarna")
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertTrue("confirm:tok:pi_9" in t.api.calls)
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), t.snap.phase)
    }

    @Test
    fun `the engine losing a redirect step it finished - the server's answer wins`() = test { t ->
        t.api.pay = { PayResponse("requires_action", "pay_1", null, "pi_9_secret_b", null) }
        t.session.setOption("Cash App Pay")
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        t.session.onConfirmResult(ConfirmStatus.Failed, "engine text")
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), t.snap.phase)

        // Not paid after all: the buyer can try again.
        t.api.status = SessionStatus("open", "pay_1", null)
        val u = Setup(this)
        u.api.pay = { PayResponse("requires_action", "pay_1", null, "pi_9_secret_b", null) }
        u.api.status = SessionStatus("open", "pay_1", null)
        u.session.load()
        u.session.setOption("Cash App Pay")
        u.session.pay()
        u.session.onPaymentMethod("pm_1")
        u.session.onConfirmResult(ConfirmStatus.Failed, "")
        assertEquals(SessionPhase.Ready(DECLINED), u.snap.phase)
        u.session.dispose()
    }

    @Test
    fun `a decline after 3D Secure on the device - the reason is the server's, recorded by its confirm step`() = test { t ->
        t.api.pay = { PayResponse("requires_action", "pay_1", null, "pi_9_secret_b", null) }
        t.api.status = SessionStatus("failed", "pay_1", null)
        t.api.confirmError = VezmoApiError(VezmoError.Code.Declined, "Payment declined by your bank (issuer).", 400)
        t.session.chooseCard()
        t.session.setCard(CardChoice("•••• 0002", null))
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        // The engine's own words differ by platform ("Your payment method was declined." here, another on iPhone).
        t.session.onConfirmResult(ConfirmStatus.Failed, "Your payment method was declined.")
        assertTrue("confirm:tok:pi_9" in t.api.calls)
        assertEquals(SessionPhase.Ready(VezmoError(VezmoError.Code.Declined, "Payment declined by your bank (issuer).")), t.snap.phase)

        // The confirm step can't say why (offline): the engine's words, as before.
        val u = Setup(this)
        u.api.pay = { PayResponse("requires_action", "pay_1", null, "pi_9_secret_b", null) }
        u.api.status = SessionStatus("failed", "pay_1", null)
        u.api.confirmError = VezmoApiError(VezmoError.Code.Network, "Check your connection and try again.", null)
        u.session.load()
        u.session.setOption("Klarna")
        u.session.pay()
        u.session.onPaymentMethod("pm_1")
        u.session.onConfirmResult(ConfirmStatus.Failed, "engine text")
        assertEquals(SessionPhase.Ready(VezmoError(VezmoError.Code.Declined, "engine text")), u.snap.phase)
        u.session.dispose()
    }

    @Test
    fun `a decline at our confirm after 3D Secure (the engine completed) - the sheet stays ready, in our words`() = test { t ->
        // A card our server confirms (manual confirmation): back from 3D Secure the engine reports completed, and the
        // bank's answer comes from our confirm step.
        t.api.pay = { PayResponse("requires_action", "pay_1", null, "pi_9_secret_b", null) }
        t.api.status = SessionStatus("failed", "pay_1", null)
        t.api.confirmError = VezmoApiError(VezmoError.Code.Declined, "Payment declined by your bank (issuer).", 400)
        t.session.chooseCard()
        t.session.setCard(CardChoice("•••• 0002", null))
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertTrue("confirm:tok:pi_9" in t.api.calls)
        assertEquals(SessionPhase.Ready(VezmoError(VezmoError.Code.Declined, "Payment declined by your bank (issuer).")), t.snap.phase)

        // A step still running: the status says how it stands, as before.
        val u = Setup(this)
        u.api.pay = { PayResponse("requires_action", "pay_1", null, "pi_9_secret_b", null) }
        u.api.confirmError = VezmoApiError(VezmoError.Code.Declined, "Still verifying.", 400, "requires_action")
        u.session.load()
        u.session.setOption("Klarna")
        u.session.pay()
        u.session.onPaymentMethod("pm_1")
        u.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), u.snap.phase)
        u.session.dispose()
    }

    @Test
    fun `the session loading late never replaces a result that arrived first (back after the process was killed)`() = runTest {
        val gate = CompletableDeferred<Unit>()
        val t = Setup(this)
        t.api.checkout = { gate.await(); BASE }
        val loading = launch { t.session.load() }
        runCurrent()
        // The engine's result for a payment finished in the browser, before the session has loaded again.
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), t.snap.phase)
        gate.complete(Unit)
        loading.join()
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), t.snap.phase)
        assertEquals(BASE, t.snap.config)

        // Nor does a load that fails (the session reads as already paid now).
        val u = Setup(this)
        val gate2 = CompletableDeferred<Unit>()
        u.api.checkout = { gate2.await(); throw VezmoApiError(VezmoError.Code.AlreadyPaid, "Already paid", 409) }
        val loading2 = launch { u.session.load() }
        runCurrent()
        u.session.onConfirmResult(ConfirmStatus.Completed, "")
        gate2.complete(Unit)
        loading2.join()
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), u.snap.phase)
        t.session.dispose()
        u.session.dispose()
    }

    @Test
    fun `a failure before Vezmo was asked never reads in the engine's words, nor the engine not set up`() = test { t ->
        t.session.chooseCard()
        t.session.setCard(CardChoice("•••• 4242", null))
        t.session.pay()
        // The card flow refused (it was being set up again after a currency switch): no /pay was made.
        t.session.onConfirmResult(ConfirmStatus.Failed, "FlowController is not configured, or has a configuration update in flight.")
        assertEquals(SessionPhase.Ready(VezmoError(VezmoError.Code.Unknown, DEFAULT_ERROR)), t.snap.phase)
        assertFalse("status" in t.api.calls)
        // The card form couldn't open: our words.
        t.session.engineNotReady()
        assertEquals(SessionPhase.Ready(VezmoError(VezmoError.Code.Unknown, ENGINE_LOADING)), t.snap.phase)
    }

    @Test
    fun `a decline goes back to the engine in our words and leaves the sheet ready to retry`() = test { t ->
        t.api.pay = { throw VezmoApiError(VezmoError.Code.Declined, "Your bank declined this card.", 400) }
        t.session.setOption("Klarna")
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        assertEquals(listOf<Pair<String?, String?>>(null to "Your bank declined this card."), t.element.resolved)
        t.session.onConfirmResult(ConfirmStatus.Failed, "processor text")
        assertEquals(SessionPhase.Ready(VezmoError(VezmoError.Code.Declined, "Your bank declined this card.")), t.snap.phase)
    }

    @Test
    fun `a changed local price refreshes the offer and asks the buyer to pay again`() = test { t ->
        t.api.pay = { throw VezmoApiError(VezmoError.Code.Unknown, "Price changed", 409, "local_price_changed") }
        t.session.setOption("Klarna")
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        assertTrue(t.element.resolved.single().second!!.contains("price in your currency"))
        assertEquals(2, t.api.calls.count { it == "checkout" })
    }

    @Test
    fun `canceling the engine returns to the sheet, an expired session closes it`() = test { t ->
        t.session.setOption("Klarna")
        t.session.pay()
        t.session.onConfirmResult(ConfirmStatus.Canceled, "")
        assertEquals(SessionPhase.Ready(null), t.snap.phase)

        t.api.pay = { throw VezmoApiError(VezmoError.Code.Expired, "Secure-payments token has expired", 410) }
        t.session.pay()
        t.session.onPaymentMethod("pm_2")
        val closed = t.snap.phase as SessionPhase.Closed
        assertEquals(VezmoError.Code.Expired, (closed.result as CheckoutResult.Failed).error.code)
    }

    @Test
    fun `the buyer's own currency - the charge and methods follow the choice`() = test { t ->
        val u = Setup(this)
        u.api.checkout = { BASE.copy(localOffer = INR_OFFER) }
        u.session.load()
        assertEquals(Charge(420000, "INR", "offer_sealed"), u.snap.charge)
        assertEquals(listOf("card"), u.snap.methods?.elementTypes)
        u.session.choosePayLocal(false)
        assertEquals("USD", u.snap.charge?.currency)
        assertEquals(listOf("card", "klarna"), u.snap.methods?.elementTypes)
        u.session.dispose()
    }

    @Test
    fun `one method at a time - UPI unselects the element, picking an element method leaves UPI`() = test { t ->
        t.session.setOption("Klarna")
        assertTrue(t.snap.canPay)
        assertEquals("Klarna", t.snap.option)
        assertEquals(Method.Element, t.snap.method)
        t.session.chooseMethod(Method.Upi)
        assertEquals(1, t.element.clears)
        t.session.setOption(null) // the element reports the cleared selection
        assertFalse(t.snap.canPay)
        assertNull(t.snap.option)
        assertEquals(Method.Upi, t.snap.method)
        t.session.setOption("Cash App")
        assertEquals(Method.Element, t.snap.method)
        // The receipt keeps what was paid with, though the element clears its selection after paying.
        t.session.pay()
        t.session.setOption(null)
        assertEquals("Cash App", t.snap.paidWith)
    }

    @Test
    fun `the Instant ACH row - opens the bank step, the linked account becomes the selection, and pays through it`() = runTest {
        val t = Setup(this)
        t.api.checkout = { config(enabledMethods = setOf("card", "klarna", "instantAch")) }
        t.session.load()
        // In the buyer's own currency there is no Instant ACH; in dollars there is.
        assertFalse(t.snap.methods!!.instantAch)
        t.session.choosePayLocal(false)
        assertTrue(t.snap.methods!!.instantAch)
        t.session.chooseBank()
        assertEquals(1, t.cardFlow.bankPresents)
        assertFalse(CheckoutSession.canPay(t.snap))
        // The bank step closed without a bank: nothing chosen.
        t.session.setBank(null)
        assertEquals(Method.Element, t.snap.method)
        val bank = CardChoice("•••• 6789", null)
        t.session.setBank(bank)
        assertEquals(Method.InstantAch, t.snap.method)
        assertEquals(bank, t.snap.bank)
        assertTrue(t.element.clears > 0)
        assertTrue(CheckoutSession.canPay(t.snap))
        t.api.pay = { PayResponse("succeeded", "pay_1", "VT1", "pi_1_secret_b", PaidMethod("instantAch", null, "6789", null)) }
        t.session.pay()
        assertEquals(1, t.cardFlow.bankConfirms)
        assertEquals(0, t.cardFlow.confirms)
        assertEquals(0, t.element.confirms)
        assertEquals("Instant ACH", t.snap.paidWith)
        t.session.onPaymentMethod("pm_b")
        // The card flow holds the bank step, so it answers the confirmation.
        assertEquals(listOf<Pair<String?, String?>>("pi_1_secret_b" to null), t.cardFlow.resolved)
        assertEquals("pm_b", t.api.payArgs!![1])
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), t.snap.phase)
        assertEquals("instantAch", t.snap.paidMethod?.type)
        t.session.dispose()
    }

    @Test
    fun `Instant ACH leaves when the buyer pays in their own currency`() = runTest {
        val t = Setup(this)
        t.api.checkout = { config(enabledMethods = setOf("card", "instantAch")) }
        t.session.load()
        t.session.choosePayLocal(false)
        t.session.chooseBank()
        t.session.setBank(CardChoice("•••• 6789", null))
        assertEquals(Method.InstantAch, t.snap.method)
        t.session.choosePayLocal(true)
        assertEquals(Method.Element, t.snap.method)
        assertFalse(CheckoutSession.canPay(t.snap))
        t.session.dispose()
    }

    @Test
    fun `the Card row - opens the card form, the typed card becomes the selection, and pays through it`() = test { t ->
        t.session.chooseCard()
        assertEquals(1, t.cardFlow.presents)
        assertFalse(CheckoutSession.canPay(t.snap))
        val card = CardChoice("•••• 4242", null)
        t.session.setCard(card)
        assertEquals(Method.Card, t.snap.method)
        assertEquals(card, t.snap.card)
        assertEquals(1, t.element.clears)
        // Another method in the element leaves the Card row but keeps the card for later.
        t.session.setOption("Klarna")
        assertEquals(Method.Element, t.snap.method)
        assertEquals(card, t.snap.card)
        // A re-sent card (the amount changed) does not take the selection back.
        t.session.setCard(card)
        assertEquals(Method.Element, t.snap.method)
        t.session.chooseCard()
        assertEquals(Method.Card, t.snap.method)
        t.session.pay()
        assertEquals(1, t.cardFlow.confirms)
        assertEquals(0, t.element.confirms)
        assertEquals("•••• 4242", t.snap.paidWith)
    }

    @Test
    fun `the card flow answers its own confirmation (card form or wallet), the element its own`() = test { t ->
        t.api.pay = { PayResponse("requires_action", "pay_1", null, "pi_1_secret_w", null) }
        t.session.walletStarted("google_pay")
        assertEquals(SessionPhase.Paying, t.snap.phase)
        assertEquals("Google Pay", t.snap.paidWith)
        t.session.onPaymentMethod("pm_w")
        assertEquals(listOf<Pair<String?, String?>>("pi_1_secret_w" to null), t.cardFlow.resolved)
        assertTrue(t.element.resolved.isEmpty())
    }

    @Test
    fun `UPI - starts on the session intent, waits for the bank app, records it when paid`() = test { t ->
        val u = Setup(this)
        u.api.checkout = { BASE.copy(enabledMethods = setOf("card", "upi"), localOffer = INR_OFFER) }
        u.session.load()
        assertTrue(u.snap.methods!!.upi)
        u.session.chooseMethod(Method.Upi)
        u.api.statuses += SessionStatus("requires_action", "pay_1", null)

        val billing = QrBilling(name = "Asha Rao", line1 = "12 MG Road", country = "IN")
        u.session.payWithQr(QrMethod.Upi, billing)
        assertTrue("intent:tok:offer_sealed" in u.api.calls)
        assertEquals(
            QrMethod.Upi to QrStart("pi_7_secret_q", "acct_1", false, "https://api.test/v1/secure-payments/tok", billing),
            u.api.qrArgs,
        )
        val waiting = u.snap.phase as SessionPhase.Waiting
        assertEquals(QrMethod.Upi, waiting.method)
        assertEquals("upi://pay?pa=x", waiting.qr.link)

        u.session.checkNow() // still in the bank app
        assertTrue(u.snap.phase is SessionPhase.Waiting)
        u.session.checkNow() // paid
        assertTrue("confirm:tok:pi_7" in u.api.calls)
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), u.snap.phase)
        u.session.dispose()
    }

    @Test
    fun `UPI with an offer that ran out - the new offer is fetched, then paid with, never the stale one again`() = test { t ->
        val u = Setup(this)
        u.api.checkout = { BASE.copy(enabledMethods = setOf("card", "upi"), localOffer = INR_OFFER) }
        u.session.load()
        u.session.chooseMethod(Method.Upi)
        u.api.intentError = VezmoApiError(VezmoError.Code.Unknown, "Price changed", 409, "local_price_changed")
        u.api.checkout = { BASE.copy(enabledMethods = setOf("card", "upi"), localOffer = INR_OFFER.copy(amountMinor = 421000, token = "offer_new")) }
        val billing = QrBilling(name = "Asha Rao", line1 = "12 MG Road", country = "IN")
        u.session.payWithQr(QrMethod.Upi, billing)
        val ready = u.snap.phase as SessionPhase.Ready
        assertTrue(ready.error!!.message.contains("price in your currency"))
        assertEquals(Charge(421000, "INR", "offer_new"), u.snap.charge)
        assertEquals(Method.Upi, u.snap.method)

        u.api.intentError = null
        u.session.payWithQr(QrMethod.Upi, billing)
        assertEquals(listOf("intent:tok:offer_sealed", "intent:tok:offer_new"), u.api.calls.filter { it.startsWith("intent") })
        assertTrue(u.snap.phase is SessionPhase.Waiting)
        u.session.dispose()
    }

    // ── closing while UPI or Pix may still be paid ─────────────────────────
    private suspend fun TestScope.upi(): Setup {
        val u = Setup(this)
        u.api.checkout = { BASE.copy(enabledMethods = setOf("card", "upi"), localOffer = INR_OFFER) }
        u.session.load()
        u.session.chooseMethod(Method.Upi)
        u.session.payWithQr(QrMethod.Upi, QrBilling(name = "Asha Rao", line1 = "12 MG Road", country = "IN"))
        assertTrue(u.snap.phase is SessionPhase.Waiting)
        return u
    }

    @Test
    fun `closing while UPI waits on the bank app is Processing, never Canceled`() = test { _ ->
        val u = upi()
        u.api.status = SessionStatus("requires_action", "pay_1", null)
        assertEquals(CheckoutResult.Processing("pay_1"), u.session.closeRequested())
        assertFalse(u.api.calls.any { it.startsWith("confirm") })
        u.session.dispose()
    }

    @Test
    fun `closing after the UPI payment went through shows the receipt instead`() = test { _ ->
        val u = upi()
        assertNull(u.session.closeRequested())
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), u.snap.phase)
        assertTrue("confirm:tok:pi_7" in u.api.calls)
        u.session.dispose()
    }

    @Test
    fun `closing after giving up on UPI is Canceled, unless it was paid meanwhile`() = test { _ ->
        val u = upi()
        u.session.stopWaiting()
        u.api.status = SessionStatus("requires_action", "pay_1", null)
        assertEquals(CheckoutResult.Canceled, u.session.closeRequested())
        u.api.status = SessionStatus("processing", "pay_1", null)
        assertNull(u.session.closeRequested())
        assertEquals(SessionPhase.Done(CheckoutResult.Processing("pay_1")), u.snap.phase)
        u.session.dispose()
    }

    @Test
    fun `closing with no UPI or Pix started is Canceled, without asking Vezmo`() = test { t ->
        assertEquals(CheckoutResult.Canceled, t.session.closeRequested())
        assertFalse("status" in t.api.calls)
    }

    // ── no answer from /pay ────────────────────────────────────────────────
    private val noAnswer = VezmoApiError(VezmoError.Code.Network, "Check your connection and try again.", null)

    @Test
    fun `a pay with no answer that went through all the same is the payment, not a failure`() = test { t ->
        t.api.pay = { throw noAnswer }
        t.session.setOption("Klarna")
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        assertEquals(listOf<Pair<String?, String?>>(null to ""), t.element.resolved)
        t.session.onConfirmResult(ConfirmStatus.Failed, "engine text")
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), t.snap.phase)
    }

    @Test
    fun `an engine failure after Vezmo took the payment is the payment, never the engine's words`() = test { t ->
        t.api.pay = { PayResponse("succeeded", "pay_1", "VT1", "pi_1_secret_a", null) }
        t.session.setOption("Klarna")
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        t.session.onConfirmResult(ConfirmStatus.Failed, "No launcher for a was found, did you call register?")
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), t.snap.phase)
    }

    @Test
    fun `a pay with no answer that didn't go through is the network error, and the next try starts clean`() = test { t ->
        t.api.pay = { throw noAnswer }
        t.api.status = SessionStatus("open", "pay_1", null)
        t.session.setOption("Klarna")
        t.session.pay()
        t.session.onPaymentMethod("pm_1")
        assertEquals(1, t.api.calls.count { it == "status" })
        assertEquals(listOf<Pair<String?, String?>>(null to noAnswer.message), t.element.resolved)
        t.session.onConfirmResult(ConfirmStatus.Failed, "engine text")
        assertEquals(SessionPhase.Ready(noAnswer.toVezmoError()), t.snap.phase)

        t.api.pay = { PayResponse("succeeded", "pay_1", "VT2", "pi_1_secret_a", null) }
        t.session.pay()
        t.session.onPaymentMethod("pm_2")
        t.session.onConfirmResult(ConfirmStatus.Completed, "")
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT2")), t.snap.phase)
    }

    // ── the sheet open again after its activity or the process was gone ───
    @Test
    fun `reopened after the process was gone mid-payment - a paid session is the payment, not already paid`() = test { _ ->
        val paid = VezmoApiError(VezmoError.Code.AlreadyPaid, "This payment has already been made.", 409, "already_paid")
        val reopened = Setup(this)
        reopened.api.checkout = { throw paid }
        reopened.session.load(recovering = true)
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), reopened.snap.phase)
        reopened.session.dispose()
        // A session prepared fresh that is already paid stays "already paid" (the app shouldn't present it).
        val fresh = Setup(this)
        fresh.api.checkout = { throw paid }
        fresh.session.load()
        assertEquals(SessionPhase.Closed(CheckoutResult.Failed(paid.toVezmoError())), fresh.snap.phase)
        fresh.session.dispose()
    }

    @Test
    fun `the UPI watcher checks by itself and stops once paid`() = test { t ->
        val u = Setup(this)
        u.api.checkout = { BASE.copy(enabledMethods = setOf("card", "upi"), localOffer = INR_OFFER) }
        u.session.load()
        u.session.chooseMethod(Method.Upi)
        u.api.statuses += SessionStatus("requires_action", "pay_1", null)
        u.session.payWithQr(QrMethod.Upi, QrBilling(name = "Asha Rao", line1 = "12 MG Road"))
        testScheduler.advanceTimeBy(4_100) // two ticks: still waiting, then paid
        assertEquals(SessionPhase.Done(CheckoutResult.Succeeded("pay_1", "VT1")), u.snap.phase)
        val checks = u.api.calls.count { it == "status" }
        testScheduler.advanceTimeBy(60_000)
        assertEquals(checks, u.api.calls.count { it == "status" })
        u.session.dispose()
    }
}
