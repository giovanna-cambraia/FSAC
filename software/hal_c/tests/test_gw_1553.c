/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/tests/test_gw_1553.c
 * Module      : Tests of the mission gateway parser (MIL-STD-1553B whitelist)
 * Language    : C11
 * Assurance   : Test code, not part of the delivered software
 * Partition   : none (host test program)
 * Requirements: SECR-GW-0001, SECR-GW-0002, SECR-ARC-0001, SECR-ARC-0002,
 *               SECR-TARA-0004 (placeholder IDs)
 *
 * PURPOSE
 *   Exercises every decision path of fsac_gw_1553.c: one test group per row of
 *   the table in docs/04_interface/ICD_mission_bus.md, section 8, plus the
 *   order of the rejection reasons, the rate limit, the output ring, the
 *   transmit path, counter saturation and a deterministic fuzz campaign.
 *   Threats covered: T-01 to T-07 (docs/05_security/TARA.md).
 *
 * HOW THE FRAMES ARE BUILT
 *   Frames are built by the writer in THIS file from the command-word layout
 *   described in the header (RT address bits 15..11, T/R bit 10, subaddress
 *   bits 9..5, word count bits 4..0, little-endian words), not by the code
 *   under test. The whitelist rows and field ranges are the illustrative
 *   values of the ICD (placeholders): NAV_HINT (receive, subaddress 1, 4
 *   words), TIME_SYNC (receive, 2, 2 words), MISSION_MODE (receive, 3, 8
 *   words), FSAC_STATUS (transmit, 1, 6 words), FSAC_SNAPSHOT (transmit, 2, 4
 *   words). When the real message set replaces the ICD table, the expectations
 *   in this file that name those rows must change with it.
 *
 * THE KEY TOOL: step()
 *   step() sends one frame and checks everything a call is allowed to do:
 *   the returned status, that EXACTLY ONE counter moved by exactly one, that
 *   the ring grew by one only for an accepted receive, and that the response is
 *   all zero unless a transmit was accepted. This is how "a rejection only
 *   moves a counter" (property G4, SECR-TARA-0004) is checked on every case.
 *
 * TEST GROUPS
 *   G-01 init and empty ring        G-08 transmit path and staleness
 *   G-02 accepted receive, records  G-09 fsac_gw_tx_load errors
 *   G-03 field ranges, reserved     G-10 counter saturation
 *   G-04 address, not listed, T/R   G-11 NULL arguments
 *   G-05 length sweep (exact alloc) G-12 ring order and wrap
 *   G-06 rejection counters         G-13 deterministic fuzzing
 *   G-07 rate limit and ring full
 *
 * BUILD AND RUN (from software/hal_c/tests)
 *   gcc -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Wshadow -I../include \
 *       -o test_gw_1553 test_gw_1553.c ../src/gw_1553/fsac_gw_1553.c
 *   ./test_gw_1553
 *   Exit code 0 when every check passed, 1 otherwise.
 *   Optional, where the compiler supports it (Linux or WSL): add
 *   -g -fsanitize=address,undefined. Groups G-05 and G-13 allocate every input
 *   at its exact length, so a read outside the frame is caught.
 *
 * MISRA NOTES
 *   * Test code is outside the MISRA claim. It uses the standard library
 *     (stdio, stdlib, string) which the delivered code does not.
 *
 * WHAT THIS DOES NOT COVER
 *   * A real bus controller or bus driver. * Timing. * Behaviour on a target.
 *   * Structural coverage is not measured by this file (use the gcov command
 *     above). * AFDX.
*/

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsac_gw_1553.h"

// check counter
static uint32_t g_run    = 0U;
static uint32_t g_failed = 0U;

static void check_(bool ok, const char * expr, int line)
{
    g_run++;
    if (!ok)
    {
        g_failed++;
        printf("  FAIL line %d: %s\n", line, expr);
    }
}

#define CHECK(cond) check_((cond), #cond, __LINE__)

static void group(const char * name)
{
    printf("%s\n", name);
}

// counters: index mapping, snapshots
#define NUM_COUNTERS  (10U)
#define IX_RX         (0U)
#define IX_TX         (1U)
#define IX_LENGTH     (2U)
#define IX_FRAMING    (3U)
#define IX_BROADCAST  (4U)
#define IX_ADDRESS    (5U)
#define IX_NOT_LISTED (6U)
#define IX_RANGE      (7U)
#define IX_RATE       (8U)
#define IX_OVERRUN    (9U)

static void snap(const fsac_gw_counters_t * c, uint32_t * a)
{
    a[0] = c->accepted_rx;
    a[1] = c->accepted_tx;
    a[2] = c->rej_length;
    a[3] = c->rej_framing;
    a[4] = c->rej_broadcast;
    a[5] = c->rej_address;
    a[6] = c->rej_not_listed;
    a[7] = c->rej_range;
    a[8] = c->rej_rate;
    a[9] = c->rej_overrun;
}

static uint64_t total(const fsac_gw_counters_t * c)
{
    uint32_t a[NUM_COUNTERS];
    uint64_t sum = 0U;
    uint32_t i;

    snap(c, a);
    for (i = 0U; i < NUM_COUNTERS; i++)
    {
        sum += (uint64_t)a[i];
    }
    return sum;
}

// the counter that a status moves, or NUM_COUNTERS for a status that moves none
static uint32_t status_index(fsac_gw_status_t s)
{
    uint32_t ix = NUM_COUNTERS;

    if (s == FSAC_GW_ACCEPTED_RX)    { ix = IX_RX; }
    if (s == FSAC_GW_ACCEPTED_TX)    { ix = IX_TX; }
    if (s == FSAC_GW_REJ_LENGTH)     { ix = IX_LENGTH; }
    if (s == FSAC_GW_REJ_FRAMING)    { ix = IX_FRAMING; }
    if (s == FSAC_GW_REJ_BROADCAST)  { ix = IX_BROADCAST; }
    if (s == FSAC_GW_REJ_ADDRESS)    { ix = IX_ADDRESS; }
    if (s == FSAC_GW_REJ_NOT_LISTED) { ix = IX_NOT_LISTED; }
    if (s == FSAC_GW_REJ_RANGE)      { ix = IX_RANGE; }
    if (s == FSAC_GW_REJ_RATE)       { ix = IX_RATE; }
    if (s == FSAC_GW_REJ_OVERRUN)    { ix = IX_OVERRUN; }
    return ix;
}

// frame writer (independent of the code under test)
static uint32_t cmdw(uint32_t rt, uint32_t tr, uint32_t sub, uint32_t count)
{
    return ((rt & 0x1FU) << 11) | ((tr & 0x01U) << 10) | ((sub & 0x1FU) << 5) | (count & 0x1FU);
}

// writes the command word then n data words, little-endian; returns the length in bytes
static uint32_t mkframe(uint8_t * buf, uint32_t cmd, const uint16_t * w, uint32_t n)
{
    uint32_t i;

    buf[0] = (uint8_t)(cmd & 0xFFU);
    buf[1] = (uint8_t)((cmd >> 8) & 0xFFU);
    for (i = 0U; i < n; i++)
    {
        buf[2U + (2U * i)] = (uint8_t)((uint32_t)w[i] & 0xFFU);
        buf[3U + (2U * i)] = (uint8_t)(((uint32_t)w[i] >> 8) & 0xFFU);
    }
    return 2U + (2U * n);
}

