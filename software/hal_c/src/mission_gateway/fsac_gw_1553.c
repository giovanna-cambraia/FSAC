/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/src/mission_gateway/fsac_gw_1553.c
 * Module      : Mission gateway, MIL-STD-1553B whitelist parser
 * Language    : C11, written to MISRA C:2012 (Amendment 2/3)
 * Assurance   : DO-178C Software Level C (partition P6 is DAL C)
 * Partition   : P6 MISSION_GATEWAY
 * Requirements: SECR-GW-0001, SECR-GW-0002, SECR-ARC-0001, SECR-ARC-0002,
 *               SECR-TARA-0004 (placeholder IDs)
 *
 * PURPOSE
 *   Implements the parser described in fsac_gw_1553.h: accepts only frames
 *   that match a row of the whitelist (docs/04_interface/ICD_mission_bus.md,
 *   section 4) in all four fields, drops everything else, and counts every
 *   outcome. Receive messages become fixed-size records in a small ring.
 *   Transmit requests are answered from buffers loaded through the one-way
 *   copy. The parser never reads control state and has no way to change a
 *   mode, a latch or a control output: a rejection can only move a counter.
 *
 * DESIGN RULES (each one maps to a MISRA or DO-326A argument)
 *   R1  No dynamic memory. No static variables that change. The only statics
 *       are read-only: the whitelist table and a zero state (MISRA 21.3).
 *   R2  No hidden state. Everything the parser remembers is in the caller's
 *       fsac_gw_state_t.
 *   R3  Bounded execution. At most 18 bytes are read, loops run over at most
 *       8 words, 5 table rows or 4 ring slots. No recursion (MISRA 17.2).
 *   R4  Pointer arguments are checked at the public boundary (ADR-008).
 *   R5  The length is checked before the first byte is read (property G1).
 *   R6  Default deny: a frame is accepted only if (T/R, subaddress, word
 *       count) match a table row. The RT address is checked before.
 *   R7  Exact shape: the byte length must equal the length the command word
 *       implies, reserved words must be zero, nothing is trimmed or repaired.
 *   R8  A rejection queues no record and produces no response; exactly one
 *       counter moves (property G4).
 *   R9  Counters saturate; they never wrap.
 *   R10 The response is cleared on every call that can write it.
 *
 * ROW INDEX
 *   Table row i holds message ID i + 1. The per-message arrays in the state
 *   (rate_used, tx_words, tx_frame, tx_valid) are indexed by the row index.
 *
 * ORDER OF CHECKS (the first failure wins, so the reported cause is stable)
 *   1 length is 0 or above 18 bytes                    REJ_LENGTH
 *   2 length does not match the command word           REJ_FRAMING
 *   3 RT address is the broadcast address (31)         REJ_BROADCAST
 *   4 RT address is not the FSAC address               REJ_ADDRESS
 *   5 no row matches (T/R, subaddress, word count)     REJ_NOT_LISTED
 *   6 a data word is out of range, or reserved != 0    REJ_RANGE   (receive only)
 *   7 rate limit for this message exceeded             REJ_RATE
 *   8 output ring full (receive only)                  REJ_OVERRUN
 *
 * TIMING BUDGET
 *   Constant and small. Not measured. No flight-critical function depends on
 *   it (security_architecture.md, section 2.1).
 *
 * USAGE
 *   See fsac_gw_1553.h.
 *
 * MISRA NOTES
 *   * Fixed-width types only (Directive 4.6).
 *   * Rule 15.5 (single point of exit) is Advisory. This file uses early
 *     returns on purpose: each rejection returns at the check that failed.
 *     To be recorded in the deviation register.
 *   * The record sequence number wraps modulo 2^32 on purpose: it only orders
 *     records. It is not a counter in the sense of rule R9.
 *   * Not yet checked with a MISRA tool. The compliance record is open.
 *
 * WHAT THIS DOES NOT COVER
 *   See fsac_gw_1553.h. The whitelist rows, ranges and limits are
 *   PLACEHOLDERS from the illustrative ICD table.
*/

#include <stdbool.h>

#include "fsac_gw_1553.h"

