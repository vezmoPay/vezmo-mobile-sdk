package com.vezmo.checkout

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.math.roundToLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

internal const val DEFAULT_API_BASE = "https://api.vezmo.com/api/v1"

/** This SDK in the `Vezmo-SDK` header. */
internal const val DEFAULT_SDK = "android/" + BuildConfig.SDK_VERSION

/** A failed call, already in Vezmo's words (the API never names its processor to a buyer). */
internal class VezmoApiError(
    val code: VezmoError.Code,
    override val message: String,
    val httpStatus: Int?,
    /** The API's own error code when it sent one (e.g. `local_price_changed`). */
    val reason: String? = null,
) : Exception(message) {
    fun toVezmoError() = VezmoError(code, message)
}

/** The buyer-side calls a checkout makes (faked in tests). */
internal interface CheckoutApi {
    suspend fun checkout(token: String, currency: String? = null): CheckoutConfig

    suspend fun pay(token: String, paymentMethodId: String, localOffer: String?, returnUrl: String?): PayResponse

    suspend fun intent(token: String, localOffer: String?): SessionIntent

    suspend fun startQr(method: QrMethod, start: QrStart): QrPayment

    fun checkoutPageUrl(token: String): String

    suspend fun confirm(token: String, paymentIntentId: String)

    suspend fun status(token: String): SessionStatus

    // ── a subscription checkout (its token) ──
    /** The plan, the first charge or free trial, the keys. A used or unknown link reads as expired. */
    suspend fun subscription(token: String, currency: String? = null): CheckoutConfig

    /** Subscribe: Vezmo confirms the first payment, or a free trial's card, with the payment method (`pm_…`). */
    suspend fun subscriptionPay(token: String, paymentMethodId: String, localOffer: String?): PayResponse

    /** Records a subscription start finished on the device (after 3D Secure). */
    suspend fun subscriptionConfirm(token: String, intentId: String): CheckoutResult
}

/**
 * The buyer-side calls of an API checkout session. Everything is scoped by the session's client token; no merchant
 * key ever reaches the app.
 */