static const uint16_t k_zeros[32] =
{
    0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U,
    0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U
};

// one frame, in a FRESH gateway at frame 0: returns only the status
static fsac_gw_status_t run_rx(uint32_t rt, uint32_t sub, uint32_t count_field,
                               const uint16_t * w, uint32_t nwords)
{
    fsac_gw_state_t    st;
    fsac_gw_response_t resp;
    uint8_t            buf[80];
    uint32_t           len;

    (void)fsac_gw_init(&st);
    len = mkframe(buf, cmdw(rt, 0U, sub, count_field), w, nwords);
    return fsac_gw_process(&st, buf, len, 0U, &resp);
}

static fsac_gw_status_t run_tx(uint32_t rt, uint32_t sub, uint32_t count_field)
{
    fsac_gw_state_t    st;
    fsac_gw_response_t resp;
    uint8_t            buf[8];
    uint32_t           len;

    (void)fsac_gw_init(&st);
    len = mkframe(buf, cmdw(rt, 1U, sub, count_field), k_zeros, 0U);
    return fsac_gw_process(&st, buf, len, 0U, &resp);
}

static bool resp_zero(const fsac_gw_response_t * r)
{
    uint32_t i;
    bool     z = (r->word_count == 0U) && (r->fresh == 0U) && (r->reserved == 0U);

    for (i = 0U; i < FSAC_GW_MAX_WORDS; i++)
    {
        if (r->words[i] != 0U)
        {
            z = false;
        }
    }
    return z;
}

static bool record_zero(const fsac_gw_record_t * r)
{
    uint32_t i;
    bool     z = (r->msg_id == 0U) && (r->word_count == 0U) && (r->seq == 0U)
                 && (r->frame == 0U) && (r->reserved == 0U);

    for (i = 0U; i < FSAC_GW_MAX_WORDS; i++)
    {
        if (r->words[i] != 0U)
        {
            z = false;
        }
    }
    return z;
}

// step(): one call, everything a call may do is checked
static bool step(fsac_gw_state_t * st, const uint8_t * buf, uint32_t len, uint32_t frame,
                 fsac_gw_status_t want, uint32_t idx)
{
    uint32_t           before[NUM_COUNTERS];
    uint32_t           after[NUM_COUNTERS];
    fsac_gw_response_t resp;
    uint8_t            ring_before = st->ring_count;
    uint8_t            ring_want   = (uint8_t)(ring_before + ((want == FSAC_GW_ACCEPTED_RX) ? 1U : 0U));
    fsac_gw_status_t   got;
    uint32_t           i;
    bool               ok = true;

    (void)memset(&resp, 0x55, sizeof(resp));
    snap(&st->counters, before);
    got = fsac_gw_process(st, buf, len, frame, &resp);
    snap(&st->counters, after);

    if (got != want)
    {
        ok = false;
    }
    for (i = 0U; i < NUM_COUNTERS; i++)
    {
        uint32_t expect = before[i] + ((i == idx) ? 1U : 0U);

        if (after[i] != expect)
        {
            ok = false;
        }
    }
    if (st->ring_count != ring_want)
    {
        ok = false;
    }
    if (want == FSAC_GW_ACCEPTED_TX)
    {
        if (resp.word_count == 0U)
        {
            ok = false;
        }
    }
    else
    {
        if (!resp_zero(&resp))
        {
            ok = false;
        }
    }
    if (!ok)
    {
        printf("    step: got status %u, wanted %u, counter index %u\n",
               (unsigned)got, (unsigned)want, (unsigned)idx);
    }
    return ok;
}

// a fully valid receive frame for each message; returns the length
static uint32_t frame_nav(uint8_t * buf, uint16_t w0)
{
    uint16_t w[4];

    w[0] = w0; w[1] = 0x0102U; w[2] = 0x0304U; w[3] = 0x0506U;
    return mkframe(buf, cmdw(FSAC_GW_RT_ADDRESS, 0U, 1U, 4U), w, 4U);
}

static uint32_t frame_time(uint8_t * buf, uint16_t w0, uint16_t w1)
{
    uint16_t w[2];

    w[0] = w0; w[1] = w1;
    return mkframe(buf, cmdw(FSAC_GW_RT_ADDRESS, 0U, 2U, 2U), w, 2U);
}

static uint32_t frame_mode(uint8_t * buf, uint16_t phase)
{
    uint16_t w[8];

    w[0] = phase; w[1] = 0U; w[2] = 0U; w[3] = 0U; w[4] = 0U; w[5] = 0U; w[6] = 0U; w[7] = 0U;
    return mkframe(buf, cmdw(FSAC_GW_RT_ADDRESS, 0U, 3U, 8U), w, 8U);
}

static uint32_t frame_txreq(uint8_t * buf, uint32_t sub, uint32_t count)
{
    return mkframe(buf, cmdw(FSAC_GW_RT_ADDRESS, 1U, sub, count), k_zeros, 0U);
}

// G-01 init and empty ring
static void test_init(void)
{
    fsac_gw_state_t  st;
    fsac_gw_record_t rec;
    uint32_t         i;
    bool             tx_clear = true;

    group("G-01 init and empty ring");
    (void)memset(&st, 0xFF, sizeof(st));
    CHECK(fsac_gw_init(&st) == FSAC_GW_ACCEPTED_RX);
    CHECK(total(&st.counters) == 0U);
    CHECK(st.ring_count == 0U);
    CHECK(st.ring_head == 0U);
    CHECK(st.seq == 0U);
    CHECK(st.has_rate_major == 0U);
    for (i = 0U; i < FSAC_GW_NUM_MSGS; i++)
    {
        if ((st.tx_valid[i] != 0U) || (st.rate_used[i] != 0U))
        {
            tx_clear = false;
        }
    }
    CHECK(tx_clear);
    CHECK(fsac_gw_init(NULL) == FSAC_GW_ERR_NULL);

    (void)memset(&rec, 0xFF, sizeof(rec));
    CHECK(fsac_gw_pop(&st, &rec) == 0U);
    CHECK(record_zero(&rec));
}

