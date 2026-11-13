/* ===========================================================================
 * File    : software/platform_bridge/tests/fsac_bridge_test_helpers.c
 * Purpose : C side of the mixed-language test of the Ada/C bridge (host only)
 *
 * The Ada test (test_bridge.adb) calls these functions. They let it ask the
 * C compiler what the layout really is (sizeof, offsetof), fill a sample in
 * C, and run the REAL sensor driver against a fake mailbox, so the sample
 * that reaches Ada was produced by the production code, not by the test.
 * Not flight code: no MISRA claim.
*/

#include <stddef.h>
#include <stdint.h>

#include "fsac_hsi_sensor.h"

static fsac_sensor_cfg_t   g_cfg;
static fsac_sensor_state_t g_state;
static volatile fsac_sensor_raw_t g_mailbox;

uint32_t fsac_test_sizeof_sample(void)
{
    return (uint32_t)sizeof(fsac_sensor_sample_t);
}

uint32_t fsac_test_alignof_sample(void)
{
    return (uint32_t)_Alignof(fsac_sensor_sample_t);
}

// which: 0 value, 1 frame, 2 status, 3 valid, 4 reserved 
uint32_t fsac_test_offset(uint32_t which)
{
    uint32_t off = 0xFFFFFFFFU;

    switch (which)
    {
        case 0U: off = (uint32_t)offsetof(fsac_sensor_sample_t, value);    break;
        case 1U: off = (uint32_t)offsetof(fsac_sensor_sample_t, frame);    break;
        case 2U: off = (uint32_t)offsetof(fsac_sensor_sample_t, status);   break;
        case 3U: off = (uint32_t)offsetof(fsac_sensor_sample_t, valid);    break;
        case 4U: off = (uint32_t)offsetof(fsac_sensor_sample_t, reserved); break;
        default: break;
    }

    return off;
}

void fsac_test_fill(fsac_sensor_sample_t * out, int32_t value, uint32_t frame,
                    uint8_t status, uint8_t valid, uint16_t reserved)
{
    out->value    = value;
    out->frame    = frame;
    out->status   = status;
    out->valid    = valid;
    out->reserved = reserved;
}

// a wide driver configuration: the DRIVER accepts anything inside the full Q16 range, so values above 8 rad/s reach the Ada bridge, which must then reject them 
// (second line of defence)
void fsac_test_reset(void)
{
    g_cfg.offset_counts = 0;
    g_cfg.scale_q16     = FSAC_Q16_ONE;      // value = counts 
    g_cfg.min_valid     = FSAC_Q16_MIN;
    g_cfg.max_valid     = FSAC_Q16_MAX;
    g_cfg.max_step      = FSAC_Q16_MAX;

    (void)fsac_sensor_init(&g_state, &g_cfg);
}

static uint16_t crc_for(uint32_t seq, int32_t counts, uint32_t ts, uint16_t flags)
{
    fsac_sensor_raw_t t;

    t.seq_begin    = seq;
    t.counts       = counts;
    t.timestamp_us = ts;
    t.hw_flags     = flags;
    t.crc16        = 0U;
    t.seq_end      = seq;

    return fsac_sensor_crc16(&t);
}

void fsac_test_pipeline(int32_t counts, uint16_t flags, uint32_t seq,
                        fsac_sensor_sample_t * out)
{
    uint32_t ts = seq * 5000U;

    g_mailbox.seq_begin    = seq;
    g_mailbox.counts       = counts;
    g_mailbox.timestamp_us = ts;
    g_mailbox.hw_flags     = flags;
    g_mailbox.crc16        = crc_for(seq, counts, ts, flags);
    g_mailbox.seq_end      = seq;

    (void)fsac_sensor_read(&g_state, &g_cfg, &g_mailbox, seq, out);
}