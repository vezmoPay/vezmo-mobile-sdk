package com.vezmo.checkout

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FlowTest {
    @Test
    fun `Google Pay's merchant country is the app's, else the session's, else US`() {
        assertEquals("AE", merchantCountry(null, "ae"))
        assertEquals("GB", merchantCountry("GB", "AE"))
        assertEquals("AE", merchantCountry("usa", "AE"))
        assertEquals("US", merchantCountry(" ", null))
        assertEquals("US", merchantCountry(null, null))
    }

    @Test
    fun `a method that leaves the app comes back through the engine's own link - never a card or Instant ACH`() {
        for (type in listOf("cashapp", "klarna", "affirm", "afterpay_clearpay", "amazon_pay", null)) {
            assertEquals("stripesdk://payment_return_url/com.acme.shop", engineReturnUrl(type, "com.acme.shop"))
        }
        assertNull(engineReturnUrl("card", "com.acme.shop"))
        assertNull(engineReturnUrl("link", "com.acme.shop"))
    }

    @Test
    fun `the charge is the price, or the buyer's own currency when they chose it`() {
        assertEquals(Charge(4900, "USD", null), chargeOf(config(), false))
        assertEquals(Charge(420000, "INR", "offer_sealed"), chargeOf(config(), true))
        assertNull(chargeOf(config(localOffer = null), true).localOffer)
    }

    @Test
    fun `in US dollars - card, the enabled pay-later methods and Cash App, Google Pay, no UPI`() {
        val m = sheetMethods(config(), chargeOf(config(), false))
        assertEquals(SheetMethods(listOf("card", "klarna", "cashapp"), googlePay = true, upi = false, pix = false), m)
    }

    @Test
    fun `in the buyer's rupees - card only in the engine, plus our UPI panel`() {
        val m = sheetMethods(config(), chargeOf(config(), true))
        assertEquals(listOf("card"), m.elementTypes)
        assertTrue(m.upi)
    }

    @Test
    fun `UPI needs the business to offer it and the offer to carry it`() {
        val off = config(enabledMethods = setOf("card"))
        assertFalse(sheetMethods(off, chargeOf(off, true)).upi)
        val noOfferMethod = config(localOffer = INR_OFFER.copy(methods = emptyList()))
        assertFalse(sheetMethods(noOfferMethod, chargeOf(noOfferMethod, true)).upi)
    }

    @Test
    fun `Instant ACH only in US dollars, when the business offers it, as the sheet's own row`() {
        val on = config(enabledMethods = setOf("card", "instantAch"))
        val dollars = sheetMethods(on, chargeOf(on, false))
        assertTrue(dollars.instantAch)
        assertEquals(listOf("card"), dollars.elementTypes)
        assertTrue(engineIntent(chargeOf(on, false), dollars).instantAch)
        // Never in the buyer's own currency.
        assertFalse(sheetMethods(on, chargeOf(on, true)).instantAch)
        val off = config(enabledMethods = setOf("card"))
        assertFalse(sheetMethods(off, chargeOf(off, false)).instantAch)
    }

    @Test
    fun `the linked bank shows only its last four, never the engine's words`() {
        assertEquals("•••• 6789", bankLabel("••••6789"))
        assertEquals("•••• 6789", bankLabel("Success Bank ••••6789 "))
        // The engine wraps the number in direction marks (as on the emulator).
        assertEquals("•••• 6789", bankLabel("\u00b7\u00b7\u00b7\u00b7 \u20666789\u2069"))
        assertNull(bankLabel("Link"))
        assertNull(bankLabel("Bank"))
        assertNull(bankLabel(null))
    }

    @Test
    fun `maps the server answers to what the merchant gets`() {
        assertEquals(
            CheckoutResult.Succeeded("p", "VT1"),
            resultFromPay(PayResponse("succeeded", "p", "VT1", null, null)),
        )
        assertEquals(CheckoutResult.Processing("p"), resultFromPay(PayResponse("processing", "p", null, null, null)))
        assertNull(resultFromPay(PayResponse("requires_action", "p", null, "pi_1_secret_x", null)))
        assertNull(resultFromStatus(SessionStatus("open", "p", null)))
        val failed = resultFromStatus(SessionStatus("failed", "p", null)) as CheckoutResult.Failed
        assertEquals(VezmoError.Code.Declined, failed.error.code)
    }

    @Test
    fun `reads the intent id only from a real client secret`() {
        assertEquals("pi_3Abc", intentIdOf("pi_3Abc_secret_xyZ_1"))
        assertNull(intentIdOf("pi_3Abc"))
        assertNull(intentIdOf(null))
    }

    @Test
    fun `formats amounts in their currency`() {
        assertEquals("$49.00", formatAmount(4900, "USD", Locale.US))
        assertEquals("₹4,200.00", formatAmount(420000, "INR", Locale("en", "IN")))
    }
}