// the whitelist (ICD_mission_bus.md, section 4): PLACEHOLDER rows
typedef struct
{
    fsac_gw_msg_id_t msg_id;
    uint8_t          transmit;   // 1U = the FSAC transmits, 0U = the FSAC receives
    uint8_t          subaddr;
    uint8_t          words;
} gw_row_t;

static const gw_row_t k_table[FSAC_GW_NUM_MSGS] =
{
    { FSAC_GW_MSG_NAV_HINT,      0U, 1U, 4U },
    { FSAC_GW_MSG_TIME_SYNC,     0U, 2U, 2U },
    { FSAC_GW_MSG_MISSION_MODE,  0U, 3U, 8U },
    { FSAC_GW_MSG_FSAC_STATUS,   1U, 1U, 6U },
    { FSAC_GW_MSG_FSAC_SNAPSHOT, 1U, 2U, 4U }
};

static const fsac_gw_state_t  k_zero_state;      // zero-initialised (static storage)
static const fsac_gw_record_t k_zero_record;     // zero-initialised (static storage)

// local helpers

// little-endian 16-bit word, byte by byte, so alignment and host endianness never matter
static uint16_t rd16(const uint8_t * p)
{
    return (uint16_t)((uint16_t)p[0] | (uint16_t)((uint16_t)p[1] << 8));
}

// saturating increment (rule R9)
static void bump(uint32_t * counter)
{
    if (*counter < UINT32_MAX)
    {
        *counter = *counter + 1U;
    }
}

// counts one rejection and returns its code
static fsac_gw_status_t reject(uint32_t * counter, fsac_gw_status_t status)
{
    bump(counter);
    return status;
}

static void clear_response(fsac_gw_response_t * response)
{
    uint32_t i;

    for (i = 0U; i < FSAC_GW_MAX_WORDS; i++)
    {
        response->words[i] = 0U;
    }
    response->word_count = 0U;
    response->fresh      = 0U;
    response->reserved   = 0U;
}

// returns the table row that matches, or FSAC_GW_NUM_MSGS if none does
static uint32_t find_row(uint32_t transmit, uint32_t subaddr, uint32_t words)
{
    uint32_t i;

    for (i = 0U; i < FSAC_GW_NUM_MSGS; i++)
    {
        if (((uint32_t)k_table[i].transmit == transmit)
            && ((uint32_t)k_table[i].subaddr == subaddr)
            && ((uint32_t)k_table[i].words == words))
        {
            return i;
        }
    }
    return FSAC_GW_NUM_MSGS;
}

// field ranges of the receive messages (ICD, section 4.1): PLACEHOLDERS
static bool range_ok(fsac_gw_msg_id_t msg_id, const uint16_t * w)
{
    bool     ok = true;
    int32_t  lat;
    uint32_t i;

    if (msg_id == FSAC_GW_MSG_NAV_HINT)
    {
        // word 0 is a signed 16-bit value limited to -16384 .. 16384; words 1..3 are free
        lat = (w[0] >= 0x8000U) ? ((int32_t)w[0] - 65536) : (int32_t)w[0];
        ok = (lat >= -16384) && (lat <= 16384);
    }
    else if (msg_id == FSAC_GW_MSG_MISSION_MODE)
    {
        // word 0 is the phase, 0 .. 7; words 1..7 are reserved and must be exactly zero
        ok = (w[0] <= 7U);
        for (i = 1U; i < 8U; i++)
        {
            if (w[i] != 0U)
            {
                ok = false;
            }
        }
    }
    else
    {
        // FSAC_GW_MSG_TIME_SYNC: any value is allowed
        ok = true;
    }
    return ok;
}

// rate limit per message, counted per major frame (ICD, rule R-4);
// returns true and uses one slot if the message is still allowed
static bool rate_allow(fsac_gw_state_t * state, uint32_t idx, uint32_t frame)
{
    uint32_t major = frame / FSAC_GW_MINORS_PER_MAJOR;
    uint32_t i;

    if ((state->has_rate_major == 0U) || (state->rate_major != major))
    {
        for (i = 0U; i < FSAC_GW_NUM_MSGS; i++)
        {
            state->rate_used[i] = 0U;
        }
        state->rate_major     = major;
        state->has_rate_major = 1U;
    }
    if (state->rate_used[idx] >= FSAC_GW_RATE_LIMIT_PER_MAJOR)
    {
        return false;
    }
    state->rate_used[idx] = (uint8_t)(state->rate_used[idx] + 1U);
    return true;
}