// G-02 accepted receive: one frame per row, record content
static void test_accepted_rx(void)
{
    fsac_gw_state_t  st;
    fsac_gw_record_t rec;
    uint8_t          buf[80];
    uint32_t         len;
    uint32_t         i;
    bool             tail_zero;

    group("G-02 accepted receive: one valid frame per row, record content");
    (void)fsac_gw_init(&st);

    // NAV_HINT at frame 7
    len = frame_nav(buf, 0x1234U);
    CHECK(len == 10U);
    CHECK(step(&st, buf, len, 7U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK(rec.msg_id == FSAC_GW_MSG_NAV_HINT);
    CHECK(rec.word_count == 4U);
    CHECK(rec.seq == 0U);
    CHECK(rec.frame == 7U);
    CHECK(rec.reserved == 0U);
    CHECK(rec.words[0] == 0x1234U);
    CHECK(rec.words[1] == 0x0102U);
    CHECK(rec.words[2] == 0x0304U);
    CHECK(rec.words[3] == 0x0506U);
    tail_zero = true;
    for (i = 4U; i < FSAC_GW_MAX_WORDS; i++)
    {
        if (rec.words[i] != 0U)
        {
            tail_zero = false;
        }
    }
    CHECK(tail_zero);
    CHECK(fsac_gw_pop(&st, &rec) == 0U);

    // TIME_SYNC at frame 8
    len = frame_time(buf, 0xFFFFU, 0x0000U);
    CHECK(len == 6U);
    CHECK(step(&st, buf, len, 8U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK(rec.msg_id == FSAC_GW_MSG_TIME_SYNC);
    CHECK(rec.word_count == 2U);
    CHECK(rec.seq == 1U);
    CHECK(rec.frame == 8U);
    CHECK(rec.words[0] == 0xFFFFU);
    CHECK(rec.words[1] == 0x0000U);
    CHECK(rec.words[2] == 0U);

    // MISSION_MODE at frame 9: the longest accepted frame, 18 bytes
    len = frame_mode(buf, 7U);
    CHECK(len == FSAC_GW_MAX_FRAME_BYTES);
    CHECK(step(&st, buf, len, 9U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK(rec.msg_id == FSAC_GW_MSG_MISSION_MODE);
    CHECK(rec.word_count == 8U);
    CHECK(rec.seq == 2U);
    CHECK(rec.frame == 9U);
    CHECK(rec.words[0] == 7U);
    CHECK(rec.words[7] == 0U);

    CHECK(st.counters.accepted_rx == 3U);
    CHECK(total(&st.counters) == 3U);
}

// G-03 field ranges and reserved words (ICD 4.1, threat T-03)
static void test_ranges(void)
{
    static const uint16_t nav_ok[]  = { 0x0000U, 0x0001U, 0x4000U, 0xC000U, 0xFFFFU };
    static const uint16_t nav_bad[] = { 0x4001U, 0xBFFFU, 0x8000U, 0x7FFFU };
    uint16_t              w[8];
    uint32_t              i;
    uint32_t              k;

    group("G-03 field ranges and reserved words");

    // NAV_HINT word 0: signed, -16384 .. 16384
    for (i = 0U; i < (sizeof(nav_ok) / sizeof(nav_ok[0])); i++)
    {
        w[0] = nav_ok[i]; w[1] = 0U; w[2] = 0U; w[3] = 0U;
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 1U, 4U, w, 4U) == FSAC_GW_ACCEPTED_RX);
    }
    for (i = 0U; i < (sizeof(nav_bad) / sizeof(nav_bad[0])); i++)
    {
        w[0] = nav_bad[i]; w[1] = 0U; w[2] = 0U; w[3] = 0U;
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 1U, 4U, w, 4U) == FSAC_GW_REJ_RANGE);
    }
    // the other three words of NAV_HINT are unconstrained
    w[0] = 0U; w[1] = 0xFFFFU; w[2] = 0xFFFFU; w[3] = 0xFFFFU;
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 1U, 4U, w, 4U) == FSAC_GW_ACCEPTED_RX);

    // TIME_SYNC: any value
    w[0] = 0U; w[1] = 0U;
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 2U, 2U, w, 2U) == FSAC_GW_ACCEPTED_RX);
    w[0] = 0xFFFFU; w[1] = 0xFFFFU;
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 2U, 2U, w, 2U) == FSAC_GW_ACCEPTED_RX);
    w[0] = 0x1234U; w[1] = 0xABCDU;
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 2U, 2U, w, 2U) == FSAC_GW_ACCEPTED_RX);

    // MISSION_MODE phase: 0 .. 7 accepted, 8 and above refused
    for (i = 0U; i < 8U; i++)
    {
        (void)memset(w, 0, sizeof(w));
        w[0] = (uint16_t)i;
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 3U, 8U, w, 8U) == FSAC_GW_ACCEPTED_RX);
    }
    (void)memset(w, 0, sizeof(w));
    w[0] = 8U;
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 3U, 8U, w, 8U) == FSAC_GW_REJ_RANGE);
    w[0] = 0x8000U;
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 3U, 8U, w, 8U) == FSAC_GW_REJ_RANGE);
    w[0] = 0xFFFFU;
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 3U, 8U, w, 8U) == FSAC_GW_REJ_RANGE);

    // MISSION_MODE reserved words 1..7: any non-zero value is a rejection
    for (k = 1U; k < 8U; k++)
    {
        (void)memset(w, 0, sizeof(w));
        w[k] = 1U;
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 3U, 8U, w, 8U) == FSAC_GW_REJ_RANGE);
        w[k] = 0xFFFFU;
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 3U, 8U, w, 8U) == FSAC_GW_REJ_RANGE);
        w[k] = 0x8000U;
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 3U, 8U, w, 8U) == FSAC_GW_REJ_RANGE);
    }

    // a rejected range leaves no record
    {
        fsac_gw_state_t  st;
        fsac_gw_record_t rec;
        uint8_t          buf[80];
        uint32_t         len;

        (void)fsac_gw_init(&st);
        len = frame_nav(buf, 0x7FFFU);
        CHECK(step(&st, buf, len, 0U, FSAC_GW_REJ_RANGE, IX_RANGE));
        CHECK(fsac_gw_pop(&st, &rec) == 0U);
        CHECK(st.seq == 0U);
    }
}

