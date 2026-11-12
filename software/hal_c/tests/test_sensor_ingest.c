/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/tests/test_sensor_ingest.c
 * Unit        : Test program for fsac_sensor_ingest.c (host only)
 * Language    : C11
 * Purpose     : Requirements-based tests of the sensor driver (DO-178C 6.4)
 * Requirements: HLR-HSI-0001 .. HLR-HSI-0012 (placeholder IDs)
 *
 * THE FAKE FPGA
 *   The real mailbox is written by the I/O FPGA. Here it is a plain
 *   volatile structure in RAM (g_mailbox). The helper publish() writes it
 *   the way the FPGA would (data, then CRC, same sequence number at both
 *   ends). publish_raw() writes arbitrary fields so the tests can inject
 *   torn reads, bad CRCs and so on.
 *
 * INDEPENDENCE OF THE EXPECTED VALUES
 *   - The CRC used by publish() is a TABLE-DRIVEN implementation written
 *     here, different in structure from the bitwise one in the driver.
 *   - The CRC known answers (test CRC-1) come from
 *     reference_crc.py, a Python model written from the header's layout
 *     note. The Python model also reproduces the published check value of
 *     the algorithm (0x29B1 for the ASCII string "123456789").
 *   - Scaling expectations are computed by hand and written next to each
 *     test.
 *
 * TEST GROUPS (map to requirements in traceability/links/)
 *   L  layout shared with Ada          HLR-HSI-0001
 *   I  initialization and config       HLR-HSI-0002
 *   S  scaling (same rule as Mul_Q)    HLR-HSI-0003
 *   C  CRC                             HLR-HSI-0004
 *   R  read: each check and its edges  HLR-HSI-0005 .. 0010
 *   O  order of the checks             HLR-HSI-0005
 *   P  policies P1..P5 of the driver   HLR-HSI-0006 .. 0010
 *   N  NULL arguments and output rule  HLR-HSI-0012
 *
 * HOW TO BUILD AND RUN (from software/hal_c/tests/)
 *   gcc -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Wshadow \
 *       -I../include -o test_sensor_ingest \
 *       test_sensor_ingest.c ../src/sensor_ingest/fsac_sensor_ingest.c
 *   ./test_sensor_ingest
 *
 *   With run-time sanitizers (Linux/macOS; MinGW usually lacks them):
 *   add  -fsanitize=address,undefined -fno-sanitize-recover=all
 *
 *   With coverage (statement and branch):
 *   add  --coverage -O0  to the command, run, then
 *   gcov -b test_sensor_ingest-fsac_sensor_ingest.gcda
 *   Expected: 100% of lines and 100% of branch outcomes (72 of 72).
*/

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "fsac_hsi_sensor.h"


// tiny test harness
static unsigned g_passed = 0U;
static unsigned g_failed = 0U;

static void check(const char * name, int condition)
{
    if (condition != 0)
    {
        g_passed++;
    }
    else
    {
        g_failed++;
        (void)printf("FAIL  %s\n", name);
    }
}

static void check_i64(const char * name, int64_t got, int64_t want)
{
    if (got == want)
    {
        g_passed++;
    }
    else
    {
        g_failed++;
        (void)printf("FAIL  %s: got %lld, expected %lld\n", name,
                     (long long)got, (long long)want);
    }
}


// fake FPGA
static volatile fsac_sensor_raw_t g_mailbox;

static uint16_t g_crc_table[256];

static void crc_table_init(void)
{
    uint32_t i;
    uint32_t b;
    uint32_t c;

    for (i = 0U; i < 256U; i++)
    {
        c = i << 8U;
        for (b = 0U; b < 8U; b++)
        {
            if ((c & 0x8000U) != 0U)
            {
                c = ((c << 1U) ^ 0x1021U) & 0xFFFFU;
            }
            else
            {
                c = (c << 1U) & 0xFFFFU;
            }
        }
        g_crc_table[i] = (uint16_t)c;
    }
}

