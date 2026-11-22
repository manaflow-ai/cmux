package com.cmuxterm.mobile.ffi

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Replays schemas/terminal-sizing/fixtures.json through the generated Kotlin
 * bindings and the host-built libcmux_mobile_ffi (JNA). Records are built in
 * Kotlin, so every step crosses the FFI boundary in both directions.
 */
class TerminalSizingFixtureTest {
    private val corpus: List<JsonObject> by lazy {
        val path = System.getProperty("cmux.sizing.fixtures") ?: error("cmux.sizing.fixtures is not set")
        Json.parseToJsonElement(File(path).readText()).jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
    }

    private fun JsonObject.string(key: String): String? =
        this[key]?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.jsonPrimitive?.content

    private fun size(value: JsonObject) = TerminalGridSize(
        cols = value.getValue("cols").jsonPrimitive.int.toUShort(),
        rows = value.getValue("rows").jsonPrimitive.int.toUShort(),
    )

    private fun participant(value: JsonObject) = TerminalSizingParticipant(
        id = value.string("id") ?: error("participant without id"),
        userId = value.string("user_id"),
        displayName = value.string("display_name"),
        deviceKind = terminalDeviceKindFromWire(value.string("device_kind") ?: "unknown"),
        deviceName = value.string("device_name"),
        deviceId = value.string("device_id"),
        via = value.string("via"),
        viewport = (value["viewport"] as? JsonObject)?.let(::size),
        countsOverride = value["counts_override"]?.jsonPrimitive?.booleanOrNull,
    )

    @Test
    fun replaysEveryFixtureCase() {
        assertTrue("the corpus is empty", corpus.isNotEmpty())
        var expects = 0
        for (case in corpus) {
            val name = case.string("name")
            TerminalSizingEngine(
                size(case.getValue("initial").jsonObject),
                terminalSizingPolicy(TerminalSizingMode.SMALLEST, emptyList(), null),
            ).use { engine ->
                for ((index, element) in case.getValue("steps").jsonArray.withIndex()) {
                    val step = element.jsonObject
                    val at = "$name step $index"
                    val id = step.string("id") ?: ""
                    when (val op = step.string("op")) {
                        "attach" -> engine.attach(participant(step.getValue("participant").jsonObject))
                        "detach" -> engine.detach(id)
                        "report" -> engine.report(id, size(step))
                        "activity" -> engine.noteActivity(id)
                        "clear_viewport" -> engine.clearViewport(id)
                        "set_counts" -> engine.setCountsOverride(id, step["counts_override"]?.jsonPrimitive?.booleanOrNull)
                        "set_policy" -> engine.setPolicy(terminalSizingPolicyFromJson(step.getValue("policy").toString()))
                        "expect" -> {
                            expects += 1
                            expect(at, engine, step)
                        }
                        else -> fail("$at: unknown op $op")
                    }
                }
            }
        }
        assertTrue("the corpus has no expect steps", expects > 0)
    }

    private fun expect(at: String, engine: TerminalSizingEngine, step: JsonObject) {
        val state = engine.state()
        step["cols"]?.let { assertEquals("$at cols", it.jsonPrimitive.int, state.cols.toInt()) }
        step["rows"]?.let { assertEquals("$at rows", it.jsonPrimitive.int, state.rows.toInt()) }
        step["owners"]?.let { owners ->
            assertEquals("$at owners", owners.jsonArray.map { it.jsonPrimitive.content }, state.owners)
        }
        step["reason"]?.let { assertEquals("$at reason", it.jsonPrimitive.content, terminalSizingReasonWire(state.reason)) }
        step["generation"]?.let { assertEquals("$at generation", it.jsonPrimitive.long.toULong(), state.generation) }
        (step["priority_keys"] as? JsonObject)?.forEach { (participant, expected: JsonElement) ->
            val row = state.participants.firstOrNull { it.participant.id == participant }
            assertEquals("$at priority_key $participant", expected.jsonPrimitive.content, row?.priorityKey)
        }
        (step["counts"] as? JsonObject)?.forEach { (participant, expected: JsonElement) ->
            assertEquals("$at counts $participant", expected.jsonPrimitive.boolean, engine.counts(participant))
            val row = state.participants.firstOrNull { it.participant.id == participant }
            assertEquals("$at published counts $participant", expected.jsonPrimitive.boolean, row?.counts)
        }
    }

    private class Recorder : TerminalSizingListener {
        val states = java.util.Collections.synchronizedList(mutableListOf<TerminalSizingState>())

        override fun onState(state: TerminalSizingState) {
            states.add(state)
        }
    }

    @Test
    fun kotlinListenerReceivesEveryChangedState() {
        TerminalSizingEngine(
            TerminalGridSize(80u, 24u),
            terminalSizingPolicy(TerminalSizingMode.LATEST, emptyList(), null),
        ).use { engine ->
            val recorder = Recorder()
            engine.setListener(recorder)
            val mac = TerminalSizingParticipant(
                id = "mac", userId = "u1", displayName = null, deviceKind = TerminalDeviceKind.MAC,
                deviceName = null, deviceId = null, via = null,
                viewport = TerminalGridSize(150u, 42u), countsOverride = null,
            )
            assertTrue(engine.attach(mac))
            assertFalse(engine.detach("missing"))
            assertTrue(engine.report("mac", TerminalGridSize(120u, 40u)))
            assertEquals(listOf(1uL, 2uL), recorder.states.map { it.generation })
            assertEquals(engine.state(), recorder.states.last())
            engine.setListener(null)
            assertTrue(engine.detach("mac"))
            assertEquals(2, recorder.states.size)
        }
    }

    @Test
    fun stateRoundTripsThroughTheWireAndBadJsonThrows() {
        TerminalSizingEngine(
            TerminalGridSize(80u, 24u),
            terminalSizingPolicy(TerminalSizingMode.FIXED, emptyList(), TerminalGridSize(0u, 0u)),
        ).use { engine ->
            assertEquals(TerminalGridSize(2u, 1u), engine.state().policy.fixed)
            val json = terminalSizingStateToJson(engine.state())
            assertEquals(engine.state(), terminalSizingStateFromJson(json))
        }
        try {
            terminalSizingStateFromJson("{")
            fail("bad JSON decoded")
        } catch (error: TerminalSizingWireException) {
            assertTrue(error is TerminalSizingWireException.Invalid)
        }
        assertEquals(TerminalDeviceKind.UNKNOWN, terminalDeviceKindFromWire("quantum"))
    }
}