// G-04 address, not listed, T/R, count zero, transmit framing
static void test_whitelist(void)
{
    uint32_t sub;
    uint32_t cnt;
    uint32_t rt;
    uint16_t w[8];

    group("G-04 address, default deny, T/R, word count");

    // every RT address with an otherwise valid NAV_HINT frame
    for (rt = 0U; rt < 32U; rt++)
    {
        fsac_gw_status_t s = run_rx(rt, 1U, 4U, k_zeros, 4U);

        if (rt == FSAC_GW_RT_ADDRESS)
        {
            CHECK(s == FSAC_GW_ACCEPTED_RX);
        }
        else if (rt == FSAC_GW_BROADCAST_ADDRESS)
        {
            CHECK(s == FSAC_GW_REJ_BROADCAST);
        }
        else
        {
            CHECK(s == FSAC_GW_REJ_ADDRESS);
        }
    }
    // broadcast with the transmit bit, and a wrong address with the transmit bit
    CHECK(run_tx(FSAC_GW_BROADCAST_ADDRESS, 1U, 6U) == FSAC_GW_REJ_BROADCAST);
    CHECK(run_tx(4U, 1U, 6U) == FSAC_GW_REJ_ADDRESS);
    CHECK(run_tx(6U, 2U, 4U) == FSAC_GW_REJ_ADDRESS);

    // every subaddress with a 4-word receive frame: only subaddress 1 is listed for 4 words
    for (sub = 0U; sub < 32U; sub++)
    {
        fsac_gw_status_t s = run_rx(FSAC_GW_RT_ADDRESS, sub, 4U, k_zeros, 4U);

        CHECK(s == ((sub == 1U) ? FSAC_GW_ACCEPTED_RX : FSAC_GW_REJ_NOT_LISTED));
    }

    // word count 1..8 on each receive subaddress: only the listed count is accepted
    for (cnt = 1U; cnt <= 8U; cnt++)
    {
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 1U, cnt, k_zeros, cnt)
              == ((cnt == 4U) ? FSAC_GW_ACCEPTED_RX : FSAC_GW_REJ_NOT_LISTED));
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 2U, cnt, k_zeros, cnt)
              == ((cnt == 2U) ? FSAC_GW_ACCEPTED_RX : FSAC_GW_REJ_NOT_LISTED));
        CHECK(run_rx(FSAC_GW_RT_ADDRESS, 3U, cnt, k_zeros, cnt)
              == ((cnt == 8U) ? FSAC_GW_ACCEPTED_RX : FSAC_GW_REJ_NOT_LISTED));
    }

    // a word count field of 0 means 32 words on the bus
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 1U, 0U, k_zeros, 32U) == FSAC_GW_REJ_LENGTH);    // 66 bytes
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 1U, 0U, k_zeros, 8U) == FSAC_GW_REJ_FRAMING);    // 18 bytes, 66 implied
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 1U, 0U, k_zeros, 0U) == FSAC_GW_REJ_FRAMING);    // 2 bytes, 66 implied

    // transmit requests: all 32 subaddresses by all 32 count fields; exactly two rows are listed
    for (sub = 0U; sub < 32U; sub++)
    {
        for (cnt = 0U; cnt < 32U; cnt++)
        {
            fsac_gw_status_t s = run_tx(FSAC_GW_RT_ADDRESS, sub, cnt);
            bool             listed = ((sub == 1U) && (cnt == 6U)) || ((sub == 2U) && (cnt == 4U));

            CHECK(s == (listed ? FSAC_GW_ACCEPTED_TX : FSAC_GW_REJ_NOT_LISTED));
        }
    }

    // a transmit request is the command word ALONE: any extra bytes are a framing error
    w[0] = 0U; w[1] = 0U; w[2] = 0U; w[3] = 0U; w[4] = 0U; w[5] = 0U; w[6] = 0U; w[7] = 0U;
    {
        fsac_gw_state_t    st;
        fsac_gw_response_t resp;
        uint8_t            buf[80];
        uint32_t           len;

        (void)fsac_gw_init(&st);
        len = mkframe(buf, cmdw(FSAC_GW_RT_ADDRESS, 1U, 1U, 6U), w, 1U);     // 4 bytes
        CHECK(len == 4U);
        CHECK(fsac_gw_process(&st, buf, len, 0U, &resp) == FSAC_GW_REJ_FRAMING);
        len = mkframe(buf, cmdw(FSAC_GW_RT_ADDRESS, 1U, 1U, 6U), w, 6U);     // 14 bytes, like a receive
        CHECK(len == 14U);
        CHECK(fsac_gw_process(&st, buf, len, 0U, &resp) == FSAC_GW_REJ_FRAMING);
    }

    // the T/R bit is part of the key: the transmit row's numbers with the receive bit
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 1U, 6U, k_zeros, 6U) == FSAC_GW_REJ_NOT_LISTED);
    CHECK(run_rx(FSAC_GW_RT_ADDRESS, 2U, 4U, k_zeros, 4U) == FSAC_GW_REJ_NOT_LISTED);
}

// G-05 length sweep with exact-size allocation (threat T-01)
static void test_length_sweep(void)
{
    uint8_t  nav[80];
    uint8_t  req[80];
    uint32_t nav_len;
    uint32_t req_len;
    uint32_t len;

    group("G-05 length sweep 0..40, exact-size allocation");

    nav_len = frame_nav(nav, 0x0010U);       // 10 bytes
    req_len = frame_txreq(req, 1U, 6U);      // 2 bytes
    CHECK(nav_len == 10U);
    CHECK(req_len == 2U);
    (void)memset(&nav[nav_len], 0xAA, sizeof(nav) - nav_len);   // garbage after the frame
    (void)memset(&req[req_len], 0xAA, sizeof(req) - req_len);

    for (len = 0U; len <= 40U; len++)
    {
        uint32_t           alloc = (len > 0U) ? len : 1U;
        uint8_t *          p     = (uint8_t *)malloc(alloc);
        fsac_gw_state_t    st;
        fsac_gw_response_t resp;
        fsac_gw_status_t   want_nav;
        fsac_gw_status_t   want_req;

        if (p == NULL)
        {
            CHECK(false);
            continue;
        }

        // length rule shared by both frames
        if ((len == 0U) || (len > FSAC_GW_MAX_FRAME_BYTES))
        {
            want_nav = FSAC_GW_REJ_LENGTH;
            want_req = FSAC_GW_REJ_LENGTH;
        }
        else
        {
            want_nav = (len == nav_len) ? FSAC_GW_ACCEPTED_RX : FSAC_GW_REJ_FRAMING;
            want_req = (len == req_len) ? FSAC_GW_ACCEPTED_TX : FSAC_GW_REJ_FRAMING;
        }

        (void)memcpy(p, nav, len);
        (void)fsac_gw_init(&st);
        CHECK(fsac_gw_process(&st, p, len, 0U, &resp) == want_nav);
        CHECK(total(&st.counters) == 1U);

        (void)memcpy(p, req, len);
        (void)fsac_gw_init(&st);
        CHECK(fsac_gw_process(&st, p, len, 0U, &resp) == want_req);
        CHECK(total(&st.counters) == 1U);

        free(p);
    }

    // length 0 is a rejection whatever the pointer is
    {
        fsac_gw_state_t    st;
        fsac_gw_response_t resp;
        uint8_t            one = 0U;

        (void)fsac_gw_init(&st);
        CHECK(fsac_gw_process(&st, &one, 0U, 0U, &resp) == FSAC_GW_REJ_LENGTH);
        CHECK(fsac_gw_process(&st, NULL, 0U, 0U, &resp) == FSAC_GW_REJ_LENGTH);
        CHECK(st.counters.rej_length == 2U);
        // an absurd length is rejected without reading anything
        CHECK(fsac_gw_process(&st, &one, 0xFFFFFFFFU, 0U, &resp) == FSAC_GW_REJ_LENGTH);
        CHECK(st.counters.rej_length == 3U);
    }
}