// table-driven CRC-16/CCITT-FALSE over seq, counts, timestamp, flags (LE)
static uint16_t ref_crc(uint32_t seq, int32_t counts, uint32_t ts, uint16_t flags)
{
    uint8_t  bytes[14];
    uint32_t c = (uint32_t)counts;
    uint16_t crc = 0xFFFFU;
    size_t   i;

    bytes[0]  = (uint8_t)(seq & 0xFFU);
    bytes[1]  = (uint8_t)((seq >> 8U) & 0xFFU);
    bytes[2]  = (uint8_t)((seq >> 16U) & 0xFFU);
    bytes[3]  = (uint8_t)((seq >> 24U) & 0xFFU);
    bytes[4]  = (uint8_t)(c & 0xFFU);
    bytes[5]  = (uint8_t)((c >> 8U) & 0xFFU);
    bytes[6]  = (uint8_t)((c >> 16U) & 0xFFU);
    bytes[7]  = (uint8_t)((c >> 24U) & 0xFFU);
    bytes[8]  = (uint8_t)(ts & 0xFFU);
    bytes[9]  = (uint8_t)((ts >> 8U) & 0xFFU);
    bytes[10] = (uint8_t)((ts >> 16U) & 0xFFU);
    bytes[11] = (uint8_t)((ts >> 24U) & 0xFFU);
    bytes[12] = (uint8_t)(flags & 0xFFU);
    bytes[13] = (uint8_t)((flags >> 8U) & 0xFFU);

    for (i = 0U; i < sizeof(bytes); i++)
    {
        crc = (uint16_t)((uint32_t)(crc << 8U) ^ g_crc_table[((uint32_t)(crc >> 8U) ^ bytes[i]) & 0xFFU]);
    }

    return crc;
}

// arbitrary fields, written in the FPGA's order (begin first, end last)
static void publish_raw(uint32_t seq_begin, int32_t counts, uint32_t ts,
                        uint16_t flags, uint16_t crc, uint32_t seq_end)
{
    g_mailbox.seq_begin    = seq_begin;
    g_mailbox.counts       = counts;
    g_mailbox.timestamp_us = ts;
    g_mailbox.hw_flags     = flags;
    g_mailbox.crc16        = crc;
    g_mailbox.seq_end      = seq_end;
}

// a healthy FPGA write
static void publish(uint32_t seq, int32_t counts, uint16_t flags)
{
    uint32_t ts = seq * 5000U;
    publish_raw(seq, counts, ts, flags, ref_crc(seq, counts, ts, flags), seq);
}

/*
 * configurations used by the tests
 *   CFG_A: unit scale; value raw = counts - 100, easy to check by hand
 *   CFG_B: half scale; value raw = (counts * 0.5) truncated toward zero
*/
static const fsac_sensor_cfg_t CFG_A =
{
    100, INT32_C(65536), -INT32_C(524288), INT32_C(524288), INT32_C(10000)
};

static const fsac_sensor_cfg_t CFG_B =
{
    0, INT32_C(32768), -INT32_C(524288), INT32_C(524288), INT32_C(10000)
};

static fsac_sensor_status_t rd(fsac_sensor_state_t * s, const fsac_sensor_cfg_t * c,
                               uint32_t frame, fsac_sensor_sample_t * o)
{
    return fsac_sensor_read(s, c, &g_mailbox, frame, o);
}

static void fresh(fsac_sensor_state_t * s, const fsac_sensor_cfg_t * c)
{
    check("setup: init OK", fsac_sensor_init(s, c) == FSAC_SENSOR_OK);
}

// checks status, valid flag, value rule R7, reserved field, in one line
static void expect(const char * name, fsac_sensor_status_t got,
                   fsac_sensor_status_t want, const fsac_sensor_sample_t * o,
                   fsac_q16_t want_value)
{
    int ok = (got == want)
          && (o->status == want)
          && (o->valid == ((want == FSAC_SENSOR_OK) ? 1U : 0U))
          && (o->value == ((want == FSAC_SENSOR_OK) ? want_value : 0))
          && (o->reserved == 0U);

    if (ok == 0)
    {
        (void)printf("      detail: got status %u, out.status %u, valid %u, value %d\n",
                     (unsigned)got, (unsigned)o->status, (unsigned)o->valid,
                     (int)o->value);
    }
    check(name, ok);
}


