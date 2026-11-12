/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/include/fsac_hsi_sensor.h
 * Module      : Sensor acquisition driver, public interface (HSI)
 * Language    : C11, written to MISRA C:2012 (Amendment 2/3)
 * Assurance   : DO-178C Software Level A (target)
 * Partition   : P1 SENSOR_INGEST
 * Requirements: HLR-HSI-0001 .. HLR-HSI-0012 (placeholder IDs)
 *
 * PURPOSE
 *   This is the border where raw data from the I/O FPGA first meets the
 *   typed world of the SPARK core. The FPGA leaves each sensor sample in a
 *   small memory-mapped mailbox. This driver reads it, checks it, converts
 *   it to Q16 engineering units, and hands the core a sample that is either
 *   VALID (safe to use) or INVALID (to be ignored). Nothing reaches the
 *   core without passing every check below.
 *
 *   It makes true the premise stated in proof/README.md, section 6, item 3:
 *   the core assumes Body_Rate is within +-8 rad/s, and this driver is what
 *   enforces it.
 *
 * DESIGN RULES (each one maps to a MISRA or DO-178C argument)
 *   R1  No dynamic memory. All state lives in structures that the CALLER
 *       owns (MISRA Rule 21.3, spec section 3).
 *   R2  No hidden state. The driver has no static variables; everything it
 *       remembers is in fsac_sensor_state_t.
 *   R3  Bounded execution. No loops that depend on data, no recursion
 *       (MISRA Rule 17.2). The cost of one read is constant.
 *   R4  Every pointer argument is checked for NULL and the failure is
 *       reported, never ignored (defensive programming at an interface).
 *   R5  The mailbox is volatile. The driver copies it ONCE into a local
 *       snapshot and checks the snapshot, never the live registers.
 *   R6  Same arithmetic as the Ada core. Scaling uses truncation toward
 *       zero and saturation, exactly as Fsac.Fixed_Math.Mul_Q, so C and Ada
 *       agree to the last bit (bit-exact comparison between lanes).
 *   R7  On any failure the output value is 0 and valid is 0. A garbage value
 *       is never published, even by accident.
 *
 * ORDER OF CHECKS (the first failure wins, so the reported cause is stable)
 *   1 arguments non-NULL            ERR_NULL
 *   2 configuration consistent      ERR_CONFIG
 *   3 mailbox not torn (seq_begin = seq_end)   ERR_TORN
 *   4 CRC of the snapshot           ERR_CRC
 *   5 FPGA hw_flags all zero        ERR_HW
 *   6 sequence number advanced      ERR_STALE (no change) / ERR_SEQ (jump)
 *   7 scaled value inside the plausible range  ERR_RANGE
 *   8 change since last valid sample small enough   ERR_STEP
 *
 * TIMING BUDGET
 *   One fsac_sensor_read: target 10 microseconds. A frame reads
 *   FSAC_TOTAL_SENSORS (18) sensors, so about 180 microseconds, inside the
 *   250 microsecond window W1 of the schedule (docs, Part 1 section 4).
 *
 * USAGE (the caller, in partition P1, once per minor frame)
 *   for each measurement m and sensor s:
 *       status = fsac_sensor_read(&state[m][s], &cfg[m], mailbox_ptr(m, s),
 *                                 frame, &sample[m][s]);
 *   The caller must use the return value (MISRA Rule 17.7).
 *
 * MISRA NOTES
 *   * Fixed-width types only (Directive 4.6).
 *   * Status codes are uint8_t constants, not enum values, so the layout
 *     shared with Ada is fixed and no signed/unsigned mixing occurs
 *     (Rule 10.4).
 *   * _Static_assert needs C11. Allowed under MISRA C:2012 Amendment 3.
 *   * No deviations are requested by this header.
*/

#ifndef FSAC_HSI_SENSOR_H
#define FSAC_HSI_SENSOR_H

#include <stdint.h>


// compile-time assertion helper
#define FSAC_STATIC_ASSERT(cond, msg) _Static_assert((cond), msg)


// Q16.16 fixed-point (must match Fsac.Types in the Ada core) raw value = real value * 65536 range is SYMMETRIC: -2147483647 .. +2147483647 (the most negative
// 32-bit value is excluded, so negation can never overflow)
typedef int32_t fsac_q16_t;

#define FSAC_Q16_ONE      INT32_C(65536)
#define FSAC_Q16_MAX      INT32_C(2147483647)
#define FSAC_Q16_MIN      (-INT32_C(2147483647))

