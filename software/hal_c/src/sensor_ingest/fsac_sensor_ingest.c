/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/src/sensor_ingest/fsac_sensor_ingest.c
 * Module      : Sensor acquisition driver, implementation
 * Language    : C11, written to MISRA C:2012 (Amendment 2/3)
 * Assurance   : DO-178C Software Level A (target)
 * Partition   : P1 SENSOR_INGEST
 * Requirements: HLR-HSI-0001 .. HLR-HSI-0012 (placeholder IDs)
 * Interface   : include/fsac_hsi_sensor.h (read it first)
 *
 * WHAT THIS FILE DOES
 *   Implements the four functions of the header. The important one is
 *   fsac_sensor_read, which turns a raw FPGA mailbox into a checked sample
 *   following the eight-step order of the header.
 *
 * STRUCTURE
 *   Pure helpers      crc16_byte, crc16_u32_le, crc16_u16_le, config_ok,
 *                     step_exceeded, sat_inc
 *   evaluate()        runs the checks. Reads the state, NEVER changes it.
 *   update_state()    the only place that changes the state, so the
 *                     bookkeeping rules are in one readable block.
 *   fsac_sensor_read  copy the mailbox, evaluate, update, publish.
 *
 * POLICIES THAT ARE EASY TO MISS
 *   P1 Sequence bookkeeping. A snapshot that is intact (not torn, CRC good)
 *      and carries a NEW sequence number moves the sequence baseline, even
 *      if it is rejected later (hardware flag, range, step). Reason: after
 *      a fault clears, the next sample must not be rejected a second time
 *      just because the baseline went stale.
 *   P2 A sequence jump (more than FSAC_SENSOR_MAX_SEQ_JUMP) rejects that one
 *      sample and resynchronizes the baseline, so the sensor can rejoin on
 *      the next frame instead of being locked out.
 *   P3 Re-arm. The step check compares with the last VALID value. If a
 *      sensor has been invalid for FSAC_SENSOR_REARM_FRAMES frames in a row,
 *      the step check is skipped, so a sensor that really moved (or a first
 *      good reading after a long outage) can rejoin. The range check is never
 *      skipped.
 *   P4 Single publish point. The output sample is written exactly once at
 *      the end, with value 0 whenever the status is not OK (rule R7).
 *   P5 Counters saturate. They never wrap, because a wrapped counter looks
 *      like a healthy sensor.
 *
 * MISRA C:2012 STYLE USED HERE
 *   - One return per function (Rule 15.5, advisory).
 *   - No recursion, no dynamic memory, no library calls other than what the
 *     header and stdint/stdbool/stddef provide.
 *   - Every loop has a constant bound (the CRC loops: 8 bits, 14 bytes).
 *   - Explicit casts at every narrowing or sign change (Rules 10.3, 10.8).
 *   - The volatile mailbox is read field by field into a local copy. memcpy
 *     is not used because it discards volatile (Rule 1.3 / undefined
 *     behaviour risk).
 *   - No deviations.
 *
 * ABOUT MEMORY ORDER ON THE TARGET
 *   The fields are read in the same order the FPGA writes them (seq_begin
 *   first, seq_end last), and volatile accesses are not reordered by the
 *   compiler. On the real target the BSP must also map the mailbox as
 *   device or non-cacheable memory so the processor cannot reorder or cache
 *   the reads. That is a BSP requirement (HLR-HSI-0011), outside this file.
 *
 * SELF-CHECK COMMAND (from software/hal_c/src/sensor_ingest/)
 *   gcc -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Wshadow \
 *       -Wstrict-prototypes -Wcast-qual -I../../include \
 *       -fsyntax-only fsac_sensor_ingest.c
*/

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "fsac_hsi_sensor.h"

// Compile-time check for the scaling arithmetic; (counts - offset) is at most 2^32 - 1 in magnitude and scale is at most 2^31 - 1, so the product must fit in int64_t
FSAC_STATIC_ASSERT(((int64_t)UINT32_MAX * (int64_t)INT32_MAX) <= INT64_MAX,
                   "scaling product must fit in 64 bits");

// CRC-16/CCITT-FALSE helpers; polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR, most significant bit first
#define CRC16_INIT  ((uint16_t)0xFFFFU)
#define CRC16_POLY  (0x1021U)

static uint16_t crc16_byte(uint16_t crc, uint8_t byte)
{
    uint16_t c = (uint16_t)(crc ^ (uint16_t)((uint32_t)byte << 8U));
    uint32_t bit;

    for (bit = 0U; bit < 8U; bit++)
    {
        if ((c & 0x8000U) != 0U)
        {
            c = (uint16_t)(((uint32_t)c << 1U) ^ CRC16_POLY);
        }
        else
        {
            c = (uint16_t)((uint32_t)c << 1U);
        }
    }

    return c;
}