// L: layout shared with the Ada side (Fsac.Platform_Ports)
static void test_layout(void)
{
    check_i64("L-01 raw size", (int64_t)sizeof(fsac_sensor_raw_t), 20);
    check_i64("L-02 offset seq_begin", (int64_t)offsetof(fsac_sensor_raw_t, seq_begin), 0);
    check_i64("L-03 offset counts", (int64_t)offsetof(fsac_sensor_raw_t, counts), 4);
    check_i64("L-04 offset timestamp", (int64_t)offsetof(fsac_sensor_raw_t, timestamp_us), 8);
    check_i64("L-05 offset hw_flags", (int64_t)offsetof(fsac_sensor_raw_t, hw_flags), 12);
    check_i64("L-06 offset crc16", (int64_t)offsetof(fsac_sensor_raw_t, crc16), 14);
    check_i64("L-07 offset seq_end", (int64_t)offsetof(fsac_sensor_raw_t, seq_end), 16);

    check_i64("L-08 sample size", (int64_t)sizeof(fsac_sensor_sample_t), 12);
    check_i64("L-09 offset value", (int64_t)offsetof(fsac_sensor_sample_t, value), 0);
    check_i64("L-10 offset frame", (int64_t)offsetof(fsac_sensor_sample_t, frame), 4);
    check_i64("L-11 offset status", (int64_t)offsetof(fsac_sensor_sample_t, status), 8);
    check_i64("L-12 offset valid", (int64_t)offsetof(fsac_sensor_sample_t, valid), 9);
    check_i64("L-13 offset reserved", (int64_t)offsetof(fsac_sensor_sample_t, reserved), 10);

    check_i64("L-14 total sensors", (int64_t)FSAC_TOTAL_SENSORS, 18);
    check_i64("L-15 defined flag bits", (int64_t)FSAC_HWFLAG_DEFINED_MASK, 0x000F);
    check_i64("L-16 fault mask is every bit", (int64_t)FSAC_HWFLAG_ANY_FAULT, 0xFFFF);
}

 // I: initialization and configuration check
static void test_init(void)
{
    fsac_sensor_state_t s;
    fsac_sensor_cfg_t   bad;

    s.last_value = 77; s.last_seq = 77U; s.invalid_run = 77U;
    s.fault_total = 77U; s.has_last = 1U; s.has_seq = 1U; s.reserved = 7U;

    check("I-01 NULL state", fsac_sensor_init(NULL, &CFG_A) == FSAC_SENSOR_ERR_NULL);

    check("I-02 NULL cfg", fsac_sensor_init(&s, NULL) == FSAC_SENSOR_ERR_NULL);
    check("I-03 NULL cfg still clears the state",
          (s.last_value == 0) && (s.last_seq == 0U) && (s.invalid_run == 0U)
          && (s.fault_total == 0U) && (s.has_last == 0U) && (s.has_seq == 0U)
          && (s.reserved == 0U));

    check("I-04 good cfg", fsac_sensor_init(&s, &CFG_A) == FSAC_SENSOR_OK);

    bad = CFG_A; bad.scale_q16 = 0;
    check("I-05 scale zero", fsac_sensor_init(&s, &bad) == FSAC_SENSOR_ERR_CONFIG);
    bad = CFG_A; bad.scale_q16 = -1;
    check("I-06 scale negative", fsac_sensor_init(&s, &bad) == FSAC_SENSOR_ERR_CONFIG);
    bad = CFG_A; bad.min_valid = bad.max_valid;
    check("I-07 min equals max", fsac_sensor_init(&s, &bad) == FSAC_SENSOR_ERR_CONFIG);
    bad = CFG_A; bad.min_valid = 1000; bad.max_valid = 0;
    check("I-08 min above max", fsac_sensor_init(&s, &bad) == FSAC_SENSOR_ERR_CONFIG);
    bad = CFG_A; bad.min_valid = INT32_MIN;
    check("I-09 min outside the symmetric range", fsac_sensor_init(&s, &bad) == FSAC_SENSOR_ERR_CONFIG);
    bad = CFG_A; bad.max_step = 0;
    check("I-10 max_step zero", fsac_sensor_init(&s, &bad) == FSAC_SENSOR_ERR_CONFIG);
    bad = CFG_A; bad.max_step = -5;
    check("I-11 max_step negative", fsac_sensor_init(&s, &bad) == FSAC_SENSOR_ERR_CONFIG);

    bad = CFG_A; bad.min_valid = FSAC_Q16_MIN; bad.max_valid = FSAC_Q16_MAX;
    check("I-12 widest legal range", fsac_sensor_init(&s, &bad) == FSAC_SENSOR_OK);
}