// physical limits, raw Q16 (must equal the Ada constants in fsac-types.ads) 
#define FSAC_RATE_MAX_RAW   INT32_C(524288)    // 8.0 rad/s   Body_Rate    
#define FSAC_ALPHA_MAX_RAW  INT32_C(65536)     // 1.0 rad     Angle_Of_Attack
#define FSAC_NZ_MAX_RAW     INT32_C(1048576)   // 16.0 g      Load_Factor   
#define FSAC_QBAR_MAX_RAW   INT32_C(8388608)   // 128.0 kPa   Dyn_Pressure  

// sensor topology (must match Fsac.Sensors_Per_Measurement and the  measurement list used by signal management)
typedef uint8_t fsac_meas_id_t;

#define FSAC_MEAS_RATE_Q   ((fsac_meas_id_t)0U)   // pitch rate, rad/s    
#define FSAC_MEAS_RATE_P   ((fsac_meas_id_t)1U)   // roll rate, rad/s      
#define FSAC_MEAS_RATE_R   ((fsac_meas_id_t)2U)   // yaw rate, rad/s      
#define FSAC_MEAS_NZ       ((fsac_meas_id_t)3U)   // load factor, g        
#define FSAC_MEAS_ALPHA    ((fsac_meas_id_t)4U)   // angle of attack, rad  
#define FSAC_MEAS_QBAR     ((fsac_meas_id_t)5U)   // dynamic pressure, kPa 

#define FSAC_NUM_MEAS          (6U)
#define FSAC_SENSORS_PER_MEAS  (3U)
#define FSAC_TOTAL_SENSORS     (FSAC_NUM_MEAS * FSAC_SENSORS_PER_MEAS)


// result codes
typedef uint8_t fsac_sensor_status_t;

#define FSAC_SENSOR_OK          ((fsac_sensor_status_t)0U)
#define FSAC_SENSOR_ERR_NULL    ((fsac_sensor_status_t)1U)  // NULL argument      
#define FSAC_SENSOR_ERR_CONFIG  ((fsac_sensor_status_t)2U)  // bad configuration  
#define FSAC_SENSOR_ERR_TORN    ((fsac_sensor_status_t)3U)  // read during update 
#define FSAC_SENSOR_ERR_CRC     ((fsac_sensor_status_t)4U)  // CRC mismatch       
#define FSAC_SENSOR_ERR_HW      ((fsac_sensor_status_t)5U)  // FPGA fault flag    
#define FSAC_SENSOR_ERR_STALE   ((fsac_sensor_status_t)6U)  // no new sample     
#define FSAC_SENSOR_ERR_SEQ     ((fsac_sensor_status_t)7U)  // sequence jump      
#define FSAC_SENSOR_ERR_RANGE   ((fsac_sensor_status_t)8U)  // implausible value  
#define FSAC_SENSOR_ERR_STEP    ((fsac_sensor_status_t)9U)  // change too fast    

/* 
 * FPGA mailbox layout (hardware-defined, 20 bytes, no padding)
 * the FPGA writes seq_begin first, then the data words, then seq_end, all with the same sequence number; a reader that sees seq_begin different from seq_end has caught the 
 * FPGA in the middle of an update (a torn read); crc16 is CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection) over the bytes of seq_begin, counts, timestamp_us and
 * hw_flags, each little endian, in that order
*/

typedef struct
{
    uint32_t seq_begin;      // sample number, written first                 
    int32_t  counts;         // signed sensor counts                          
    uint32_t timestamp_us;   // FPGA time of the sample, microseconds mod 2^32 
    uint16_t hw_flags;       // FPGA fault bits, see below                    
    uint16_t crc16;          // see the layout note above                     
    uint32_t seq_end;        // same value as seq_begin, written last         
} fsac_sensor_raw_t;

FSAC_STATIC_ASSERT(sizeof(fsac_sensor_raw_t) == 20U, "mailbox must be 20 bytes");

/* hw_flags is written by the FPGA. FAIL CLOSED (ADR-007): a sample is
 * accepted only when hw_flags == 0. Any set bit, including a bit this
 * software does not define, makes the sample FSAC_SENSOR_ERR_HW. */
#define FSAC_HWFLAG_OVERRANGE    ((uint16_t)0x0001U)  /* input beyond converter range */
#define FSAC_HWFLAG_ADC_FAULT    ((uint16_t)0x0002U)  /* converter self-test failed   */
#define FSAC_HWFLAG_LINK_FAULT   ((uint16_t)0x0004U)  /* sensor link error            */
#define FSAC_HWFLAG_BIT_FAIL     ((uint16_t)0x0008U)  /* built-in test failed         */
#define FSAC_HWFLAG_DEFINED_MASK ((uint16_t)0x000FU)  /* bits named above, diagnostics only */
#define FSAC_HWFLAG_ANY_FAULT    ((uint16_t)0xFFFFU)  /* mask used by the check: every bit  */

