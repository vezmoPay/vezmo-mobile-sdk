package com.vezmo.checkout

import java.text.DateFormat
import java.text.NumberFormat
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Currency
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToLong

/** The engine's payment-method types the sheet shows, by our method key, in this order. */
private val ELEMENT_TYPES = linkedMapOf(
    "card" to "card",
    "klarna" to "klarna",
    "affirm" to "affirm",
    "afterpayClearpay" to "afterpay_clearpay",
    "amazonPay" to "amazon_pay",
    "cashapp" to "cashapp",
)

/** Methods the business priced only in US dollars: hidden when the buyer pays in their own currency (as on web). */
private val USD_ONLY = setOf("klarna", "affirm", "afterpayClearpay", "amazonPay", "cashapp", "ach")

internal data class Charge(
    val amountMinor: Long,
    val currency: String,
    /** The sealed local-currency offer when the buyer pays in their own currency. */
    val localOffer: String?,
)

/**
 * What the buyer is charged: the session's price, or the offer in their own currency when they chose it. A free
 * trial charges nothing today, whichever currency the plan will renew in.
 */
internal fun chargeOf(config: CheckoutConfig, payLocal: Boolean): Charge {
    val offer = config.localOffer
    val trial = config.subscription?.trial == true
    if (payLocal && offer != null) return Charge(if (trial) 0 else offer.amountMinor, offer.currency.uppercase(), offer.token)
    return Charge(if (trial) 0 else config.amountMinor, config.currency.uppercase(), null)
}

internal data class SheetMethods(
    /** For the engine (cards, pay-later, Cash App), in this order. */
    val elementTypes: List<String>,
    val googlePay: Boolean,
    /** Our own panels: UPI (INR) and Pix (BRL), only when paying in that currency. */
    val upi: Boolean,
    val pix: Boolean,
    /** Our own Instant ACH row (a US bank account through the engine's bank step): US dollars only. */
    val instantAch: Boolean = false,
)

/**
 * The ways to pay the sheet offers, from the business's enabled methods: the same rules as the web checkout. Bank
 * debit (ACH) is not offered in the mobile sheet; Instant ACH is, in US dollars (never in the buyer's own currency).
 */
internal fun sheetMethods(config: CheckoutConfig, charge: Charge): SheetMethods {
    val on = config.enabledMethods
    val local = charge.localOffer != null
    val offerMethods = config.localOffer?.methods ?: emptyList()
    val elementTypes = ELEMENT_TYPES
        .filterKeys { it == "card" || it in on }
        .filterKeys { !(local && it in USD_ONLY) }
        .values
        .toList()
    return SheetMethods(
        elementTypes = elementTypes,
        googlePay = "googlePay" in on,
        upi = local && charge.currency == "INR" && "upi" in on && "upi" in offerMethods,
        pix = local && charge.currency == "BRL" && "pix" in on && "pix" in offerMethods,
        instantAch = !local && charge.currency == "USD" && "instantAch" in on,
    )
}

/**
 * The linked bank account as the Instant ACH row shows it: "•••• 6789". Null until the engine's bank step has linked
 * one (its label then carries the account's last four, maybe wrapped in direction marks); the engine's own words are
 * never shown.
 */
internal fun bankLabel(engineLabel: String?): String? =
    Regex("[0-9]{4,}").findAll(engineLabel ?: "").lastOrNull()?.let { "•••• ${it.value.takeLast(4)}" }

/** The merchant's result for a /pay answer that needs nothing more from the buyer. */
internal fun resultFromPay(res: PayResponse): CheckoutResult? =
    when (res.state) {
        "succeeded" -> CheckoutResult.Succeeded(res.paymentId, res.transactionId, res.subscription)
        "processing" -> CheckoutResult.Processing(res.paymentId, res.subscription)
        else -> null // requires_action: the engine finishes it first
    }

/** The merchant's result from the session status (after 3D Secure, a redirect, UPI or Pix). */
internal fun resultFromStatus(s: SessionStatus): CheckoutResult? =
    when (s.state) {
        "succeeded" -> CheckoutResult.Succeeded(s.paymentId, s.transactionId)
        "processing" -> CheckoutResult.Processing(s.paymentId)
        "failed" -> CheckoutResult.Failed(DECLINED)
        "canceled" -> CheckoutResult.Failed(VezmoError(VezmoError.Code.Expired, EXPIRED.message))
        else -> null // still open or waiting on the buyer
    }

/**
 * Google Pay's merchant country: the app's own, else the country of the account that processes the payment (from the
 * session: the business's own on Connect, Vezmo's on merchant of record), else US (a server that doesn't say).
 */
internal fun merchantCountry(app: String?, session: String?): String =
    listOf(app, session).firstNotNullOfOrNull { c -> c?.trim()?.uppercase()?.takeIf { Regex("[A-Z]{2}").matches(it) } } ?: "US"