// S: scaling
static void test_scale(void)
{
    fsac_sensor_cfg_t huge_up   = { INT32_MIN, INT32_MAX, -INT32_C(524288), INT32_C(524288), 1 };
    fsac_sensor_cfg_t huge_down = { INT32_MAX, INT32_MAX, -INT32_C(524288), INT32_C(524288), 1 };

    // CFG_A: raw = (counts - 100) * 65536 / 65536 = counts - 100 
    check_i64("S-01 zero at the offset", fsac_sensor_scale(100, &CFG_A), 0);
    check_i64("S-02 positive", fsac_sensor_scale(1100, &CFG_A), 1000);
    check_i64("S-03 negative", fsac_sensor_scale(-900, &CFG_A), -1000);

    // CFG_B: raw = counts * 32768 / 65536 = counts / 2, toward zero 
    check_i64("S-04 half scale, even", fsac_sensor_scale(10, &CFG_B), 5);
    check_i64("S-05 truncation toward zero, positive", fsac_sensor_scale(3, &CFG_B), 1);
    check_i64("S-06 truncation toward zero, negative", fsac_sensor_scale(-3, &CFG_B), -1);
    check_i64("S-07 tiny positive becomes zero", fsac_sensor_scale(1, &CFG_B), 0);
    check_i64("S-08 tiny negative becomes zero", fsac_sensor_scale(-1, &CFG_B), 0);

    // Extremes: |diff| = 2^32 - 1, scale = 2^31 - 1, far outside the Q16 range 
    check_i64("S-09 saturates up", fsac_sensor_scale(INT32_MAX, &huge_up), (int64_t)FSAC_Q16_MAX);
    check_i64("S-10 saturates down", fsac_sensor_scale(INT32_MIN, &huge_down), (int64_t)FSAC_Q16_MIN);
    check_i64("S-11 NULL cfg gives 0", fsac_sensor_scale(12345, NULL), 0);
}


// C: CRC
static void test_crc(void)
{
    fsac_sensor_raw_t m;
    uint16_t base;
    uint32_t bit;
    int all_flips_detected = 1;

    // known answers from reference_crc.py (independent Python model) 
    m.seq_begin = 1U;          m.counts = 0;       m.timestamp_us = 0U;
    m.hw_flags = 0U;
    check_i64("CRC-1a vector V1", fsac_sensor_crc16(&m), 0xD20B);

    m.seq_begin = 0x102U;      m.counts = 100000;  m.timestamp_us = 123456U;
    m.hw_flags = 0U;
    check_i64("CRC-1b vector V2", fsac_sensor_crc16(&m), 0x0630);

    m.seq_begin = 0xFFFFFFFFU; m.counts = -1;      m.timestamp_us = 0xFFFFFFFFU;
    m.hw_flags = 0x000FU;
    check_i64("CRC-1c vector V3", fsac_sensor_crc16(&m), 0xCE10);

    m.seq_begin = 7U;          m.counts = -32768;  m.timestamp_us = 1000U;
    m.hw_flags = 0x0001U;
    check_i64("CRC-1d vector V4", fsac_sensor_crc16(&m), 0x0C79);

    // the test's own table-driven CRC must agree with the same vectors 
    check_i64("CRC-2a table CRC V1", ref_crc(1U, 0, 0U, 0U), 0xD20B);
    check_i64("CRC-2b table CRC V2", ref_crc(0x102U, 100000, 123456U, 0U), 0x0630);
    check_i64("CRC-2c table CRC V3", ref_crc(0xFFFFFFFFU, -1, 0xFFFFFFFFU, 0x000FU), 0xCE10);
    check_i64("CRC-2d table CRC V4", ref_crc(7U, -32768, 1000U, 0x0001U), 0x0C79);

    check_i64("CRC-3 NULL snapshot", fsac_sensor_crc16(NULL), 0);

    // every single-bit change in the covered fields must change the CRC 
    m.seq_begin = 0x102U; m.counts = 100000; m.timestamp_us = 123456U; m.hw_flags = 0U;
    base = fsac_sensor_crc16(&m);

    for (bit = 0U; bit < 32U; bit++)
    {
        fsac_sensor_raw_t t = m;
        t.seq_begin ^= ((uint32_t)1U << bit);
        if (fsac_sensor_crc16(&t) == base) { all_flips_detected = 0; }

        t = m;
        t.counts = (int32_t)((uint32_t)t.counts ^ ((uint32_t)1U << bit));
        if (fsac_sensor_crc16(&t) == base) { all_flips_detected = 0; }

        t = m;
        t.timestamp_us ^= ((uint32_t)1U << bit);
        if (fsac_sensor_crc16(&t) == base) { all_flips_detected = 0; }
    }
    for (bit = 0U; bit < 16U; bit++)
    {
        fsac_sensor_raw_t t = m;
        t.hw_flags = (uint16_t)(t.hw_flags ^ (uint16_t)((uint32_t)1U << bit));
        if (fsac_sensor_crc16(&t) == base) { all_flips_detected = 0; }
    }
    check("CRC-4 all 112 single-bit flips are detected", all_flips_detected);

    // the CRC field itself and seq_end are NOT covered 
    {
        fsac_sensor_raw_t t = m;
        t.crc16 = 0x1234U;
        t.seq_end = 99U;
        check("CRC-5 crc16 and seq_end are not part of the CRC", fsac_sensor_crc16(&t) == base);
    }
}