/*
 * per-measurement configuration (read-only at run time)
 * physical value (Q16) = ( (counts - offset_counts) * scale_q16 ) / 65536; the product is formed in 64 bits, divided with truncation toward zero and saturated to the symmetric 
 * Q16 range, which is the rule of Mul_Q in Ada
 *
 * Consistency required (checked by fsac_sensor_init, ERR_CONFIG otherwise):
 *   scale_q16 > 0, min_valid < max_valid, both inside +-FSAC_Q16_MAX,
 *   max_step > 0.
*/

typedef struct
{
    int32_t    offset_counts;   // zero offset                                   
    fsac_q16_t scale_q16;       // physical unit per count, Q16                  
    fsac_q16_t min_valid;       // lowest plausible value, inclusive             
    fsac_q16_t max_valid;       // highest plausible value, inclusive            
    fsac_q16_t max_step;        // largest change allowed between valid samples  
} fsac_sensor_cfg_t;

// per-sensor state (owned by the caller, one per physical sensor) initialize with fsac_sensor_init before the first read; a zero-filled structure is NOT a valid state:
// use the init function.
#define FSAC_SENSOR_MAX_SEQ_JUMP  (4U)   // more lost samples than this: ERR_SEQ  
#define FSAC_SENSOR_REARM_FRAMES  (8U)   // invalid frames before the step check is dropped and the sensor may rejoin  

typedef struct
{
    fsac_q16_t last_value;     // last VALID value, baseline for the step check
    uint32_t   last_seq;       // sequence number of the last accepted snapshot
    uint32_t   invalid_run;    // consecutive invalid frames, saturates         
    uint32_t   fault_total;    // count of invalid frames since init, saturates 
    uint8_t    has_last;       // 1U once a valid sample exists, else 0U        
    uint8_t    has_seq;        // 1U once a sequence number has been seen       
    uint16_t   reserved;       // keeps the layout fixed, always 0              
} fsac_sensor_state_t;


// output sample (what the Ada core reads; layout is mirrored in Fsac.Platform_Ports with Convention C, 12 bytes)
// valid = 1U : value is a checked Q16 engineering value
// valid = 0U : ignore value (it is set to 0), status says why

typedef struct
{
    fsac_q16_t           value;      // checked value, or 0 when not valid      
    uint32_t             frame;      // minor-frame number of this read         
    fsac_sensor_status_t status;     // FSAC_SENSOR_OK or an ERR code            
    uint8_t              valid;      // 1U valid, 0U invalid                     
    uint16_t             reserved;   // always 0                                
} fsac_sensor_sample_t;

FSAC_STATIC_ASSERT(sizeof(fsac_sensor_sample_t) == 12U, "sample must be 12 bytes");


// interface
 
/*
 * fsac_sensor_init
 *  prepares one sensor state and validates the configuration. Returns FSAC_SENSOR_OK, FSAC_SENSOR_ERR_NULL or FSAC_SENSOR_ERR_CONFIG;
 *  on any error the state is left filled with a safe empty value
*/
fsac_sensor_status_t fsac_sensor_init(fsac_sensor_state_t * state,
                                      const fsac_sensor_cfg_t * cfg);

/*
 * fsac_sensor_scale
 *  converts counts to Q16 engineering units as described above; pure function, no side effects; exposed so the tests can compare it with the Ada Mul_Q on the same inputs;
 *  a NULL cfg returns 0
*/
fsac_q16_t fsac_sensor_scale(int32_t counts, const fsac_sensor_cfg_t * cfg);

/*
 * fsac_sensor_crc16
 *  CRC-16/CCITT-FALSE of the four data fields of a snapshot (the layout note above); a NULL snapshot returns 0
*/
uint16_t fsac_sensor_crc16(const fsac_sensor_raw_t * snapshot);

/*
 * fsac_sensor_read
 *   reads one mailbox and produces one checked sample
 *     state : in/out, per-sensor memory
 *     cfg   : the configuration of this measurement
 *     raw   : the live (volatile) mailbox; copied once, never re-read
 *     frame : current minor-frame number, recorded in the output
 *     out   : receives the sample, written on EVERY call, including errors
 *   returns the same code that is stored in out->status; when it returns anything but FSAC_SENSOR_OK, out->valid is 0U and out->value is 0 (rule R7)
*/
fsac_sensor_status_t fsac_sensor_read(fsac_sensor_state_t * state, const fsac_sensor_cfg_t * cfg, const volatile fsac_sensor_raw_t * raw, uint32_t frame, 
                                      fsac_sensor_sample_t * out);

#endif