// G-06 each rejection moves exactly its own counter
static void test_counters_one_by_one(void)
{
    fsac_gw_state_t st;
    uint8_t         buf[80];
    uint32_t        len;
    uint16_t        w[8];

    group("G-06 each outcome moves exactly its own counter");
    (void)fsac_gw_init(&st);

    // REJ_LENGTH, REJ_FRAMING
    len = frame_nav(buf, 0U);
    CHECK(step(&st, buf, 0U, 0U, FSAC_GW_REJ_LENGTH, IX_LENGTH));
    CHECK(step(&st, buf, 19U, 0U, FSAC_GW_REJ_LENGTH, IX_LENGTH));
    CHECK(step(&st, buf, len - 1U, 0U, FSAC_GW_REJ_FRAMING, IX_FRAMING));
    CHECK(step(&st, buf, 4U, 0U, FSAC_GW_REJ_FRAMING, IX_FRAMING));

    // REJ_BROADCAST, REJ_ADDRESS
    len = mkframe(buf, cmdw(31U, 0U, 1U, 4U), k_zeros, 4U);
    CHECK(step(&st, buf, len, 0U, FSAC_GW_REJ_BROADCAST, IX_BROADCAST));
    len = mkframe(buf, cmdw(9U, 0U, 1U, 4U), k_zeros, 4U);
    CHECK(step(&st, buf, len, 0U, FSAC_GW_REJ_ADDRESS, IX_ADDRESS));

    // REJ_NOT_LISTED
    len = mkframe(buf, cmdw(FSAC_GW_RT_ADDRESS, 0U, 9U, 4U), k_zeros, 4U);
    CHECK(step(&st, buf, len, 0U, FSAC_GW_REJ_NOT_LISTED, IX_NOT_LISTED));

    // REJ_RANGE
    w[0] = 0x4001U; w[1] = 0U; w[2] = 0U; w[3] = 0U;
    len = mkframe(buf, cmdw(FSAC_GW_RT_ADDRESS, 0U, 1U, 4U), w, 4U);
    CHECK(step(&st, buf, len, 0U, FSAC_GW_REJ_RANGE, IX_RANGE));

    // every rejection above left the ring empty and no record behind
    CHECK(st.ring_count == 0U);
    CHECK(st.seq == 0U);
    CHECK(st.counters.accepted_rx == 0U);
    CHECK(st.counters.accepted_tx == 0U);
    CHECK(total(&st.counters) == 9U);

    // accepted receive and accepted transmit
    len = frame_nav(buf, 0U);
    CHECK(step(&st, buf, len, 4U, FSAC_GW_ACCEPTED_RX, IX_RX));
    len = frame_txreq(buf, 1U, 6U);
    CHECK(step(&st, buf, len, 4U, FSAC_GW_ACCEPTED_TX, IX_TX));
    CHECK(total(&st.counters) == 11U);
}

// G-07 rate limit and a full ring (threat T-04)
static void test_rate_and_ring(void)
{
    fsac_gw_state_t  st;
    fsac_gw_record_t rec;
    uint8_t          buf[80];
    uint32_t         len;

    group("G-07 rate limit per message per major frame, and a full ring");

    // two per major frame, the third is refused; frames 0..3 are one major frame
    (void)fsac_gw_init(&st);
    len = frame_nav(buf, 1U);
    CHECK(step(&st, buf, len, 0U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(step(&st, buf, len, 1U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(step(&st, buf, len, 2U, FSAC_GW_REJ_RATE, IX_RATE));
    CHECK(step(&st, buf, len, 3U, FSAC_GW_REJ_RATE, IX_RATE));
    // frame 4 is the next major frame: the allowance is renewed
    CHECK(step(&st, buf, len, 4U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK((rec.seq == 0U) && (rec.frame == 0U));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK((rec.seq == 1U) && (rec.frame == 1U));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK((rec.seq == 2U) && (rec.frame == 4U));
    CHECK(fsac_gw_pop(&st, &rec) == 0U);

    // the limit is per message id: fill NAV and TIME (ring 4), drain, then MISSION still has its own two
    (void)fsac_gw_init(&st);
    len = frame_nav(buf, 1U);
    CHECK(step(&st, buf, len, 8U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(step(&st, buf, len, 8U, FSAC_GW_ACCEPTED_RX, IX_RX));
    len = frame_time(buf, 1U, 2U);
    CHECK(step(&st, buf, len, 8U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(step(&st, buf, len, 8U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(st.ring_count == 4U);
    while (fsac_gw_pop(&st, &rec) == 1U)
    {
        // drain
    }
    len = frame_mode(buf, 3U);
    CHECK(step(&st, buf, len, 9U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(step(&st, buf, len, 9U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(step(&st, buf, len, 9U, FSAC_GW_REJ_RATE, IX_RATE));
    len = frame_nav(buf, 1U);
    CHECK(step(&st, buf, len, 9U, FSAC_GW_REJ_RATE, IX_RATE));    // NAV already used its two in this major frame

    // a full ring: the new record is dropped, the old ones are intact
    (void)fsac_gw_init(&st);
    len = frame_nav(buf, 0x0A0AU);
    CHECK(step(&st, buf, len, 0U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(step(&st, buf, len, 0U, FSAC_GW_ACCEPTED_RX, IX_RX));
    len = frame_time(buf, 0x0B0BU, 0x0C0CU);
    CHECK(step(&st, buf, len, 0U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(step(&st, buf, len, 0U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(st.ring_count == FSAC_GW_RING_DEPTH);

    len = frame_nav(buf, 0xDEADU & 0x3FFFU);
    CHECK(step(&st, buf, len, 4U, FSAC_GW_REJ_OVERRUN, IX_OVERRUN));
    CHECK(step(&st, buf, len, 4U, FSAC_GW_REJ_OVERRUN, IX_OVERRUN));
    // an overrun still used a rate slot: the third NAV in this major frame is a RATE rejection
    CHECK(step(&st, buf, len, 4U, FSAC_GW_REJ_RATE, IX_RATE));
    CHECK(st.ring_count == FSAC_GW_RING_DEPTH);
    CHECK(st.seq == 4U);                  // the dropped messages took no sequence number

    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK((rec.msg_id == FSAC_GW_MSG_NAV_HINT) && (rec.seq == 0U) && (rec.words[0] == 0x0A0AU));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK((rec.msg_id == FSAC_GW_MSG_NAV_HINT) && (rec.seq == 1U));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK((rec.msg_id == FSAC_GW_MSG_TIME_SYNC) && (rec.seq == 2U) && (rec.words[0] == 0x0B0BU));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK((rec.msg_id == FSAC_GW_MSG_TIME_SYNC) && (rec.seq == 3U) && (rec.words[1] == 0x0C0CU));
    CHECK(fsac_gw_pop(&st, &rec) == 0U);

    // after draining, the ring accepts again and the sequence continues
    len = frame_time(buf, 5U, 6U);
    CHECK(step(&st, buf, len, 5U, FSAC_GW_ACCEPTED_RX, IX_RX));
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK(rec.seq == 4U);
}

// G-08 transmit path and staleness (ICD rules TX-1 to TX-4)
static bool response_is(const fsac_gw_response_t * r, const uint16_t * want, uint32_t n, uint8_t fresh)
{
    uint32_t i;
    bool     ok = (r->word_count == (uint8_t)n) && (r->fresh == fresh) && (r->reserved == 0U);

    for (i = 0U; i < FSAC_GW_MAX_WORDS; i++)
    {
        uint16_t expect = (i < n) ? want[i] : 0U;

        if (r->words[i] != expect)
        {
            ok = false;
        }
    }
    return ok;
}

static void test_transmit(void)
{
    static const uint16_t status_w[6]   = { 1U, 2U, 3U, 4U, 5U, 6U };
    static const uint16_t snap_w[4]     = { 0x000AU, 0x000BU, 0x000CU, 0x000DU };
    static const uint16_t no_data6[6]   = { 0xFFFFU, 0xFFFFU, 0xFFFFU, 0xFFFFU, 0xFFFFU, 0xFFFFU };
    static const uint16_t no_data4[4]   = { 0xFFFFU, 0xFFFFU, 0xFFFFU, 0xFFFFU };
    fsac_gw_state_t       st;
    fsac_gw_response_t    resp;
    uint8_t               req1[8];
    uint8_t               req2[8];
    uint32_t              l1;
    uint32_t              l2;

    group("G-08 transmit path: no data, fresh, stale, rate limit");
    (void)fsac_gw_init(&st);
    l1 = frame_txreq(req1, 1U, 6U);     // FSAC_STATUS
    l2 = frame_txreq(req2, 2U, 4U);     // FSAC_SNAPSHOT

    // never loaded: the "no data" pattern, never whatever was in memory (TX-4)
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req1, l1, 0U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, no_data6, 6U, 0U));
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req2, l2, 0U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, no_data4, 4U, 0U));
    CHECK(st.counters.accepted_tx == 2U);
    CHECK(st.ring_count == 0U);          // a transmit request never queues a record

    // load both, then request at frame 4 (major 1): fresh
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, status_w, 6U, 0U) == FSAC_GW_ACCEPTED_RX);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_SNAPSHOT, snap_w, 4U, 0U) == FSAC_GW_ACCEPTED_RX);
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req1, l1, 4U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, status_w, 6U, 1U));
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req2, l2, 4U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, snap_w, 4U, 1U));

    // second request in major 1 is fine, the third is a RATE rejection with an empty response
    CHECK(fsac_gw_process(&st, req1, l1, 5U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(fsac_gw_process(&st, req1, l1, 6U, &resp) == FSAC_GW_REJ_RATE);
    CHECK(resp_zero(&resp));

    // age in major frames: loaded in major 0, still fresh in major 5, stale in major 6
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req1, l1, 20U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, status_w, 6U, 1U));
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req1, l1, 24U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, no_data6, 6U, 0U));

    // reloading makes it fresh again
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, status_w, 6U, 24U) == FSAC_GW_ACCEPTED_RX);
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req1, l1, 24U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, status_w, 6U, 1U));

    // data "loaded in the future" is not trusted: loaded at major 25, requested at major 10
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, status_w, 6U, 100U) == FSAC_GW_ACCEPTED_RX);
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req1, l1, 40U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, no_data6, 6U, 0U));

    // the two rows are independent: the snapshot buffer is still the one loaded at frame 0
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, req2, l2, 40U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(response_is(&resp, no_data4, 4U, 0U));     // major 10 against a load in major 0: stale
}