// R: read, one group per check and its boundaries (CFG_A: value = counts-100)
static void test_read_nominal(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;
    fsac_sensor_status_t st;

    fresh(&s, &CFG_A);
    publish(1U, 1100, 0U);
    st = rd(&s, &CFG_A, 42U, &o);

    expect("R-01 nominal sample", st, FSAC_SENSOR_OK, &o, 1000);
    check_i64("R-02 frame recorded", o.frame, 42);
    check_i64("R-03 state last_value", s.last_value, 1000);
    check_i64("R-04 state last_seq", s.last_seq, 1);
    check("R-05 state flags", (s.has_last == 1U) && (s.has_seq == 1U));
    check_i64("R-06 invalid_run zero", s.invalid_run, 0);
}

static void test_read_torn_and_crc(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;

    fresh(&s, &CFG_A);
    publish_raw(5U, 1100, 25000U, 0U, ref_crc(5U, 1100, 25000U, 0U), 6U);
    expect("R-10 torn read", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_TORN, &o, 0);

    fresh(&s, &CFG_A);
    publish(1U, 1100, 0U);
    g_mailbox.counts = 1101;   // data changed after the CRC was written 
    expect("R-11 CRC mismatch", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_CRC, &o, 0);
}

static void test_read_hw_flags(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;
    static const uint16_t faults[5] = { 0x0001U, 0x0002U, 0x0004U, 0x0008U, 0x000FU };
    unsigned i;

    for (i = 0U; i < 5U; i++)
    {
        fresh(&s, &CFG_A);
        publish(1U, 1100, faults[i]);
        expect("R-20 hardware fault flag", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_HW, &o, 0);
    }

    /* Fail closed (ADR-007): ANY set bit is a fault, defined or not. */
    fresh(&s, &CFG_A);
    publish(1U, 1100, 0x0010U);
    expect("R-21 unknown flag bit 4 is a fault", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_HW, &o, 0);

    fresh(&s, &CFG_A);
    publish(1U, 1100, 0x8000U);
    expect("R-22 unknown flag bit 15 is a fault", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_HW, &o, 0);

    fresh(&s, &CFG_A);
    publish(1U, 1100, 0xFFFFU);
    expect("R-23 all flag bits set is a fault", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_HW, &o, 0);

    fresh(&s, &CFG_A);
    publish(1U, 1100, 0x0000U);
    expect("R-24 no flag set is accepted", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_OK, &o, 1000);
}

