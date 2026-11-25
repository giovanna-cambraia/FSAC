/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/include/fsac_gw_1553.h
 * Module      : Mission gateway, MIL-STD-1553B whitelist parser, public interface
 * Language    : C11, written to MISRA C:2012 (Amendment 2/3)
 * Assurance   : DO-178C Software Level C (partition P6 is DAL C)
 * Partition   : P6 MISSION_GATEWAY
 * Requirements: SECR-GW-0001, SECR-GW-0002, SECR-ARC-0001, SECR-ARC-0002,
 *               SECR-TARA-0004 (placeholder IDs)
 *
 * PURPOSE
 *   This is the border where bytes from the shared mission bus first meet the
 *   FSAC. The bus is hostile (attacker AT-1 in docs/05_security/TARA.md): any
 *   other system on it may be compromised. The parser accepts a very small set
 *   of exactly-shaped messages, listed in docs/04_interface/ICD_mission_bus.md,
 *   and drops everything else. It does not try to understand or repair traffic.
 *   Nothing is accepted that does not match a row of the whitelist exactly.
 *
 *   Two directions:
 *     RECEIVE   the bus controller sends data to the FSAC. An accepted message
 *               becomes one fixed-size record in a small output ring.
 *     TRANSMIT  the bus controller asks the FSAC for data. The answer comes
 *               only from a dedicated buffer filled by the one-way copy from
 *               Z0 (ICD, rules TX-1 to TX-4). The parser never reads control
 *               state.
 *
 *   It makes true the rule of security_architecture.md, section 1: in flight
 *   an untrusted input is DROPPED, COUNTED and LOGGED. It never stops, resets
 *   or degrades anything. This header has no callback and no mode: a rejection
 *   can only move a counter. That is how SECR-TARA-0004 is met by construction.
 *
 * DESIGN RULES (each one maps to a MISRA or DO-326A argument)
 *   R1  No dynamic memory. All state lives in a structure the CALLER owns
 *       (MISRA Rule 21.3).
 *   R2  No hidden state. The parser has no static variables; everything it
 *       remembers is in fsac_gw_state_t.
 *   R3  Bounded execution. The longest accepted frame is 18 bytes; loops are
 *       bounded by 8 words and 5 table rows; no recursion (MISRA Rule 17.2).
 *   R4  Every pointer argument is checked for NULL at this boundary and the
 *       failure is reported, never ignored (ADR-008).
 *   R5  The input is read only inside [data, data + length). The length is
 *       checked before the first byte is read (property G1).
 *   R6  Default deny. A frame is accepted only if it matches a row of the
 *       whitelist in all four fields: RT address, T/R, subaddress, word count.
 *   R7  Exact shape. Word counts are equal, not "at most". Reserved words must
 *       be zero. No padding, no trimming, no guessing.
 *   R8  A rejected frame changes no output: no record is queued and no
 *       response is produced. Only one counter moves (property G4).
 *   R9  Counters saturate at their maximum. They never wrap to zero, so a
 *       flood cannot erase its own evidence.
 *   R10 The response is written on EVERY call, including rejections, and is
 *       empty when there is nothing to send.
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
 *   Checks 3 and 4 are in this order because broadcast (31) is also "not the
 *   FSAC address"; the other order would make REJ_BROADCAST unreachable.
 *
 * FRAME FORMAT (what the bus driver hands over: PLACEHOLDER, match the driver)
 *   A byte buffer of 16-bit words, little-endian.
 *   RECEIVE  : command word, then N data words. Length = 2 + 2N bytes.
 *   TRANSMIT : command word only. Length = 2 bytes.
 *   Command word: bits 15..11 RT address, bit 10 T/R (1 = FSAC transmits),
 *                 bits 9..5 subaddress, bits 4..0 word count.
 *   A word count of 0 means 32 words in MIL-STD-1553B; 32 is above the limit
 *   of 8 and is never listed, so it ends as REJ_NOT_LISTED. Subaddresses 0 and
 *   31 are mode codes in the standard; no mode code is listed.
 *
 * TIMING BUDGET
 *   One fsac_gw_process: constant and tiny (at most 18 bytes read). Not
 *   measured. The gateway runs in P6, DAL C, and no flight-critical function
 *   depends on its timing (security_architecture.md, section 2.1).
 *
 * USAGE (the caller, in partition P6)
 *   fsac_gw_init(&state);                                 // once
 *   for each frame received from the bus driver:
 *       status = fsac_gw_process(&state, data, length, frame, &response);
 *       if (status == FSAC_GW_ACCEPTED_TX) { send response words to the bus; }
 *   for each fresh snapshot copied from Z0:
 *       status = fsac_gw_tx_load(&state, msg_id, words, count, frame);
 *   to consume accepted data:
 *       while (fsac_gw_pop(&state, &record) == 1U) { use record; }
 *   frame is the minor-frame number (5 ms). The caller must use the return
 *   values (MISRA Rule 17.7).
 *
 * MISRA NOTES
 *   * Fixed-width types only (Directive 4.6).
 *   * Status codes are uint8_t constants, not enum values, like the sensor
 *     driver (Rule 10.4).
 *   * _Static_assert needs C11. Allowed under MISRA C:2012 Amendment 3.
 *   * No deviations are requested by this header.
 *
 * WHAT THIS DOES NOT COVER
 *   * The real RT address, subaddress map, rate limits and message set: all
 *     PLACEHOLDERS (ICD, section 9, open items OI-1 and OI-2).
 *   * Whether what the caller loads for transmission is allowed content (TX-3
 *     is enforced by what P6 is given, not by this module).
 *   * The log. Counters are kept here; log records are rate limited elsewhere
 *     (SM-09).
 *   * AFDX. * Timing on a target. * Real bus controller behaviour.