// G-09 fsac_gw_tx_load errors: nothing is written on error
static void test_tx_load_errors(void)
{
    static const uint16_t w6[6] = { 1U, 2U, 3U, 4U, 5U, 6U };
    fsac_gw_state_t       st;
    uint32_t              i;
    bool                  nothing = true;

    group("G-09 tx_load errors");
    (void)fsac_gw_init(&st);

    CHECK(fsac_gw_tx_load(NULL, FSAC_GW_MSG_FSAC_STATUS, w6, 6U, 0U) == FSAC_GW_ERR_NULL);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, NULL, 6U, 0U) == FSAC_GW_ERR_NULL);

    // not a message, not a transmit row, wrong count
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_NONE, w6, 6U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, (fsac_gw_msg_id_t)6U, w6, 6U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, (fsac_gw_msg_id_t)255U, w6, 6U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_NAV_HINT, w6, 4U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_TIME_SYNC, w6, 2U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_MISSION_MODE, w6, 8U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, w6, 5U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, w6, 7U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, w6, 0U, 0U) == FSAC_GW_ERR_ARG);
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_SNAPSHOT, w6, 6U, 0U) == FSAC_GW_ERR_ARG);

    // none of those wrote anything, and no bus counter moved
    for (i = 0U; i < FSAC_GW_NUM_MSGS; i++)
    {
        if (st.tx_valid[i] != 0U)
        {
            nothing = false;
        }
    }
    CHECK(nothing);
    CHECK(total(&st.counters) == 0U);

    // the good loads, and unused words of the buffer are zeroed
    CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, w6, 6U, 3U) == FSAC_GW_ACCEPTED_RX);
    CHECK(st.tx_valid[3] == 1U);
    CHECK(st.tx_frame[3] == 3U);
    CHECK(st.tx_words[3][5] == 6U);
    CHECK(st.tx_words[3][6] == 0U);
    CHECK(st.tx_words[3][7] == 0U);
}

// G-10 counter saturation (rule R9): a flood cannot reset its own evidence
static void test_saturation(void)
{
    fsac_gw_state_t    st;
    fsac_gw_response_t resp;
    fsac_gw_record_t   rec;
    uint8_t            buf[80];
    uint32_t           len;

    group("G-10 counters saturate and never wrap");

    // rejection counter
    (void)fsac_gw_init(&st);
    st.counters.rej_length = UINT32_MAX;
    CHECK(fsac_gw_process(&st, buf, 0U, 0U, &resp) == FSAC_GW_REJ_LENGTH);
    CHECK(st.counters.rej_length == UINT32_MAX);
    CHECK(total(&st.counters) == (uint64_t)UINT32_MAX);

    // accepted receive counter: the record is still queued
    (void)fsac_gw_init(&st);
    st.counters.accepted_rx = UINT32_MAX;
    len = frame_nav(buf, 5U);
    CHECK(fsac_gw_process(&st, buf, len, 0U, &resp) == FSAC_GW_ACCEPTED_RX);
    CHECK(st.counters.accepted_rx == UINT32_MAX);
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK(rec.words[0] == 5U);

    // accepted transmit counter
    (void)fsac_gw_init(&st);
    st.counters.accepted_tx = UINT32_MAX;
    len = frame_txreq(buf, 1U, 6U);
    CHECK(fsac_gw_process(&st, buf, len, 0U, &resp) == FSAC_GW_ACCEPTED_TX);
    CHECK(st.counters.accepted_tx == UINT32_MAX);

    // overrun and rate counters
    (void)fsac_gw_init(&st);
    st.counters.rej_rate = UINT32_MAX;
    len = frame_nav(buf, 1U);
    (void)fsac_gw_process(&st, buf, len, 0U, &resp);
    (void)fsac_gw_process(&st, buf, len, 0U, &resp);
    CHECK(fsac_gw_process(&st, buf, len, 0U, &resp) == FSAC_GW_REJ_RATE);
    CHECK(st.counters.rej_rate == UINT32_MAX);

    // the sequence number is not a counter: it is allowed to wrap, and it does so cleanly
    (void)fsac_gw_init(&st);
    st.seq = UINT32_MAX;
    len = frame_nav(buf, 1U);
    CHECK(fsac_gw_process(&st, buf, len, 0U, &resp) == FSAC_GW_ACCEPTED_RX);
    CHECK(fsac_gw_pop(&st, &rec) == 1U);
    CHECK(rec.seq == UINT32_MAX);
    CHECK(st.seq == 0U);
}