static void test_read_sequence(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;

    // stale: the same sequence number twice 
    fresh(&s, &CFG_A);
    publish(1U, 1100, 0U);
    (void)rd(&s, &CFG_A, 1U, &o);
    expect("R-30 stale sample", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_ERR_STALE, &o, 0);
    check_i64("R-31 stale counts as an invalid frame", s.invalid_run, 1);

    // jump boundary: delta 4 passes, delta 5 is rejected 
    fresh(&s, &CFG_A);
    publish(10U, 100, 0U); (void)rd(&s, &CFG_A, 1U, &o);
    publish(14U, 100, 0U);
    expect("R-32 jump of exactly 4 is accepted", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_OK, &o, 0);
    publish(19U, 100, 0U);
    expect("R-33 jump of 5 is rejected", rd(&s, &CFG_A, 3U, &o), FSAC_SENSOR_ERR_SEQ, &o, 0);
    publish(20U, 100, 0U);
    expect("R-34 next sample after a jump rejoins (resync)", rd(&s, &CFG_A, 4U, &o), FSAC_SENSOR_OK, &o, 0);

    // wrap-around of the 32-bit sequence number 
    fresh(&s, &CFG_A);
    publish(0xFFFFFFFEU, 100, 0U); (void)rd(&s, &CFG_A, 1U, &o);
    publish(1U, 100, 0U);
    expect("R-35 sequence wraps 0xFFFFFFFE -> 1 (delta 3)", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_OK, &o, 0);

    // a sequence number that goes backwards is a large forward jump 
    fresh(&s, &CFG_A);
    publish(100U, 100, 0U); (void)rd(&s, &CFG_A, 1U, &o);
    publish(99U, 100, 0U);
    expect("R-36 backwards sequence is rejected", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_ERR_SEQ, &o, 0);
}

static void test_read_range(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;

    fresh(&s, &CFG_A);
    publish(1U, 524388, 0U);   // value 524288 = max 
    expect("R-40 exactly at the maximum", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_OK, &o, 524288);

    fresh(&s, &CFG_A);
    publish(1U, 524389, 0U);   // value 524289 
    expect("R-41 one above the maximum", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_RANGE, &o, 0);

    fresh(&s, &CFG_A);
    publish(1U, -524188, 0U);  // value -524288 = min 
    expect("R-42 exactly at the minimum", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_OK, &o, -524288);

    fresh(&s, &CFG_A);
    publish(1U, -524189, 0U);  // value -524289 
    expect("R-43 one below the minimum", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_RANGE, &o, 0);

    fresh(&s, &CFG_A);
    publish(1U, INT32_MAX, 0U);
    expect("R-44 saturated value is out of range", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_RANGE, &o, 0);
}

static void test_read_step(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;

    fresh(&s, &CFG_A);
    publish(1U, 100, 0U);      // value 0 
    (void)rd(&s, &CFG_A, 1U, &o);

    publish(2U, 10100, 0U);    // value 10000, change exactly max_step 
    expect("R-50 change of exactly max_step is accepted", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_OK, &o, 10000);

    publish(3U, 20101, 0U);    // value 20001, change 10001 
    expect("R-51 change of max_step + 1 is rejected", rd(&s, &CFG_A, 3U, &o), FSAC_SENSOR_ERR_STEP, &o, 0);
    check_i64("R-52 baseline is the last VALID value", s.last_value, 10000);

    publish(4U, 20100, 0U);    /* value 20000, change 10000 from the baseline */
    expect("R-53 next sample compared with the last valid one", rd(&s, &CFG_A, 4U, &o), FSAC_SENSOR_OK, &o, 20000);

    publish(5U, 10100, 0U);    // value 10000, change -10000: negative direction 
    expect("R-54 negative change of exactly max_step", rd(&s, &CFG_A, 5U, &o), FSAC_SENSOR_OK, &o, 10000);

    publish(6U, 99, 0U);       // value -1, change -10001 
    expect("R-55 negative change of max_step + 1", rd(&s, &CFG_A, 6U, &o), FSAC_SENSOR_ERR_STEP, &o, 0);
}


