package com.vezmo.checkout

import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ApiTest {
    private class Recorded(val method: String, val url: String, val headers: Map<String, String>, val body: String?)

    private fun api(status: Int, body: String, calls: MutableList<Recorded> = mutableListOf()) =
        VezmoApi(
            "https://api.test/v1",
            { method, url, headers, b ->
                calls += Recorded(method, url, headers, b)
                VezmoApi.Response(status, body)
            },
            Dispatchers.Unconfined,
        )

    private suspend fun failure(block: suspend () -> Unit): VezmoApiError {
        try {
            block()
        } catch (e: VezmoApiError) {
            return e
        }
        fail("expected a VezmoApiError")
        throw IllegalStateException()
    }

    @Test
    fun `pays with the payment method, our integration and SDK header, and unwraps the data`() = runTest {
        val calls = mutableListOf<Recorded>()
        val res = api(200, """{"success":true,"data":{"state":"processing","paymentId":"p","clientSecret":null}}""", calls)
            .pay("tok/1", "pm_1", "o", "stripesdk://payment_return_url/com.acme.shop")
        assertEquals("processing", res.state)
        assertEquals(null, res.clientSecret)
        val call = calls.single()
        assertEquals("https://api.test/v1/secure-payments/tok%2F1/pay", call.url)
        assertEquals("POST", call.method)
        assertTrue(call.headers["Vezmo-SDK"]!!.matches(Regex("""^android/\d+\.\d+\.\d+.*""")))
        val body = JSONObject(call.body!!)
        // A payment method, never a confirmation token; the engine's return link when the method leaves the app.
        assertEquals(setOf("paymentMethodId", "integration", "localOffer", "returnUrl"), body.keys().asSequence().toSet())
        assertEquals("pm_1", body.getString("paymentMethodId"))
        assertEquals("android", body.getString("integration"))
        assertEquals("o", body.getString("localOffer"))
        assertEquals("stripesdk://payment_return_url/com.acme.shop", body.getString("returnUrl"))
    }

    @Test
    fun `a card goes without a return link`() = runTest {
        val calls = mutableListOf<Recorded>()
        api(200, """{"success":true,"data":{"state":"succeeded","paymentId":"p"}}""", calls).pay("t", "pm_1", null, null)
        val body = JSONObject(calls.single().body!!)
        assertEquals(setOf("paymentMethodId", "integration"), body.keys().asSequence().toSet())
    }

    @Test
    fun `subscribes with the payment method, never a confirmation token`() = runTest {
        val calls = mutableListOf<Recorded>()
        api(200, """{"success":true,"data":{"state":"succeeded","subscriptionRef":"SUB-1","paymentId":"p"}}""", calls)
            .subscriptionPay("sub", "pm_1", null)
        val call = calls.single()
        assertEquals("https://api.test/v1/subscription-checkout/sub/pay", call.url)
        val body = JSONObject(call.body!!)
        assertEquals(setOf("paymentMethodId", "integration"), body.keys().asSequence().toSet())
        assertEquals("pm_1", body.getString("paymentMethodId"))
    }

    @Test
    fun `a Vezmo wrapper names itself in the SDK header`() = runTest {
        val calls = mutableListOf<Recorded>()
        val wrapped = VezmoApi(
            "https://api.test/v1",
            { method, url, headers, b ->
                calls += Recorded(method, url, headers, b)
                VezmoApi.Response(410, "{}")
            },
            Dispatchers.Unconfined,
            sdk = "flutter/0.1.0",
        )
        failure { wrapped.status("t") }
        assertEquals("flutter/0.1.0", calls.single().headers["Vezmo-SDK"])
    }

    @Test
    fun `turns failures into Vezmo's own codes and words`() = runTest {
        assertEquals(
            VezmoError.Code.Expired,
            failure { api(410, """{"message":"Secure-payments token has expired"}""").status("t") }.code,
        )
        val declined = failure { api(400, """{"message":"Your bank declined this card."}""").pay("t", "c", null, null) }
        assertEquals(VezmoError.Code.Declined, declined.code)
        assertEquals("Your bank declined this card.", declined.message)
        val priceChanged = failure {
            api(409, """{"message":"Price changed","errors":[{"code":"local_price_changed","message":"x"}]}""").pay("t", "c", null, null)
        }
        assertEquals("local_price_changed", priceChanged.reason)
        assertEquals(VezmoError.Code.Unknown, priceChanged.code)
        val unregistered = failure {
            api(
                400,
                """{"message":"Register acme://vezmo for this business.","errors":[{"code":"return_url_not_registered","message":"Register acme://vezmo for this business."}]}""",
            ).pay("t", "c", null, null)
        }
        assertEquals(VezmoError.Code.Config, unregistered.code)
        assertEquals("Register acme://vezmo for this business.", unregistered.message)
        val unavailable = failure {
            api(400, """{"errors":[{"code":"method_unavailable","message":"This way to pay is not available."}]}""")
                .subscriptionPay("t", "c", null)
        }
        assertEquals(VezmoError.Code.NotAvailable, unavailable.code)
        assertEquals("This way to pay is not available.", unavailable.message)
        assertEquals(VezmoError.Code.AlreadyPaid, failure { api(409, "{}").status("t") }.code)
        assertEquals(VezmoError.Code.Config, failure { api(404, "not json").status("t") }.code)
        val offline = VezmoApi("https://api.test/v1", { _, _, _, _ -> throw IOException("x") }, Dispatchers.Unconfined)
        assertEquals(VezmoError.Code.Network, failure { offline.status("t") }.code)
    }

    @Test
    fun `a merchant-of-record session - JSON nulls stay null, never the text null`() = runTest {
        val config = api(
            200,
            """{"success":true,"data":{"publishableKey":"pk_test_x","connectedAccountId":null,"livemode":false,
            "amountMinor":4900,"currency":"USD","title":"Order","merchantName":null,"enabledMethods":{"card":true},
            "customerName":null,"customerEmail":"","theme":null,"paymentId":"pay_1",
            "localOffer":{"currency":"INR","amountMinor":420000,"rate":85.7,"country":null,"methods":["upi"],"token":"o"},
            "appReturnUrl":null}}""",
        ).checkout("tok")
        assertEquals(null, config.connectedAccountId)
        assertEquals(null, config.merchantName)
        assertEquals(null, config.customerName)
        assertEquals(null, config.customerEmail)
        assertEquals(null, config.theme)
        assertEquals(null, config.localOffer!!.country)
        val intent = api(200, """{"success":true,"data":{"id":"pi_1","clientSecret":"pi_1_secret_x","connectedAccountId":null,"livemode":false}}""")
            .intent("tok", null)
        assertEquals(null, intent.connectedAccountId)
        val paid = api(200, """{"success":true,"data":{"state":"succeeded","paymentId":"p","transactionId":null,"clientSecret":null,"method":{"type":"card","brand":null,"last4":null,"wallet":null}}}""")
            .pay("tok", "c", null, null)
        assertEquals(null, paid.transactionId)
        assertEquals(PaidMethod("card", null, null, null), paid.method)
    }

    @Test
    fun `reads the checkout session and sends no body to load it`() = runTest {
        val calls = mutableListOf<Recorded>()
        val json = """{"success":true,"data":{"publishableKey":"pk_test_x","connectedAccountId":null,"livemode":false,
            "amount":49,"amountMinor":4900,"currency":"usd","title":"Order","merchantName":"Acme",
            "enabledMethods":{"card":true,"klarna":false,"googlePay":true},"customerName":null,"customerEmail":null,
            "theme":null,"paymentId":"pay_1","localOffer":null,"appReturnUrl":null}}"""
        val config = api(200, json, calls).checkout("tok")
        assertEquals("https://api.test/v1/secure-payments/tok/checkout?redirectMethods=1", calls.single().url)
        assertEquals(null, calls.single().body)
        assertEquals(null, config.connectedAccountId)
        assertEquals(null, config.customerName)
        assertEquals(setOf("card", "googlePay"), config.enabledMethods)
        assertEquals(4900L, config.amountMinor)
        // A server that doesn't say which country processes the payment.
        assertEquals(null, config.processingCountry)
        val withCountry = api(200, json.replace("\"appReturnUrl\":null", "\"appReturnUrl\":null,\"processingCountry\":\"AE\"")).checkout("tok")
        assertEquals("AE", withCountry.processingCountry)
    }
}