// answer to a transmit request: the loaded words if they are fresh, else "no data"
static void build_response(const fsac_gw_state_t * state, uint32_t idx, uint32_t frame,
                           fsac_gw_response_t * response)
{
    uint32_t n         = (uint32_t)k_table[idx].words;
    uint32_t now_major = frame / FSAC_GW_MINORS_PER_MAJOR;
    uint32_t ld_major  = state->tx_frame[idx] / FSAC_GW_MINORS_PER_MAJOR;
    bool     fresh     = false;
    uint32_t i;

    // stale if never loaded, loaded "in the future", or older than the limit
    if ((state->tx_valid[idx] == 1U) && (now_major >= ld_major)
        && ((now_major - ld_major) <= FSAC_GW_TX_MAX_AGE_MAJOR))
    {
        fresh = true;
    }

    for (i = 0U; i < n; i++)
    {
        response->words[i] = fresh ? state->tx_words[idx][i] : FSAC_GW_NO_DATA_WORD;
    }
    response->word_count = (uint8_t)n;
    response->fresh      = fresh ? 1U : 0U;
}

// interface

fsac_gw_status_t fsac_gw_init(fsac_gw_state_t * state)
{
    if (state == NULL)
    {
        return FSAC_GW_ERR_NULL;
    }
    *state = k_zero_state;
    return FSAC_GW_ACCEPTED_RX;   // 0U is the success code of the init and load functions
}

fsac_gw_status_t fsac_gw_process(fsac_gw_state_t * state, const uint8_t * data,
                                 uint32_t length, uint32_t frame,
                                 fsac_gw_response_t * response)
{
    uint32_t cmd;
    uint32_t rt;
    uint32_t transmit;
    uint32_t subaddr;
    uint32_t count;
    uint32_t n;
    uint32_t expected;
    uint32_t idx;
    uint32_t i;
    uint16_t w[FSAC_GW_MAX_WORDS] = { 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U };

    // the response is written on every call that can write it
    if (response == NULL)
    {
        return FSAC_GW_ERR_NULL;
    }
    clear_response(response);

    // caller errors: no counter moves
    if ((state == NULL) || ((data == NULL) && (length > 0U)))
    {
        return FSAC_GW_ERR_NULL;
    }

    // check 1: length bounds; after this the first bytes may be read, once length >= 2
    if ((length == 0U) || (length > FSAC_GW_MAX_FRAME_BYTES))
    {
        return reject(&state->counters.rej_length, FSAC_GW_REJ_LENGTH);
    }

    // check 2: framing. A frame is whole 16-bit words and holds at least the command word
    if ((length < 2U) || ((length & 1U) != 0U))
    {
        return reject(&state->counters.rej_framing, FSAC_GW_REJ_FRAMING);
    }

    cmd      = (uint32_t)rd16(data);
    rt       = (cmd >> 11) & 0x1FU;
    transmit = (cmd >> 10) & 0x01U;
    subaddr  = (cmd >> 5) & 0x1FU;
    count    = cmd & 0x1FU;
    n        = (count == 0U) ? 32U : count;   // MIL-STD-1553B: a count of 0 means 32 words

    // check 2 (continued): the byte length must equal what the command word implies.
    // A transmit request is the command word alone; a receive frame carries n data words.
    expected = (transmit == 1U) ? 2U : (2U + (2U * n));
    if (length != expected)
    {
        return reject(&state->counters.rej_framing, FSAC_GW_REJ_FRAMING);
    }

    // check 3 and 4: broadcast first, because 31 is also "not the FSAC address"
    if (rt == FSAC_GW_BROADCAST_ADDRESS)
    {
        return reject(&state->counters.rej_broadcast, FSAC_GW_REJ_BROADCAST);
    }
    if (rt != FSAC_GW_RT_ADDRESS)
    {
        return reject(&state->counters.rej_address, FSAC_GW_REJ_ADDRESS);
    }

    // check 5: default deny
    idx = find_row(transmit, subaddr, n);
    if (idx >= FSAC_GW_NUM_MSGS)
    {
        return reject(&state->counters.rej_not_listed, FSAC_GW_REJ_NOT_LISTED);
    }

    // check 6: field ranges and reserved words (receive only).
    // n is at most 8 here, because only table rows can match and they have at most 8 words.
    if (transmit == 0U)
    {
        for (i = 0U; i < n; i++)
        {
            w[i] = rd16(&data[2U + (2U * i)]);
        }
        if (!range_ok(k_table[idx].msg_id, w))
        {
            return reject(&state->counters.rej_range, FSAC_GW_REJ_RANGE);
        }
    }

    // check 7: rate limit
    if (!rate_allow(state, idx, frame))
    {
        return reject(&state->counters.rej_rate, FSAC_GW_REJ_RATE);
    }

    // transmit: answer from the loaded buffer, never from control state
    if (transmit == 1U)
    {
        build_response(state, idx, frame, response);
        bump(&state->counters.accepted_tx);
        return FSAC_GW_ACCEPTED_TX;
    }

    // check 8: output ring full
    if (state->ring_count >= FSAC_GW_RING_DEPTH)
    {
        return reject(&state->counters.rej_overrun, FSAC_GW_REJ_OVERRUN);
    }

    // accepted receive: queue one fixed-size record
    {
        uint32_t           slot = ((uint32_t)state->ring_head + (uint32_t)state->ring_count)
                                  % FSAC_GW_RING_DEPTH;
        fsac_gw_record_t * rec  = &state->ring[slot];

        *rec = k_zero_record;
        rec->msg_id     = (uint16_t)k_table[idx].msg_id;
        rec->word_count = (uint16_t)n;
        rec->seq        = state->seq;
        rec->frame      = frame;
        for (i = 0U; i < n; i++)
        {
            rec->words[i] = w[i];
        }
        state->seq        = state->seq + 1U;   // wraps on purpose, see MISRA NOTES
        state->ring_count = (uint8_t)(state->ring_count + 1U);
    }
    bump(&state->counters.accepted_rx);
    return FSAC_GW_ACCEPTED_RX;
}