// four bytes, least significant first (the mailbox is little endian)
static uint16_t crc16_u32_le(uint16_t crc, uint32_t value)
{
    uint16_t c = crc;

    c = crc16_byte(c, (uint8_t)(value & 0xFFU));
    c = crc16_byte(c, (uint8_t)((value >> 8U) & 0xFFU));
    c = crc16_byte(c, (uint8_t)((value >> 16U) & 0xFFU));
    c = crc16_byte(c, (uint8_t)((value >> 24U) & 0xFFU));

    return c;
}

// two bytes, least significant first
static uint16_t crc16_u16_le(uint16_t crc, uint16_t value)
{
    uint16_t c = crc;

    c = crc16_byte(c, (uint8_t)((uint32_t)value & 0xFFU));
    c = crc16_byte(c, (uint8_t)(((uint32_t)value >> 8U) & 0xFFU));

    return c;
}

uint16_t fsac_sensor_crc16(const fsac_sensor_raw_t * snapshot)
{
    uint16_t crc = 0U;

    if (snapshot != NULL)
    {
        crc = CRC16_INIT;
        crc = crc16_u32_le(crc, snapshot->seq_begin);
        crc = crc16_u32_le(crc, (uint32_t)snapshot->counts);
        crc = crc16_u32_le(crc, snapshot->timestamp_us);
        crc = crc16_u16_le(crc, snapshot->hw_flags);
    }

    return crc;
}

// scaling: same rule as Fsac.Fixed_Math.Mul_Q; product in 64 bits, divide by 65536 truncating toward zero (C99 and later define integer division this way), saturate to the 
// symmetric Q16 range
fsac_q16_t fsac_sensor_scale(int32_t counts, const fsac_sensor_cfg_t * cfg)
{
    fsac_q16_t result = 0;
    int64_t    diff;
    int64_t    scaled;

    if (cfg != NULL)
    {
        diff   = (int64_t)counts - (int64_t)cfg->offset_counts;
        scaled = (diff * (int64_t)cfg->scale_q16) / (int64_t)FSAC_Q16_ONE;

        if (scaled > (int64_t)FSAC_Q16_MAX)
        {
            result = FSAC_Q16_MAX;
        }
        else if (scaled < (int64_t)FSAC_Q16_MIN)
        {
            result = FSAC_Q16_MIN;
        }
        else
        {
            result = (fsac_q16_t)scaled;
        }
    }

    return result;
}


// small helpers
/* Precondition: cfg is not NULL. Both callers check that first, at the public
   boundary (fsac_sensor_init, fsac_sensor_read), so it is not checked twice
   (ADR-008). */
static bool config_ok(const fsac_sensor_cfg_t * cfg)
{
    return (cfg->scale_q16 > 0)
        && (cfg->min_valid >= FSAC_Q16_MIN)
        && (cfg->max_valid <= FSAC_Q16_MAX)
        && (cfg->min_valid < cfg->max_valid)
        && (cfg->max_step > 0);
}

static uint32_t sat_inc(uint32_t value)
{
    uint32_t result = value;

    if (result < UINT32_MAX)
    {
        result++;
    }

    return result;
}

static bool step_exceeded(const fsac_sensor_state_t * state,
                          fsac_q16_t                  value,
                          const fsac_sensor_cfg_t *   cfg)
{
    bool    exceeded = false;
    int64_t diff;

    // policy P3: the step check needs a baseline and is dropped after FSAC_SENSOR_REARM_FRAMES consecutive invalid frames
    if ((state->has_last != 0U) && (state->invalid_run < FSAC_SENSOR_REARM_FRAMES))
    {
        diff = (int64_t)value - (int64_t)state->last_value;

        if (diff < 0)
        {
            diff = -diff;
        }

        exceeded = (diff > (int64_t)cfg->max_step);
    }

    return exceeded;
}

// state handling
static void clear_state(fsac_sensor_state_t * state)
{
    state->last_value  = 0;
    state->last_seq    = 0U;
    state->invalid_run = 0U;
    state->fault_total = 0U;
    state->has_last    = 0U;
    state->has_seq     = 0U;
    state->reserved    = 0U;
}

fsac_sensor_status_t fsac_sensor_init(fsac_sensor_state_t * state,
                                      const fsac_sensor_cfg_t * cfg)
{
    fsac_sensor_status_t status = FSAC_SENSOR_OK;

    if (state == NULL)
    {
        status = FSAC_SENSOR_ERR_NULL;
    }
    else
    {
        clear_state(state);   // on every path: an error leaves a safe empty state 

        if (cfg == NULL)
        {
            status = FSAC_SENSOR_ERR_NULL;
        }
        else if (!config_ok(cfg))
        {
            status = FSAC_SENSOR_ERR_CONFIG;
        }
        else
        {
            // nothing more to do: the state is ready 
        }
    }

    return status;
}