// O: the order of the checks (first failure wins)
static void test_order(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;
    fsac_sensor_cfg_t    badcfg = CFG_A;

    // 1 config before everything 
    badcfg.scale_q16 = 0;
    fresh(&s, &CFG_A);
    publish(1U, 1100, 0U);
    expect("O-01 config error comes first", rd(&s, &badcfg, 1U, &o), FSAC_SENSOR_ERR_CONFIG, &o, 0);

    // 2 torn before CRC 
    fresh(&s, &CFG_A);
    publish_raw(5U, 1100, 0U, 0U, 0xABCDU, 6U);        // torn AND wrong CRC 
    expect("O-02 torn before CRC", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_TORN, &o, 0);

    // 3 CRC before hardware flags 
    fresh(&s, &CFG_A);
    publish_raw(5U, 1100, 0U, 0x0001U, ref_crc(5U, 1100, 0U, 0U), 5U);  // CRC of flags=0 
    expect("O-03 CRC before hardware flags", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_ERR_CRC, &o, 0);

    // 4 hardware flags before stale 
    fresh(&s, &CFG_A);
    publish(5U, 100, 0U); (void)rd(&s, &CFG_A, 1U, &o);
    publish(5U, 100, 0x0001U);                           // same seq AND fault 
    expect("O-04 hardware fault before stale", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_ERR_HW, &o, 0);

    // 5 stale before range 
    fresh(&s, &CFG_A);
    publish(5U, 100, 0U); (void)rd(&s, &CFG_A, 1U, &o);
    publish(5U, 900000, 0U);                             // same seq AND out of range 
    expect("O-05 stale before range", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_ERR_STALE, &o, 0);

    // 6 sequence jump before range 
    fresh(&s, &CFG_A);
    publish(5U, 100, 0U); (void)rd(&s, &CFG_A, 1U, &o);
    publish(50U, 900000, 0U);                            // big jump AND out of range 
    expect("O-06 sequence jump before range", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_ERR_SEQ, &o, 0);

    // 7 range before step 
    fresh(&s, &CFG_A);
    publish(5U, 100, 0U); (void)rd(&s, &CFG_A, 1U, &o);
    publish(6U, 900000, 0U);                             // out of range AND big step 
    expect("O-07 range before step", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_ERR_RANGE, &o, 0);
}


// P: policies P1 .. P5
static void test_policies(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;
    unsigned i;

    // P1: a fresh, intact snapshot moves the sequence baseline even when it is rejected later (here: hardware flag)
    fresh(&s, &CFG_A);
    publish(1U, 100, 0U);      (void)rd(&s, &CFG_A, 1U, &o);
    publish(2U, 100, 0x0001U);
    expect("P1-01 rejected by hardware flag", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_ERR_HW, &o, 0);
    check_i64("P1-02 baseline moved to 2", s.last_seq, 2);
    publish(2U, 100, 0U);
    expect("P1-03 same sequence again is stale", rd(&s, &CFG_A, 3U, &o), FSAC_SENSOR_ERR_STALE, &o, 0);
    publish(3U, 100, 0U);
    expect("P1-04 next sequence is accepted", rd(&s, &CFG_A, 4U, &o), FSAC_SENSOR_OK, &o, 0);

    // a torn or corrupt snapshot must NOT move the baseline
    fresh(&s, &CFG_A);
    publish(1U, 100, 0U);      (void)rd(&s, &CFG_A, 1U, &o);
    publish_raw(2U, 100, 0U, 0U, 0U, 3U);               // torn 
    (void)rd(&s, &CFG_A, 2U, &o);
    check_i64("P1-05 torn snapshot leaves the baseline", s.last_seq, 1);

    // P3: re-arm of the step check after FSAC_SENSOR_REARM_FRAMES invalid frames 
    fresh(&s, &CFG_A);
    publish(1U, 100, 0U);      (void)rd(&s, &CFG_A, 1U, &o);          // value 0 
    for (i = 2U; i <= 8U; i++)                                        // 7 invalid frames 
    {
        publish(i, 100, 0x0001U);
        (void)rd(&s, &CFG_A, i, &o);
    }
    check_i64("P3-01 seven invalid frames", s.invalid_run, 7);
    publish(9U, 50100, 0U);                                           // value 50000 
    expect("P3-02 step still checked at 7 invalid frames", rd(&s, &CFG_A, 9U, &o), FSAC_SENSOR_ERR_STEP, &o, 0);
    check_i64("P3-03 now eight invalid frames", s.invalid_run, 8);
    publish(10U, 50100, 0U);
    expect("P3-04 step check dropped at 8 invalid frames", rd(&s, &CFG_A, 10U, &o), FSAC_SENSOR_OK, &o, 50000);
    check_i64("P3-05 invalid_run cleared", s.invalid_run, 0);
    publish(11U, 70100, 0U);                                          // value 70000, +20000 
    expect("P3-06 step check active again", rd(&s, &CFG_A, 11U, &o), FSAC_SENSOR_ERR_STEP, &o, 0);

    // P3b: the range check is never dropped by the re-arm 
    fresh(&s, &CFG_A);
    publish(1U, 100, 0U);      (void)rd(&s, &CFG_A, 1U, &o);
    s.invalid_run = 20U;
    publish(2U, 900000, 0U);
    expect("P3-07 range is checked even when re-armed", rd(&s, &CFG_A, 2U, &o), FSAC_SENSOR_ERR_RANGE, &o, 0);

    // P3c: the first ever sample has no baseline, so no step check 
    fresh(&s, &CFG_A);
    publish(1U, 400100, 0U);
    expect("P3-08 first sample has no step check", rd(&s, &CFG_A, 1U, &o), FSAC_SENSOR_OK, &o, 400000);

    // P5: counters saturate and never wrap 
    fresh(&s, &CFG_A);
    s.invalid_run = UINT32_MAX - 1U;
    s.fault_total = UINT32_MAX - 1U;
    publish(1U, 100, 0x0001U); (void)rd(&s, &CFG_A, 1U, &o);
    check_i64("P5-01 invalid_run reaches the maximum", s.invalid_run, (int64_t)UINT32_MAX);
    publish(2U, 100, 0x0001U); (void)rd(&s, &CFG_A, 2U, &o);
    check_i64("P5-02 invalid_run does not wrap", s.invalid_run, (int64_t)UINT32_MAX);
    check_i64("P5-03 fault_total does not wrap", s.fault_total, (int64_t)UINT32_MAX);
    publish(3U, 100, 0U);
    expect("P5-04 a valid sample is still accepted", rd(&s, &CFG_A, 3U, &o), FSAC_SENSOR_OK, &o, 0);
    check_i64("P5-05 valid sample clears invalid_run", s.invalid_run, 0);
    check_i64("P5-06 fault_total is kept", s.fault_total, (int64_t)UINT32_MAX);
}