/**
 * The payment engine's own return link (`stripesdk://payment_return_url/<package>`, what it opens to bring the buyer
 * back into the open sheet) for a method that leaves the app: a bank app or a pay-later provider (Cash App, Klarna,
 * Affirm, Afterpay, Amazon Pay). Vezmo's API takes it for a business that registered this app (Developers → Mobile
 * apps, Android, this package). Null for a card (3D Secure and Google Pay included) and Instant ACH, which come back
 * without it: they keep working for a business that registered no app.
 */
internal fun engineReturnUrl(paymentMethodType: String?, packageName: String): String? =
    if (paymentMethodType == "card" || paymentMethodType == "link") null else "stripesdk://payment_return_url/$packageName"

/** Paid, or money on its way. */
internal val CheckoutResult.isPaid get() = this is CheckoutResult.Succeeded || this is CheckoutResult.Processing

internal val DECLINED = VezmoError(VezmoError.Code.Declined, "Your payment didn’t go through. Try another card or way to pay.")
internal val EXPIRED = VezmoError(VezmoError.Code.Expired, "This checkout has expired. Please start again.")

private val INTENT_SECRET = Regex("^((?:pi|seti)_[A-Za-z0-9]+)_secret_[A-Za-z0-9_-]+$")

/** `pi_123_secret_abc` → `pi_123` (or a free trial's `seti_…`): the intent the device finished, for /confirm. */
internal fun intentIdOf(clientSecret: String?): String? = clientSecret?.let { INTENT_SECRET.matchEntire(it)?.groupValues?.get(1) }

/** Amount for display, e.g. 4900 USD → "$49.00", 420000 INR → "₹4,200.00". */
internal fun formatAmount(amountMinor: Long, currency: String, locale: Locale = Locale.getDefault()): String =
    try {
        NumberFormat.getCurrencyInstance(locale).apply { this.currency = Currency.getInstance(currency.uppercase()) }.format(amountMinor / 100.0)
    } catch (_: IllegalArgumentException) {
        String.format(Locale.US, "%.2f %s", amountMinor / 100.0, currency)
    }

// ── subscriptions ─────────────────────────────────────────────────────────

internal fun subscriptionOf(ref: String, status: String): SubscriptionResult =
    SubscriptionResult(
        ref,
        when (status.lowercase()) {
            "active" -> SubscriptionResult.Status.Active
            "trialing" -> SubscriptionResult.Status.Trialing
            else -> SubscriptionResult.Status.Incomplete
        },
    )

/** The result after a subscription start finished on the device (3D Secure), from /confirm. */
internal fun resultFromSubscriptionConfirm(status: String, ref: String, paymentId: String?, transactionId: String?): CheckoutResult {
    val subscription = subscriptionOf(ref, status)
    return if (status == "processing") {
        CheckoutResult.Processing(paymentId, subscription)
    } else {
        CheckoutResult.Succeeded(paymentId, transactionId, subscription)
    }
}

private val UNITS = mapOf(
    "HOUR" to ("hour" to "hours"),
    "DAY" to ("day" to "days"),
    "WEEK" to ("week" to "weeks"),
    "MONTH" to ("month" to "months"),
    "YEAR" to ("year" to "years"),
)

/** "month", "3 months": one period of the plan. */
internal fun periodText(interval: String, count: Int): String {
    val (one, many) = UNITS[interval.uppercase()] ?: (interval.lowercase() to "${interval.lowercase()}s")
    return if (count > 1) "$count $many" else one
}

/** "$9.99 / month", "$30.00 every 3 months": the plan's price, as the buyer reads it. */
internal fun planPriceText(plan: SubscriptionPlan, locale: Locale = Locale.getDefault()): String {
    val price = formatAmount((plan.recurringAmount * 100).roundToLong(), plan.currency.uppercase(), locale)
    return if (plan.intervalCount > 1) "$price every ${periodText(plan.interval, plan.intervalCount)}" else "$price / ${periodText(plan.interval, 1)}"
}

/** "Oct 23, 2026" or "23 Oct 2026": the buyer's own date format. Empty for a missing or unreadable date. */
internal fun dateText(iso: String?, locale: Locale = Locale.getDefault(), zone: TimeZone = TimeZone.getDefault()): String {
    if (iso.isNullOrEmpty()) return ""
    for (pattern in listOf("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd")) {
        val parser = SimpleDateFormat(pattern, Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val date = try {
            parser.parse(iso)
        } catch (_: ParseException) {
            null
        } ?: continue
        return DateFormat.getDateInstance(DateFormat.MEDIUM, locale).apply { timeZone = zone }.format(date)
    }
    return ""
}