// G-11 NULL arguments
static void test_null_args(void)
{
    fsac_gw_state_t    st;
    fsac_gw_response_t resp;
    fsac_gw_record_t   rec;
    uint8_t            buf[80];
    uint32_t           len;

    group("G-11 NULL arguments are caller errors: no counter moves");
    (void)fsac_gw_init(&st);
    len = frame_nav(buf, 1U);

    // NULL state: the response is still cleared
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(NULL, buf, len, 0U, &resp) == FSAC_GW_ERR_NULL);
    CHECK(resp_zero(&resp));

    // NULL response: nothing to write, and no counter moves
    CHECK(fsac_gw_process(&st, buf, len, 0U, NULL) == FSAC_GW_ERR_NULL);
    CHECK(total(&st.counters) == 0U);

    // NULL data with a length above zero
    (void)memset(&resp, 0x55, sizeof(resp));
    CHECK(fsac_gw_process(&st, NULL, len, 0U, &resp) == FSAC_GW_ERR_NULL);
    CHECK(resp_zero(&resp));
    CHECK(total(&st.counters) == 0U);
    CHECK(st.ring_count == 0U);

    // pop with NULL arguments
    CHECK(fsac_gw_pop(NULL, &rec) == 0U);
    CHECK(fsac_gw_pop(&st, NULL) == 0U);
}

// G-12 ring order and wrap
static void test_ring_wrap(void)
{
    fsac_gw_state_t    st;
    fsac_gw_response_t resp;
    fsac_gw_record_t   rec;
    uint8_t            buf[80];
    uint32_t           round;
    uint32_t           k;
    uint32_t           next_seq = 0U;
    uint32_t           frame    = 0U;
    uint32_t           pushed   = 0U;

    group("G-12 ring order and wrap (three in, three out, many rounds)");
    (void)fsac_gw_init(&st);

    for (round = 0U; round < 8U; round++)
    {
        uint32_t first_pushed = pushed;

        // three records, each in its own major frame so the rate limit never interferes
        for (k = 0U; k < 3U; k++)
        {
            uint32_t len = frame_time(buf, (uint16_t)pushed, (uint16_t)(0xFFFFU - pushed));

            frame += 4U;
            CHECK(fsac_gw_process(&st, buf, len, frame, &resp) == FSAC_GW_ACCEPTED_RX);
            pushed++;
        }
        CHECK(st.ring_count == 3U);

        // popped in the same order, with consecutive sequence numbers and the right words
        for (k = 0U; k < 3U; k++)
        {
            CHECK(fsac_gw_pop(&st, &rec) == 1U);
            CHECK(rec.seq == next_seq);
            CHECK(rec.words[0] == (uint16_t)(first_pushed + k));
            CHECK(rec.words[1] == (uint16_t)(0xFFFFU - (first_pushed + k)));
            next_seq++;
        }
        CHECK(fsac_gw_pop(&st, &rec) == 0U);
        CHECK(st.ring_head < FSAC_GW_RING_DEPTH);
    }
    CHECK(pushed == 24U);
    CHECK(st.counters.accepted_rx == 24U);
}

// G-13 deterministic fuzzing (threat T-01)
static uint32_t g_rng = 0x1BADB002U;      // fixed seed: the campaign is repeatable

static uint32_t rnd(void)
{
    uint32_t x = g_rng;

    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    g_rng = x;
    return x;
}

// independent check of a popped record against the ICD (placeholders)
static bool record_valid(const fsac_gw_record_t * r)
{
    uint32_t i;
    uint32_t want_words = 0U;
    bool     ok = true;

    if (r->msg_id == FSAC_GW_MSG_NAV_HINT)          { want_words = 4U; }
    else if (r->msg_id == FSAC_GW_MSG_TIME_SYNC)    { want_words = 2U; }
    else if (r->msg_id == FSAC_GW_MSG_MISSION_MODE) { want_words = 8U; }
    else                                            { return false; }

    if ((r->word_count != want_words) || (r->reserved != 0U))
    {
        ok = false;
    }
    for (i = want_words; i < FSAC_GW_MAX_WORDS; i++)
    {
        if (r->words[i] != 0U)
        {
            ok = false;
        }
    }
    if (r->msg_id == FSAC_GW_MSG_NAV_HINT)
    {
        int32_t lat = (r->words[0] >= 0x8000U) ? ((int32_t)r->words[0] - 65536) : (int32_t)r->words[0];

        if ((lat < -16384) || (lat > 16384))
        {
            ok = false;
        }
    }
    if (r->msg_id == FSAC_GW_MSG_MISSION_MODE)
    {
        if (r->words[0] > 7U)
        {
            ok = false;
        }
        for (i = 1U; i < 8U; i++)
        {
            if (r->words[i] != 0U)
            {
                ok = false;
            }
        }
    }
    return ok;
}

static uint16_t rnd_word(void)
{
    uint32_t sel = rnd() % 4U;

    if (sel == 0U) { return 0U; }
    if (sel == 1U) { return (uint16_t)(rnd() % 8U); }
    if (sel == 2U) { return (uint16_t)(rnd() % 0x4100U); }
    return (uint16_t)(rnd() & 0xFFFFU);
}

