package com.vezmo.checkout

import android.graphics.Bitmap
import android.graphics.Color
import android.util.Base64
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The sheet's states that a sandbox card payment never reaches (UPI and Pix, the other results, a failed load),
 * drawn with a fake API and saved as screenshots (CI pulls them from the emulator). The engine is left alone.
 */
@RunWith(AndroidJUnit4::class)
class SheetStatesTest {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()

    private var session: CheckoutSession? = null

    @After
    fun dispose() {
        session?.dispose()
    }

    private class FakeApi(
        val config: () -> CheckoutConfig,
        val qr: QrPayment = QrPayment("requires_action", null, null, null, null),
        val startError: VezmoApiError? = null,
        var status: SessionStatus = SessionStatus("requires_action", "pay_1", null),
        val payAnswer: PayResponse? = null,
    ) : CheckoutApi {
        override suspend fun checkout(token: String, currency: String?) = config()

        override suspend fun pay(token: String, paymentMethodId: String, localOffer: String?, returnUrl: String?): PayResponse =
            payAnswer ?: error("not used")

        override suspend fun intent(token: String, localOffer: String?) = SessionIntent("pi_7", "pi_7_secret_q", null, false)

        override suspend fun startQr(method: QrMethod, start: QrStart): QrPayment = startError?.let { throw it } ?: qr

        override fun checkoutPageUrl(token: String) = "https://api.test/v1/secure-payments/$token"

        override suspend fun confirm(token: String, paymentIntentId: String) = Unit

        override suspend fun status(token: String) = status

        // A subscription checkout reads the same config (with its plan).
        override suspend fun subscription(token: String, currency: String?) = config()

        override suspend fun subscriptionPay(token: String, paymentMethodId: String, localOffer: String?): PayResponse = error("not used")

        override suspend fun subscriptionConfirm(token: String, intentId: String): CheckoutResult = error("not used")
    }

    private fun config(
        offer: LocalOffer? = null,
        methods: Set<String> = setOf("card"),
    ) = CheckoutConfig(
        publishableKey = "pk_test_x",
        connectedAccountId = null,
        livemode = false,
        amountMinor = 4900,
        currency = "USD",
        title = "Vezmo SDK demo order",
        merchantName = "Northwind Audio",
        enabledMethods = methods,
        customerName = "Asha Rao",
        customerEmail = null,
        theme = null,
        paymentId = "pay_1",
        localOffer = offer,
    )

    private val inr = LocalOffer("INR", 420_000, 85.7143, "IN", listOf("upi"), "offer_inr")
    private val brl = LocalOffer("BRL", 26_950, 5.5, "BR", listOf("pix"), "offer_brl")