fsac_gw_status_t fsac_gw_tx_load(fsac_gw_state_t * state, fsac_gw_msg_id_t msg_id,
                                 const uint16_t * words, uint8_t count, uint32_t frame)
{
    uint32_t idx;
    uint32_t i;

    if ((state == NULL) || (words == NULL))
    {
        return FSAC_GW_ERR_NULL;
    }

    // the message must be a listed transmit row, and the count must be that row's count
    if ((msg_id < FSAC_GW_MSG_NAV_HINT) || ((uint32_t)msg_id > FSAC_GW_NUM_MSGS))
    {
        return FSAC_GW_ERR_ARG;
    }
    idx = (uint32_t)msg_id - 1U;
    if ((k_table[idx].transmit != 1U) || (k_table[idx].words != count))
    {
        return FSAC_GW_ERR_ARG;
    }

    for (i = 0U; i < FSAC_GW_MAX_WORDS; i++)
    {
        state->tx_words[idx][i] = (i < (uint32_t)count) ? words[i] : 0U;
    }
    state->tx_frame[idx] = frame;
    state->tx_valid[idx] = 1U;
    return FSAC_GW_ACCEPTED_RX;   // 0U is the success code of the init and load functions
}

uint8_t fsac_gw_pop(fsac_gw_state_t * state, fsac_gw_record_t * out)
{
    if ((state == NULL) || (out == NULL))
    {
        return 0U;
    }
    if (state->ring_count == 0U)
    {
        *out = k_zero_record;
        return 0U;
    }

    *out = state->ring[state->ring_head];
    state->ring_head  = (uint8_t)(((uint32_t)state->ring_head + 1U) % FSAC_GW_RING_DEPTH);
    state->ring_count = (uint8_t)(state->ring_count - 1U);
    return 1U;
}