internal class VezmoApi(
    private val apiBase: String = DEFAULT_API_BASE,
    private val transport: Transport = HttpTransport,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /** Sent as `Vezmo-SDK` so a payment records which SDK took it: this one, or a Vezmo wrapper around it. */
    private val sdk: String = DEFAULT_SDK,
) : CheckoutApi {
    /** One HTTP exchange. Throws [IOException] when there is no answer. */
    fun interface Transport {
        fun send(method: String, url: String, headers: Map<String, String>, body: String?): Response
    }

    data class Response(val status: Int, val body: String)

    private suspend fun call(method: String, path: String, body: JSONObject? = null): JSONObject {
        val headers = buildMap {
            put("Accept", "application/json")
            if (body != null) put("Content-Type", "application/json")
            put("Vezmo-SDK", sdk)
        }
        val res =
            try {
                withContext(io) { transport.send(method, "$apiBase$path", headers, body?.toString()) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                throw VezmoApiError(VezmoError.Code.Network, "Check your connection and try again.", null)
            }
        val json = try {
            JSONObject(res.body)
        } catch (_: JSONException) {
            null // an empty or non-JSON body
        }
        if (res.status in 200..299 && json?.opt("success") != false) return json?.optJSONObject("data") ?: json ?: JSONObject()
        val first = json?.optJSONArray("errors")?.optJSONObject(0)
        val message = json?.str("message")?.ifEmpty { null }
            ?: first?.str("message")?.ifEmpty { null }
            ?: "Something went wrong. Please try again."
        throw VezmoApiError(codeFor(res.status, first?.str("code")), message, res.status, first?.str("code"))
    }

    override suspend fun checkout(token: String, currency: String?): CheckoutConfig {
        val q = "redirectMethods=1" + (currency?.let { "&currency=${enc(it)}" } ?: "")
        return CheckoutConfig.from(call("POST", "/secure-payments/${enc(token)}/checkout?$q"))
    }

    override suspend fun pay(token: String, paymentMethodId: String, localOffer: String?, returnUrl: String?): PayResponse {
        val body = JSONObject()
            .put("paymentMethodId", paymentMethodId)
            .put("integration", INTEGRATION)
        if (!localOffer.isNullOrEmpty()) body.put("localOffer", localOffer)
        // The payment engine's own return link, for a method that leaves the app (see engineReturnUrl); none for a card.
        if (!returnUrl.isNullOrEmpty()) body.put("returnUrl", returnUrl)
        return PayResponse.from(call("POST", "/secure-payments/${enc(token)}/pay", body))
    }

    /** The session's intent, made or reused (UPI and Pix start from it). */
    override suspend fun intent(token: String, localOffer: String?): SessionIntent {
        val body = JSONObject().apply { if (!localOffer.isNullOrEmpty()) put("localOffer", localOffer) }
        return SessionIntent.from(call("POST", "/secure-payments/${enc(token)}/intent?redirectMethods=1", body))
    }

    /** Start UPI or Pix on the intent: the UPI app link, or the Pix code to paste in a bank app. */
    override suspend fun startQr(method: QrMethod, start: QrStart): QrPayment {
        val body = JSONObject().put("clientSecret", start.clientSecret)
        start.connectedAccountId?.let { body.put("connectedAccountId", it) }
        body.put("livemode", start.livemode).put("returnUrl", start.returnUrl).put("billing", start.billing.toJson())
        return QrPayment.from(call("POST", "/checkout/${method.key}", body))
    }

    /** The session's own checkout page (https): where UPI and Pix send a buyer who comes back by browser. */
    override fun checkoutPageUrl(token: String) = "$apiBase/secure-payments/${enc(token)}"

    /** Records a payment that finished on the device (after 3D Secure or a redirect). */
    override suspend fun confirm(token: String, paymentIntentId: String) {
        call("POST", "/secure-payments/${enc(token)}/confirm", JSONObject().put("paymentIntentId", paymentIntentId).put("integration", INTEGRATION))
    }

    override suspend fun status(token: String) = SessionStatus.from(call("GET", "/secure-payments/${enc(token)}/status"))

    override suspend fun subscription(token: String, currency: String?): CheckoutConfig {
        val q = currency?.let { "?currency=${enc(it)}" } ?: ""
        val json = try {
            call("GET", "/subscription-checkout/${enc(token)}$q")
        } catch (e: VezmoApiError) {
            if (e.httpStatus == 404) throw VezmoApiError(VezmoError.Code.Expired, "This subscription link is no longer valid.", 404)
            if (e.httpStatus == 400 && e.message.contains("already set up", ignoreCase = true)) {
                throw VezmoApiError(VezmoError.Code.AlreadyPaid, "This subscription is already set up.", 400)
            }
            throw e
        }
        return CheckoutConfig.fromSubscription(json)
    }

    override suspend fun subscriptionPay(token: String, paymentMethodId: String, localOffer: String?): PayResponse {
        val body = JSONObject()
            .put("paymentMethodId", paymentMethodId)
            .put("integration", INTEGRATION)
        if (!localOffer.isNullOrEmpty()) body.put("localOffer", localOffer)
        return PayResponse.fromSubscription(call("POST", "/subscription-checkout/${enc(token)}/pay", body))
    }

    override suspend fun subscriptionConfirm(token: String, intentId: String): CheckoutResult {
        val j = call("POST", "/subscription-checkout/${enc(token)}/confirm", JSONObject().put("paymentIntentId", intentId))
        return resultFromSubscriptionConfirm(j.str("status") ?: "", j.str("subscriptionRef") ?: "", j.str("paymentId"), j.str("transactionId"))
    }

    companion object {
        const val INTEGRATION = "android"

        // encodeURIComponent: spaces as %20, not +.
        private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

        fun codeFor(status: Int, errorCode: String?): VezmoError.Code =
            when {
                // The app's return link isn't registered for this business, or this way to pay is off for it.
                errorCode == "return_url_not_registered" -> VezmoError.Code.Config
                errorCode == "method_unavailable" -> VezmoError.Code.NotAvailable
                status == 410 -> VezmoError.Code.Expired
                status == 409 -> if (errorCode == "local_price_changed") VezmoError.Code.Unknown else VezmoError.Code.AlreadyPaid
                status == 400 || status == 402 -> VezmoError.Code.Declined
                status == 401 || status == 403 || status == 404 -> VezmoError.Code.Config
                else -> VezmoError.Code.Unknown
            }
    }
}

/** The platform's own HTTP client: no dependency for six small JSON calls. */
internal object HttpTransport : VezmoApi.Transport {
    override fun send(method: String, url: String, headers: Map<String, String>, body: String?): VezmoApi.Response {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
            if (body != null) {
                conn.doOutput = true
                conn.outputStream.use { it.write(body.toByteArray()) }
            } else if (method == "POST") {
                conn.doOutput = true
                conn.setFixedLengthStreamingMode(0)
                conn.outputStream.close()
            }
            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            return VezmoApi.Response(status, stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            conn.disconnect()
        }
    }
}

// ── What the API returns ─────────────────────────────────────────────────

/**
 * A string, or null when missing, JSON null or empty. Never `optString` alone: on Android it reads a JSON null as the
 * text "null" (a merchant-of-record session's null connected account became the account "null" and failed to load).
 */
internal fun JSONObject.str(key: String): String? = if (isNull(key)) null else optString(key).ifEmpty { null }

private fun JSONArray?.strings(): List<String> = this?.let { a -> (0 until a.length()).mapNotNull { a.optString(it).ifEmpty { null } } } ?: emptyList()

/** The buyer's own currency, offered beside the price. */
internal data class LocalOffer(
    val currency: String,
    val amountMinor: Long,
    val rate: Double,
    val country: String?,
    /** Methods offered when paying in this currency, e.g. upi for INR, pix for BRL. */
    val methods: List<String>,
    /** Sealed; sent back to pay in this currency. */
    val token: String,
) {
    companion object {
        fun from(j: JSONObject) = LocalOffer(
            currency = j.str("currency") ?: "",
            amountMinor = j.optLong("amountMinor"),
            rate = j.optDouble("rate", 0.0),
            country = j.str("country"),
            methods = j.optJSONArray("methods").strings(),
            token = j.str("token") ?: "",
        )
    }
}

/** What the checkout call returns that the sheet uses. */
internal data class CheckoutConfig(
    val publishableKey: String,
    /** Null for a merchant-of-record business: the platform account. */
    val connectedAccountId: String?,
    val livemode: Boolean,
    val amountMinor: Long,
    val currency: String,
    val title: String,
    val merchantName: String?,
    val enabledMethods: Set<String>,
    val customerName: String?,
    val customerEmail: String?,
    val theme: String?,
    val paymentId: String,
    val localOffer: LocalOffer?,
    /** A subscription checkout: the plan, and what starting it means. Null for a one-time payment. */
    val subscription: SubscriptionPlan? = null,
    /**
     * The country of the account that processes the payment (the business's own on Connect, Vezmo's on merchant of
     * record): Google Pay's merchant country. Null from a server that doesn't say.
     */
    val processingCountry: String? = null,
) {
    companion object {
        /**
         * A subscription checkout as the sheet's config: cards, Google Pay and Instant ACH (when the business offers it
         * for this plan), the plan beside the price.
         */
        fun fromSubscription(v: JSONObject): CheckoutConfig {
            val currency = v.str("currency") ?: "USD"
            val planName = v.str("planName") ?: ""
            val customer = v.optJSONObject("customer")
            return CheckoutConfig(
                publishableKey = v.str("publishableKey") ?: "",
                connectedAccountId = v.str("connectedAccountId"),
                livemode = v.optBoolean("livemode"),
                amountMinor = (v.optDouble("amount", 0.0) * 100).roundToLong(),
                currency = currency,
                title = planName,
                merchantName = v.optJSONObject("merchant")?.str("name"),
                enabledMethods = if (v.optBoolean("instantAchEnabled")) setOf("card", "googlePay", "instantAch") else setOf("card", "googlePay"),
                customerName = customer?.str("name"),
                customerEmail = customer?.str("email"),
                theme = null,
                paymentId = "",
                localOffer = v.optJSONObject("localOffer")?.let(LocalOffer::from),
                subscription = SubscriptionPlan(
                    ref = v.str("subscriptionRef") ?: "",
                    mode = v.str("mode") ?: "payment",
                    planName = planName,
                    recurringAmount = v.optDouble("recurringAmount", 0.0),
                    currency = currency,
                    interval = v.str("interval") ?: "MONTH",
                    intervalCount = v.optInt("intervalCount", 1),
                    trialDays = if (v.isNull("trialDays")) null else v.optInt("trialDays"),
                    nextChargeAt = v.str("nextChargeAt"),
                    consentText = v.str("consentText") ?: "",
                ),
                processingCountry = v.str("processingCountry"),
            )
        }

        fun from(j: JSONObject): CheckoutConfig {
            val on = j.optJSONObject("enabledMethods")
            return CheckoutConfig(
                publishableKey = j.str("publishableKey") ?: "",
                connectedAccountId = j.str("connectedAccountId"),
                livemode = j.optBoolean("livemode"),
                amountMinor = j.optLong("amountMinor"),
                currency = j.str("currency") ?: "USD",
                title = j.str("title") ?: "",
                merchantName = j.str("merchantName"),
                enabledMethods = on?.keys()?.asSequence()?.filter { on.optBoolean(it) }?.toSet() ?: emptySet(),
                customerName = j.str("customerName"),
                customerEmail = j.str("customerEmail"),
                theme = j.str("theme"),
                paymentId = j.str("paymentId") ?: "",
                localOffer = j.optJSONObject("localOffer")?.let(LocalOffer::from),
                processingCountry = j.str("processingCountry"),
            )
        }
    }
}

/** What the buyer paid with (for the receipt): the card's network and last four, or the method. */
internal data class PaidMethod(val type: String, val brand: String?, val last4: String?, val wallet: String?) {
    companion object {
        fun from(j: JSONObject) = PaidMethod(j.str("type") ?: "", j.str("brand"), j.str("last4"), j.str("wallet"))
    }
}

/** What the buyer subscribes to (from the subscription checkout). */
internal data class SubscriptionPlan(
    val ref: String,
    /** `payment`: the first period is charged now. `setup`: a free trial; the card is saved, nothing is charged today. */
    val mode: String,
    val planName: String,
    /** The price of each period, in the plan's currency (major units). */
    val recurringAmount: Double,
    val currency: String,
    /** HOUR, DAY, WEEK, MONTH or YEAR. */
    val interval: String,
    val intervalCount: Int,
    val trialDays: Int?,
    /** When the plan's price is next charged: the trial's end, or the end of the first period (ISO 8601). */
    val nextChargeAt: String?,
    /** The recurring authorization the buyer agrees to by subscribing. */
    val consentText: String,
) {
    val trial get() = mode == "setup"
}

/** POST …/pay: what the server did with the buyer's payment method. */
internal data class PayResponse(
    /** succeeded, processing or requires_action. */
    val state: String,
    /** Null for a free trial (nothing charged) or a step still to finish. */
    val paymentId: String?,
    val transactionId: String?,
    val clientSecret: String?,
    val method: PaidMethod?,
    /** A subscription checkout's subscription. */
    val subscription: SubscriptionResult? = null,
) {
    companion object {
        fun from(j: JSONObject) = PayResponse(
            state = j.str("state") ?: "",
            paymentId = j.str("paymentId"),
            transactionId = j.str("transactionId"),
            clientSecret = j.str("clientSecret"),
            method = j.optJSONObject("method")?.let(PaidMethod::from),
        )

        /** A subscription /pay answer in the shape the session handles for every payment. */
        fun fromSubscription(j: JSONObject): PayResponse {
            val state = j.str("state") ?: ""
            val ref = j.str("subscriptionRef") ?: ""
            return PayResponse(
                state = state,
                paymentId = if (state == "requires_action") null else j.str("paymentId"),
                transactionId = if (state == "succeeded") j.str("transactionId") else null,
                clientSecret = j.str("clientSecret"),
                method = j.optJSONObject("method")?.let(PaidMethod::from),
                subscription = when (state) {
                    "succeeded" -> subscriptionOf(ref, j.str("subscriptionStatus") ?: "")
                    "processing" -> subscriptionOf(ref, "incomplete")
                    else -> null
                },
            )
        }
    }
}

/** open, requires_action, processing, succeeded, failed or canceled. */
internal data class SessionStatus(val state: String, val paymentId: String, val transactionId: String?) {
    companion object {
        fun from(j: JSONObject) = SessionStatus(j.str("state") ?: "", j.str("paymentId") ?: "", j.str("transactionId"))
    }
}

internal data class SessionIntent(val id: String, val clientSecret: String, val connectedAccountId: String?, val livemode: Boolean) {
    companion object {
        fun from(j: JSONObject) = SessionIntent(
            j.str("id") ?: "",
            j.str("clientSecret") ?: "",
            j.str("connectedAccountId"),
            j.optBoolean("livemode"),
        )
    }
}

internal enum class QrMethod(val key: String, val title: String) {
    Upi("upi", "UPI"),
    Pix("pix", "Pix"),
}

/** Who pays with UPI or Pix (Pix also needs the CPF or CNPJ). */
internal data class QrBilling(
    val name: String,
    val line1: String,
    val city: String? = null,
    val postalCode: String? = null,
    val country: String? = null,
    val email: String? = null,
    val taxId: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().put("name", name).put("line1", line1).apply {
        city?.let { put("city", it) }
        postalCode?.let { put("postalCode", it) }
        country?.let { put("country", it) }
        email?.let { put("email", it) }
        taxId?.let { put("taxId", it) }
    }
}

internal data class QrStart(
    val clientSecret: String,
    val connectedAccountId: String?,
    val livemode: Boolean,
    val returnUrl: String,
    val billing: QrBilling,
)

/** A started UPI or Pix payment. */
internal data class QrPayment(
    val status: String,
    /** The QR as a PNG data URI, and when the code runs out (Unix seconds). */
    val qrPng: String?,
    val expiresAt: Long?,
    /** UPI: opens the buyer's UPI app on this phone. */
    val link: String?,
    /** Pix: the code to paste in a bank app. */
    val code: String?,
) {
    companion object {
        fun from(j: JSONObject): QrPayment {
            val qr = j.optJSONObject("qr")
            return QrPayment(
                status = j.str("status") ?: "",
                qrPng = qr?.str("png"),
                expiresAt = qr?.takeUnless { it.isNull("expiresAt") }?.optLong("expiresAt"),
                link = j.str("link"),
                code = j.str("code"),
            )
        }
    }
}