    private fun open(
        api: CheckoutApi,
        dark: Boolean = false,
        subscription: Boolean = false,
        /** The phone's font size (Settings → Display → Font size), 1 by default. */
        fontScale: Float = 1f,
        drive: suspend CheckoutSession.() -> Unit = { load() },
    ): CheckoutSession {
        val s = CheckoutSession(api, "tok", "vezmoexample://vezmo", subscription = subscription)
        session = s
        runBlocking { s.drive() }
        rule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                val engine = rememberEngine(s)
                CheckoutSheet(s, engine, CheckoutRequest("tok", null, VezmoConfiguration()), dark, onClose = {}, useEngine = false)
            }
        }
        return s
    }

    private fun shoot(name: String) {
        rule.waitForIdle()
        val bitmap = rule.onRoot().captureToImage().asAndroidBitmap()
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("states")!!
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    /** A stand-in QR code: finder squares and a fixed pattern, as a PNG data URI. */
    private fun qrPng(): String {
        val n = 25
        val k = 12
        val bmp = Bitmap.createBitmap(n * k, n * k, Bitmap.Config.ARGB_8888)
        bmp.eraseColor(Color.WHITE)
        fun finder(x: Int, y: Int, i: Int, j: Int) = i in x until x + 7 && j in y until y + 7 &&
            (i == x || i == x + 6 || j == y || j == y + 6 || (i in x + 2..x + 4 && j in y + 2..y + 4))
        for (i in 0 until n) for (j in 0 until n) {
            val inFinderZone = (i < 8 && j < 8) || (i >= n - 8 && j < 8) || (i < 8 && j >= n - 8)
            val on = if (inFinderZone) finder(0, 0, i, j) || finder(n - 7, 0, i, j) || finder(0, n - 7, i, j) else (i * 7 + j * 13 + i * j) % 3 == 0
            if (on) for (x in 0 until k) for (y in 0 until k) bmp.setPixel(i * k + x, j * k + y, Color.BLACK)
        }
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        return "data:image/png;base64," + Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    @Test
    fun loading() {
        open(FakeApi({ config() })) { }
        shoot("loading")
    }

    @Test
    fun upiForm() {
        open(FakeApi({ config(inr, setOf("card", "upi")) })) {
            load()
            chooseMethod(Method.Upi)
        }
        rule.onNodeWithText("with UPI", substring = true).assertExists()
        shoot("upi-form")
    }

    @Test
    fun upiFormDark() {
        open(FakeApi({ config(inr, setOf("card", "upi")) }), dark = true) {
            load()
            chooseMethod(Method.Upi)
        }
        shoot("upi-form-dark")
    }

    @Test
    fun upiDeclined() {
        val declined = VezmoApiError(VezmoError.Code.Declined, "Your payment didn’t go through. Try another card or way to pay.", 402)
        open(FakeApi({ config(inr, setOf("card", "upi")) }, startError = declined)) {
            load()
            chooseMethod(Method.Upi)
            payWithQr(QrMethod.Upi, QrBilling("Asha Rao", "12 MG Road", country = "IN"))
        }
        // Below the form on a phone: the sheet scrolls it into view.
        rule.onNodeWithText("didn’t go through", substring = true).assertIsDisplayed()
        shoot("upi-declined")
    }

    /** The largest font size: the badge, the currency choice and the buttons grow with their text. */
    @Test
    fun upiFormLargeText() {
        open(FakeApi({ config(inr, setOf("card", "upi")) }), fontScale = 2f) {
            load()
            chooseMethod(Method.Upi)
        }
        shoot("upi-form-large-text")
    }

    @Test
    fun upiWaitingLargeText() {
        val qr = QrPayment("requires_action", qrPng(), System.currentTimeMillis() / 1000 + 540, "upi://pay?pa=vezmo@bank", null)
        open(FakeApi({ config(inr, setOf("card", "upi")) }, qr = qr), fontScale = 2f) {
            load()
            chooseMethod(Method.Upi)
            payWithQr(QrMethod.Upi, QrBilling("Asha Rao", "12 MG Road", country = "IN"))
        }
        shoot("upi-waiting-large-text")
    }

    @Test
    fun upiWaiting() {
        val qr = QrPayment("requires_action", qrPng(), System.currentTimeMillis() / 1000 + 540, "upi://pay?pa=vezmo@bank", null)
        open(FakeApi({ config(inr, setOf("card", "upi")) }, qr = qr)) {
            load()
            chooseMethod(Method.Upi)
            payWithQr(QrMethod.Upi, QrBilling("Asha Rao", "12 MG Road", country = "IN"))
        }
        rule.onNodeWithText("Open UPI app").assertExists()
        shoot("upi-waiting")
    }

    @Test
    fun pixWaitingDark() {
        val code = "00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Northwind6008BRASILIA62070503***6304ABCD"
        val qr = QrPayment("requires_action", qrPng(), System.currentTimeMillis() / 1000 + 45, null, code)
        open(FakeApi({ config(brl, setOf("card", "pix")) }, qr = qr), dark = true) {
            load()
            chooseMethod(Method.Pix)
            payWithQr(QrMethod.Pix, QrBilling("Ana Silva", "Rua Augusta 100", country = "BR", taxId = "12345678909"))
        }
        rule.onNodeWithText("Copy Pix code").assertExists()
        shoot("pix-waiting-dark")
    }

    @Test
    fun pixForm() {
        open(FakeApi({ config(brl, setOf("card", "pix")) })) {
            load()
            chooseMethod(Method.Pix)
        }
        rule.onNodeWithText("CPF or CNPJ").assertExists()
        shoot("pix-form")
    }

    @Test
    fun processing() {
        val api = FakeApi({ config(inr, setOf("card", "upi")) }, qr = QrPayment("requires_action", null, null, "upi://pay", null))
        open(api) {
            load()
            chooseMethod(Method.Upi)
            payWithQr(QrMethod.Upi, QrBilling("Asha Rao", "12 MG Road"))
            api.status = SessionStatus("processing", "pay_1", null)
            checkNow()
        }
        rule.onNodeWithText("Payment received").assertExists()
        shoot("result-processing")
    }

    @Test
    fun expired() {
        open(FakeApi({ throw VezmoApiError(VezmoError.Code.Expired, "Secure-payments token has expired", 410) }))
        rule.onNodeWithText("Checkout expired").assertExists()
        shoot("result-expired")
    }

    @Test
    fun alreadyPaidDark() {
        open(FakeApi({ throw VezmoApiError(VezmoError.Code.AlreadyPaid, "This checkout has already been paid.", 409) }), dark = true)
        rule.onNodeWithText("Already paid").assertExists()
        shoot("result-already-paid-dark")
    }

    private fun trial() = config().copy(
        amountMinor = 0,
        title = "Northwind Audio Club",
        subscription = SubscriptionPlan(
            ref = "SUB-7Q2K9WX",
            mode = "setup",
            planName = "Northwind Audio Club",
            recurringAmount = 9.99,
            currency = "USD",
            interval = "MONTH",
            intervalCount = 1,
            trialDays = 7,
            nextChargeAt = "2026-10-23T07:00:00.000Z",
            consentText = "I authorize Northwind Audio to charge my payment method \$9.99 every month after my 7-day free trial, until I cancel.",
        ),
    )

    @Test
    fun subscriptionTrialDark() {
        open(FakeApi({ trial() }), dark = true, subscription = true)
        rule.onNodeWithText("Start free trial").assertExists()
        shoot("subscription-trial-dark")
    }

    @Test
    fun subscriptionPendingResult() {
        open(FakeApi({ trial() }), subscription = true) {
            load()
            // A first payment still settling after 3D Secure.
            onConfirmResult(ConfirmStatus.Completed, "")
        }
        rule.onNodeWithText("Subscription received").assertExists()
        shoot("subscription-received")
    }

    /** Instant ACH in the list, before a bank is linked (the bank step itself is the engine's). */
    @Test
    fun instantAch() {
        open(FakeApi({ config(methods = setOf("card", "instantAch", "klarna")) }))
        rule.onNodeWithText("Instant ACH").assertIsDisplayed()
        rule.onNodeWithText("US bank account").assertIsDisplayed()
        shoot("instant-ach")
    }

    @Test
    fun instantAchDark() {
        open(FakeApi({ config(methods = setOf("card", "instantAch")) }), dark = true)
        shoot("instant-ach-dark")
    }

    /** The largest font size: the row's title and line stay on one line each. */
    @Test
    fun instantAchLargeText() {
        open(FakeApi({ config(methods = setOf("card", "instantAch")) }), fontScale = 2f)
        shoot("instant-ach-large-text")
    }

    @Test
    fun instantAchReceipt() {
        val paid = PayResponse("succeeded", "pay_1", "VT92TDOA", "pi_1_secret_b", PaidMethod("instantAch", null, "6789", null))
        open(FakeApi({ config(methods = setOf("card", "instantAch")) }, payAnswer = paid)) {
            load()
            onPaymentMethod("pm_b")
            onConfirmResult(ConfirmStatus.Completed, "")
        }
        rule.onNodeWithText("Instant ACH").assertIsDisplayed()
        shoot("result-instant-ach")
    }

    @Test
    fun loadFailed() {
        open(FakeApi({ config() })) {
            load()
            setElementError("offline")
        }
        rule.onNodeWithText("Couldn’t load payment options").assertExists()
        shoot("load-failed")
    }
}