static void test_fuzz(void)
{
    enum { ITER = 200000 };
    fsac_gw_state_t  st;
    uint32_t         tally[12];
    uint32_t         frame        = 0U;
    uint32_t         expect_seq   = 0U;
    uint32_t         fresh_count  = 0U;
    uint32_t         stale_count  = 0U;
    uint32_t         bad_invariant = 0U;
    uint32_t         bad_record    = 0U;
    uint32_t         it;
    uint32_t         i;

    group("G-13 deterministic fuzzing: 200000 frames, fixed seed");
    (void)fsac_gw_init(&st);
    for (i = 0U; i < 12U; i++)
    {
        tally[i] = 0U;
    }

    for (it = 0U; it < (uint32_t)ITER; it++)
    {
        uint8_t            local[96];
        uint8_t *          heap;
        fsac_gw_response_t resp;
        uint32_t           before[NUM_COUNTERS];
        uint32_t           after[NUM_COUNTERS];
        uint8_t            ring_before;
        uint32_t           len;
        uint32_t           mode;
        fsac_gw_status_t   s;
        uint32_t           ix;

        // time moves slowly, so the rate limit and the ring are really exercised
        if ((rnd() % 8U) == 0U)
        {
            frame += rnd() % 3U;
        }

        // sometimes the application loads transmit data, sometimes it is old
        if ((rnd() % 64U) == 0U)
        {
            uint16_t w[6];
            uint32_t back = rnd() % 40U;
            uint32_t ld   = (frame > back) ? (frame - back) : 0U;

            for (i = 0U; i < 6U; i++)
            {
                w[i] = (uint16_t)(rnd() & 0xFFFFU);
            }
            if ((rnd() & 1U) == 0U)
            {
                CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_STATUS, w, 6U, ld) == FSAC_GW_ACCEPTED_RX);
            }
            else
            {
                CHECK(fsac_gw_tx_load(&st, FSAC_GW_MSG_FSAC_SNAPSHOT, w, 4U, ld) == FSAC_GW_ACCEPTED_RX);
            }
        }

        // sometimes the consumer pops a record, and the record is checked
        if ((rnd() % 8U) == 0U)
        {
            fsac_gw_record_t rec;

            if (fsac_gw_pop(&st, &rec) == 1U)
            {
                if (!record_valid(&rec) || (rec.seq != expect_seq))
                {
                    bad_record++;
                }
                expect_seq++;
            }
        }

        // choose a frame: structured (reaches deep checks) or random bytes
        mode = rnd() % 4U;
        len  = rnd() % 25U;
        for (i = 0U; i < 96U; i++)
        {
            local[i] = (uint8_t)(rnd() & 0xFFU);
        }
        if (mode <= 1U)
        {
            // a structured command word with a mostly consistent length
            uint32_t pick = rnd() % 6U;
            uint32_t rtv  = rnd() % 16U;
            uint32_t rt   = (rtv < 12U) ? FSAC_GW_RT_ADDRESS : ((rtv == 12U) ? 31U : (rnd() % 32U));
            uint32_t tr   = 0U;
            uint32_t sub  = 1U;
            uint32_t cnt  = 4U;
            uint32_t n;
            uint16_t w[32];

            if (pick == 0U)      { tr = 0U; sub = 1U; cnt = 4U; }
            else if (pick == 1U) { tr = 0U; sub = 2U; cnt = 2U; }
            else if (pick == 2U) { tr = 0U; sub = 3U; cnt = 8U; }
            else if (pick == 3U) { tr = 1U; sub = 1U; cnt = 6U; }
            else if (pick == 4U) { tr = 1U; sub = 2U; cnt = 4U; }
            else                 { tr = rnd() % 2U; sub = rnd() % 32U; cnt = rnd() % 32U; }

            n = (cnt == 0U) ? 32U : cnt;
            for (i = 0U; i < 32U; i++)
            {
                w[i] = rnd_word();
            }
            // half the mission-mode frames get clean reserved words so they can be accepted
            if ((pick == 2U) && ((rnd() & 1U) == 0U))
            {
                for (i = 1U; i < 8U; i++)
                {
                    w[i] = 0U;
                }
                w[0] = (uint16_t)(rnd() % 8U);
            }
            len = (tr == 1U) ? 2U : (2U + (2U * n));
            if (len > 90U)
            {
                len = 90U;
            }
            (void)mkframe(local, cmdw(rt, tr, sub, cnt), w, (tr == 1U) ? 0U : ((n > 44U) ? 44U : n));
            // one frame in eight gets a perturbed length
            if ((rnd() % 8U) == 0U)
            {
                len = rnd() % 25U;
            }
        }
        else if (mode == 3U)
        {
            // a structured prefix with a random length
            uint16_t w[1];

            w[0] = 0U;
            (void)mkframe(local, cmdw(FSAC_GW_RT_ADDRESS, rnd() % 2U, rnd() % 4U, rnd() % 9U), w, 0U);
        }

        // exact-size allocation: a read outside the frame is caught by a sanitizer
        heap = (uint8_t *)malloc((len > 0U) ? len : 1U);
        if (heap == NULL)
        {
            CHECK(false);
            return;
        }
        (void)memcpy(heap, local, len);

        snap(&st.counters, before);
        ring_before = st.ring_count;
        (void)memset(&resp, 0x55, sizeof(resp));
        s = fsac_gw_process(&st, heap, len, frame, &resp);
        snap(&st.counters, after);
        free(heap);

        ix = status_index(s);
        if (ix >= NUM_COUNTERS)
        {
            bad_invariant++;     // ERR_NULL or ERR_ARG can never come from valid pointers
            continue;
        }
        tally[ix]++;

        // exactly one counter moved, by one
        for (i = 0U; i < NUM_COUNTERS; i++)
        {
            if (after[i] != (before[i] + ((i == ix) ? 1U : 0U)))
            {
                bad_invariant++;
            }
        }
        // the ring grew only for an accepted receive, and never beyond its depth
        if ((st.ring_count > FSAC_GW_RING_DEPTH)
            || (st.ring_count != (uint8_t)(ring_before + ((s == FSAC_GW_ACCEPTED_RX) ? 1U : 0U))))
        {
            bad_invariant++;
        }
        // the response is empty unless a transmit was accepted, and then it is well formed
        if (s != FSAC_GW_ACCEPTED_TX)
        {
            if (!resp_zero(&resp))
            {
                bad_invariant++;
            }
        }
        else
        {
            uint32_t k;

            if (((resp.word_count != 4U) && (resp.word_count != 6U))
                || (resp.fresh > 1U) || (resp.reserved != 0U))
            {
                bad_invariant++;
            }
            for (k = 0U; k < FSAC_GW_MAX_WORDS; k++)
            {
                if (k >= resp.word_count)
                {
                    if (resp.words[k] != 0U)
                    {
                        bad_invariant++;
                    }
                }
                else if ((resp.fresh == 0U) && (resp.words[k] != FSAC_GW_NO_DATA_WORD))
                {
                    bad_invariant++;
                }
            }
            if (resp.fresh == 1U) { fresh_count++; } else { stale_count++; }
        }
    }

    // drain what is left and check every record
    {
        fsac_gw_record_t rec;

        while (fsac_gw_pop(&st, &rec) == 1U)
        {
            if (!record_valid(&rec) || (rec.seq != expect_seq))
            {
                bad_record++;
            }
            expect_seq++;
        }
    }

    CHECK(bad_invariant == 0U);
    CHECK(bad_record == 0U);
    CHECK(total(&st.counters) == (uint64_t)ITER);       // every call moved exactly one counter
    CHECK(expect_seq == st.seq);                         // no record lost, none invented

    // the campaign must have reached every outcome, otherwise it proves less than it claims
    CHECK(tally[IX_RX] > 0U);
    CHECK(tally[IX_TX] > 0U);
    CHECK(tally[IX_LENGTH] > 0U);
    CHECK(tally[IX_FRAMING] > 0U);
    CHECK(tally[IX_BROADCAST] > 0U);
    CHECK(tally[IX_ADDRESS] > 0U);
    CHECK(tally[IX_NOT_LISTED] > 0U);
    CHECK(tally[IX_RANGE] > 0U);
    CHECK(tally[IX_RATE] > 0U);
    CHECK(tally[IX_OVERRUN] > 0U);
    CHECK(fresh_count > 0U);
    CHECK(stale_count > 0U);

    printf("  fuzz outcomes: rx %u, tx %u, length %u, framing %u, broadcast %u, address %u,\n"
           "                 not_listed %u, range %u, rate %u, overrun %u; tx fresh %u, stale %u\n",
           (unsigned)tally[IX_RX], (unsigned)tally[IX_TX], (unsigned)tally[IX_LENGTH],
           (unsigned)tally[IX_FRAMING], (unsigned)tally[IX_BROADCAST], (unsigned)tally[IX_ADDRESS],
           (unsigned)tally[IX_NOT_LISTED], (unsigned)tally[IX_RANGE], (unsigned)tally[IX_RATE],
           (unsigned)tally[IX_OVERRUN], (unsigned)fresh_count, (unsigned)stale_count);
}


// main
int main(void)
{
    printf("test_gw_1553\n");

    test_init();
    test_accepted_rx();
    test_ranges();
    test_whitelist();
    test_length_sweep();
    test_counters_one_by_one();
    test_rate_and_ring();
    test_transmit();
    test_tx_load_errors();
    test_saturation();
    test_null_args();
    test_ring_wrap();
    test_fuzz();

    printf("\npassed %u, failed %u\n", (unsigned)(g_run - g_failed), (unsigned)g_failed);
    return (g_failed == 0U) ? 0 : 1;
}