// the only function that changes the state after init (policies P1, P3, P5)
static void update_state(fsac_sensor_state_t * state,
                         fsac_sensor_status_t status,
                         fsac_q16_t           value,
                         bool                 fresh,
                         uint32_t             seq)
{
    if (fresh)
    {
        state->last_seq = seq;
        state->has_seq  = 1U;
    }

    if (status == FSAC_SENSOR_OK)
    {
        state->last_value  = value;
        state->has_last    = 1U;
        state->invalid_run = 0U;
    }
    else
    {
        state->invalid_run = sat_inc(state->invalid_run);
        state->fault_total = sat_inc(state->fault_total);
    }
}

/*
 * the checks, in the order documented in the header
 *   reads the state, does not change it
 *   *value    receives the checked value (0 unless the result is OK)
 *   *seq_fresh is true when the snapshot is intact and has a new sequence number (input for policy P1)
*/

static fsac_sensor_status_t evaluate(const fsac_sensor_state_t *state, const fsac_sensor_cfg_t *cfg, const fsac_sensor_raw_t *snap, fsac_q16_t *value, bool *seq_fresh)
{
    fsac_sensor_status_t status = FSAC_SENSOR_OK;
    uint32_t   delta  = 0U;
    bool       fresh  = false;
    fsac_q16_t scaled = 0;

    *value     = 0;
    *seq_fresh = false;

    if (!config_ok(cfg))                                      // check 2 
    {
        status = FSAC_SENSOR_ERR_CONFIG;
    }
    else if (snap->seq_begin != snap->seq_end)                // check 3 
    {
        status = FSAC_SENSOR_ERR_TORN;
    }
    else if (fsac_sensor_crc16(snap) != snap->crc16)          // check 4 
    {
        status = FSAC_SENSOR_ERR_CRC;
    }
    else
    {
        // the snapshot is intact; work out whether its sequence is new
        if (state->has_seq != 0U)
        {
            delta = snap->seq_begin - state->last_seq;   // modular, wrap safe 
            fresh = (delta != 0U);
        }
        else
        {
            fresh = true;
        }
        *seq_fresh = fresh;

        if ((uint16_t)(snap->hw_flags & FSAC_HWFLAG_ANY_FAULT) != 0U)   // check 5
        {
            status = FSAC_SENSOR_ERR_HW;
        }
        else if (!fresh)                                                // check 6 
        {
            status = FSAC_SENSOR_ERR_STALE;
        }
        else if ((state->has_seq != 0U) && (delta > FSAC_SENSOR_MAX_SEQ_JUMP))
        {
            status = FSAC_SENSOR_ERR_SEQ;
        }
        else
        {
            scaled = fsac_sensor_scale(snap->counts, cfg);

            if ((scaled < cfg->min_valid) || (scaled > cfg->max_valid)) // check 7 
            {
                status = FSAC_SENSOR_ERR_RANGE;
            }
            else if (step_exceeded(state, scaled, cfg))                 // check 8 
            {
                status = FSAC_SENSOR_ERR_STEP;
            }
            else
            {
                *value = scaled;
            }
        }
    }

    return status;
}


// public read function
fsac_sensor_status_t fsac_sensor_read(fsac_sensor_state_t * state, const fsac_sensor_cfg_t * cfg, const volatile fsac_sensor_raw_t * raw, uint32_t frame, 
                                      fsac_sensor_sample_t * out)
{
    fsac_sensor_status_t status = FSAC_SENSOR_ERR_NULL;
    fsac_q16_t           value  = 0;
    bool                 fresh  = false;
    fsac_sensor_raw_t    snap   = { 0U, 0, 0U, 0U, 0U, 0U };

    // without an output there is nowhere to publish: only the code is returned
    if (out != NULL)
    {
        if ((state != NULL) && (cfg != NULL) && (raw != NULL))
        {
            // rule R5: one copy of the live mailbox, in the order the FPGA writes it; everything after this works on the copy
            snap.seq_begin    = raw->seq_begin;
            snap.counts       = raw->counts;
            snap.timestamp_us = raw->timestamp_us;
            snap.hw_flags     = raw->hw_flags;
            snap.crc16        = raw->crc16;
            snap.seq_end      = raw->seq_end;

            status = evaluate(state, cfg, &snap, &value, &fresh);
            update_state(state, status, value, fresh, snap.seq_begin);
        }

        // policy P4: single publish point, value 0 unless the status is OK
        out->value    = (status == FSAC_SENSOR_OK) ? value : 0;
        out->frame    = frame;
        out->status   = status;
        out->valid    = (uint8_t)((status == FSAC_SENSOR_OK) ? 1U : 0U);
        out->reserved = 0U;
    }

    return status;
}