*/

#ifndef FSAC_GW_1553_H
#define FSAC_GW_1553_H

#include <stdint.h>


// compile-time assertion helper (the same shape as in fsac_hsi_sensor.h)
#define FSAC_GW_STATIC_ASSERT(cond, msg) _Static_assert((cond), msg)


// bus parameters (ICD_mission_bus.md, sections 3 and 7)
// ALL PLACEHOLDERS until the real integration data replaces the ICD table

#define FSAC_GW_RT_ADDRESS          (5U)    // address of the FSAC as a Remote Terminal
#define FSAC_GW_BROADCAST_ADDRESS   (31U)   // never accepted (ICD, rule R-3)
#define FSAC_GW_MAX_WORDS           (8U)    // largest listed message
#define FSAC_GW_MAX_FRAME_BYTES     (2U + (2U * FSAC_GW_MAX_WORDS))   // 18

#define FSAC_GW_NUM_MSGS            (5U)    // rows of the whitelist
#define FSAC_GW_RATE_LIMIT_PER_MAJOR (2U)   // accepted messages per ID per major frame
#define FSAC_GW_MINORS_PER_MAJOR    (4U)    // 20 ms major frame / 5 ms minor frame
#define FSAC_GW_RING_DEPTH          (4U)    // output records, fixed
#define FSAC_GW_TX_MAX_AGE_MAJOR    (5U)    // older transmit data is answered as "no data"
#define FSAC_GW_NO_DATA_WORD        ((uint16_t)0xFFFFU)   // the "no data" pattern (ICD, TX-4)

FSAC_GW_STATIC_ASSERT(FSAC_GW_MAX_FRAME_BYTES == 18U, "longest frame must be 18 bytes");


// message IDs, one per row of the ICD whitelist (section 4)
typedef uint8_t fsac_gw_msg_id_t;

#define FSAC_GW_MSG_NONE            ((fsac_gw_msg_id_t)0U)
#define FSAC_GW_MSG_NAV_HINT        ((fsac_gw_msg_id_t)1U)   // MB-R-01, receive, subaddress 1, 4 words
#define FSAC_GW_MSG_TIME_SYNC       ((fsac_gw_msg_id_t)2U)   // MB-R-02, receive, subaddress 2, 2 words
#define FSAC_GW_MSG_MISSION_MODE    ((fsac_gw_msg_id_t)3U)   // MB-R-03, receive, subaddress 3, 8 words
#define FSAC_GW_MSG_FSAC_STATUS     ((fsac_gw_msg_id_t)4U)   // MB-T-01, transmit, subaddress 1, 6 words
#define FSAC_GW_MSG_FSAC_SNAPSHOT   ((fsac_gw_msg_id_t)5U)   // MB-T-02, transmit, subaddress 2, 4 words


// result codes
typedef uint8_t fsac_gw_status_t;

#define FSAC_GW_ACCEPTED_RX     ((fsac_gw_status_t)0U)    // one record queued
#define FSAC_GW_ACCEPTED_TX     ((fsac_gw_status_t)1U)    // response produced
#define FSAC_GW_ERR_NULL        ((fsac_gw_status_t)2U)    // NULL argument, caller error, no counter moves
#define FSAC_GW_ERR_ARG         ((fsac_gw_status_t)3U)    // bad argument to fsac_gw_tx_load
#define FSAC_GW_REJ_LENGTH      ((fsac_gw_status_t)4U)    // check 1
#define FSAC_GW_REJ_FRAMING     ((fsac_gw_status_t)5U)    // check 2
#define FSAC_GW_REJ_BROADCAST   ((fsac_gw_status_t)6U)    // check 3
#define FSAC_GW_REJ_ADDRESS     ((fsac_gw_status_t)7U)    // check 4
#define FSAC_GW_REJ_NOT_LISTED  ((fsac_gw_status_t)8U)    // check 5
#define FSAC_GW_REJ_RANGE       ((fsac_gw_status_t)9U)    // check 6
#define FSAC_GW_REJ_RATE        ((fsac_gw_status_t)10U)   // check 7
#define FSAC_GW_REJ_OVERRUN     ((fsac_gw_status_t)11U)   // check 8