// N: NULL arguments and the output rule (R7, P4)
static void test_null_and_output(void)
{
    fsac_sensor_state_t  s;
    fsac_sensor_sample_t o;

    fresh(&s, &CFG_A);
    publish(1U, 1100, 0U);

    check("N-01 NULL out returns the NULL code",
          fsac_sensor_read(&s, &CFG_A, &g_mailbox, 1U, NULL) == FSAC_SENSOR_ERR_NULL);

    o.value = 123; o.frame = 0U; o.status = 77U; o.valid = 1U; o.reserved = 9U;
    expect("N-02 NULL state", fsac_sensor_read(NULL, &CFG_A, &g_mailbox, 5U, &o),
           FSAC_SENSOR_ERR_NULL, &o, 0);
    check_i64("N-03 frame is recorded on a NULL error", o.frame, 5);

    o.value = 123; o.status = 77U; o.valid = 1U; o.reserved = 9U;
    expect("N-04 NULL cfg", fsac_sensor_read(&s, NULL, &g_mailbox, 6U, &o),
           FSAC_SENSOR_ERR_NULL, &o, 0);

    o.value = 123; o.status = 77U; o.valid = 1U; o.reserved = 9U;
    expect("N-05 NULL mailbox", fsac_sensor_read(&s, &CFG_A, NULL, 7U, &o),
           FSAC_SENSOR_ERR_NULL, &o, 0);
    check_i64("N-06 NULL arguments do not touch the state", s.invalid_run, 0);

    // the output is overwritten on every call, also after an old good value 
    o.value = 555; o.status = FSAC_SENSOR_OK; o.valid = 1U; o.reserved = 0U;
    publish_raw(9U, 1100, 0U, 0U, 0U, 10U);            // torn 
    expect("N-07 stale output is overwritten by an error", rd(&s, &CFG_A, 8U, &o),
           FSAC_SENSOR_ERR_TORN, &o, 0);
}


// main
int main(void)
{
    crc_table_init();

    (void)printf("FSAC sensor ingest tests\n");

    test_layout();
    test_init();
    test_scale();
    test_crc();
    test_read_nominal();
    test_read_torn_and_crc();
    test_read_hw_flags();
    test_read_sequence();
    test_read_range();
    test_read_step();
    test_order();
    test_policies();
    test_null_and_output();

    (void)printf("\npassed: %u\nfailed: %u\n", g_passed, g_failed);

    return (g_failed == 0U) ? 0 : 1;
}