// counters: one per outcome of fsac_gw_process, saturating (rule R9)
// every call that is not ERR_NULL moves exactly one of them, by one
typedef struct
{
    uint32_t accepted_rx;
    uint32_t accepted_tx;
    uint32_t rej_length;
    uint32_t rej_framing;
    uint32_t rej_broadcast;
    uint32_t rej_address;
    uint32_t rej_not_listed;
    uint32_t rej_range;
    uint32_t rej_rate;
    uint32_t rej_overrun;
} fsac_gw_counters_t;


// output record: one per accepted RECEIVE message (32 bytes, no padding)
// it holds the VALIDATED data words, not the command word and not the raw frame
typedef struct
{
    uint16_t msg_id;                          // fsac_gw_msg_id_t of the matched row
    uint16_t word_count;                      // number of valid entries in words[]
    uint32_t seq;                             // sequence number assigned by the parser
    uint32_t frame;                           // minor-frame number when accepted
    uint32_t reserved;                        // always 0
    uint16_t words[FSAC_GW_MAX_WORDS];        // validated data words, unused ones are 0
} fsac_gw_record_t;

FSAC_GW_STATIC_ASSERT(sizeof(fsac_gw_record_t) == 32U, "record must be 32 bytes");


// response to a TRANSMIT request
// fresh = 1U : the words come from a loaded buffer that is not older than the limit
// fresh = 0U : the words are all FSAC_GW_NO_DATA_WORD (ICD, TX-4)
// word_count = 0U and fresh = 0U : there is no response to send
typedef struct
{
    uint16_t words[FSAC_GW_MAX_WORDS];
    uint8_t  word_count;
    uint8_t  fresh;
    uint16_t reserved;      // always 0
} fsac_gw_response_t;


// per-gateway state (owned by the caller)
// initialise with fsac_gw_init before the first call; a zero-filled structure is
// NOT a valid state: use the init function
typedef struct
{
    fsac_gw_counters_t counters;

    // rate limiting, counted per major frame (ICD, rule R-4)
    uint8_t  rate_used[FSAC_GW_NUM_MSGS];
    uint32_t rate_major;                      // major frame the counters belong to
    uint8_t  has_rate_major;                  // 1U once a major frame has been seen

    // output ring
    fsac_gw_record_t ring[FSAC_GW_RING_DEPTH];
    uint8_t  ring_head;                       // next slot to read
    uint8_t  ring_count;                      // records waiting
    uint32_t seq;                             // sequence number of the next record

    // transmit buffers, one per row (only the transmit rows are used)
    uint16_t tx_words[FSAC_GW_NUM_MSGS][FSAC_GW_MAX_WORDS];
    uint32_t tx_frame[FSAC_GW_NUM_MSGS];      // minor frame when loaded
    uint8_t  tx_valid[FSAC_GW_NUM_MSGS];      // 1U once loaded
} fsac_gw_state_t;


// interface

/*
 * fsac_gw_init
 *   prepares one gateway state: all counters zero, ring empty, no transmit data
 *   returns FSAC_GW_OK-class codes: FSAC_GW_ACCEPTED_RX (0U) on success, or
 *   FSAC_GW_ERR_NULL; on error nothing is written
*/
fsac_gw_status_t fsac_gw_init(fsac_gw_state_t * state);

/*
 * fsac_gw_process
 *   parses one frame from the bus (the ORDER OF CHECKS above)
 *     state    : in/out, the gateway memory
 *     data     : the frame bytes; read only inside [data, data + length)
 *     length   : number of bytes; 0 is a rejection (REJ_LENGTH), whatever data is
 *     frame    : current minor-frame number
 *     response : receives the answer to a TRANSMIT request; written on EVERY call
 *   returns FSAC_GW_ACCEPTED_RX, FSAC_GW_ACCEPTED_TX, one FSAC_GW_REJ_* code, or
 *   FSAC_GW_ERR_NULL (state or response NULL, or data NULL with length above 0)
 *   FSAC_GW_ERR_NULL is a caller error: no counter moves
 *   any other return moves exactly one counter, saturating, and a rejection
 *   queues no record and produces no response
*/
fsac_gw_status_t fsac_gw_process(fsac_gw_state_t * state, const uint8_t * data,
                                 uint32_t length, uint32_t frame,
                                 fsac_gw_response_t * response);

/*
 * fsac_gw_tx_load
 *   stores the words that the next TRANSMIT request for msg_id will answer with
 *   called by P6 with a snapshot copied one-way from Z0 (ICD, rule TX-1)
 *   msg_id must be a transmit row and count must equal that row's word count
 *   returns FSAC_GW_ACCEPTED_RX (0U) on success, FSAC_GW_ERR_NULL or FSAC_GW_ERR_ARG;
 *   on error nothing is written
*/
fsac_gw_status_t fsac_gw_tx_load(fsac_gw_state_t * state, fsac_gw_msg_id_t msg_id,
                                 const uint16_t * words, uint8_t count, uint32_t frame);

/*
 * fsac_gw_pop
 *   removes the oldest record from the output ring and copies it to out
 *   returns 1U when a record was delivered, 0U when the ring is empty
 *   (out is then filled with zeros); a NULL argument returns 0U
*/
uint8_t fsac_gw_pop(fsac_gw_state_t * state, fsac_gw_record_t * out);

#endif