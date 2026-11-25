/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/include/fsac_secure_boot.h
 * Module      : Secure boot, public interface (strict manifest reader and
 *               boot decision)
 * Language    : C11, written to MISRA C:2012 (Amendment 2/3)
 * Assurance   : To be assigned from the security risk assessment (DO-356A)
 * Partition   : none. Used by the loader, before the hypervisor starts any
 *               partition (security/signing/secure_boot.md, section 2).
 * Requirements: SECR-BOOT-0001 .. SECR-BOOT-0008, SECR-TARA-0003
 *               (placeholder IDs)
 *
 * PURPOSE
 *   This is the border where an untrusted manifest, read from storage, first
 *   meets the decision to start the unit. The strict reader accepts only a
 *   buffer with exactly the format of secure_boot.md, section 5. The boot
 *   decision then runs nine ordered checks and either boots or refuses.
 *   Nothing is started that has not passed every check.
 *
 *   The cryptography is NOT here. Signature verification, hashing, key lookup
 *   and the anti-rollback counters are reached through the function table
 *   fsb_ops_t, so the decision logic can be tested with a fake verifier that
 *   returns any answer on demand.
 *
 * DESIGN RULES (each one maps to a MISRA or DO-326A argument)
 *   R1  No dynamic memory. All state lives in structures that the CALLER
 *       owns (MISRA Rule 21.3).
 *   R2  No hidden state. The module remembers nothing between calls.
 *   R3  Bounded execution. At most 8 images, 32 digest bytes per image, no
 *       recursion (MISRA Rule 17.2).
 *   R4  Every pointer argument is checked for NULL at this public boundary
 *       and the failure is a refusal, never ignored (ADR-008, fail closed).
 *   R5  The reader checks the length before it reads anything, so no read
 *       goes outside the buffer (property B1).
 *   R6  No manifest field drives an ACCEPTANCE before the signature
 *       verified (property B3, see the note below).
 *   R7  Boot or refuse. There is no third outcome, no partial start.
 *   R8  The decision never changes a counter. Only fsb_commit does, and only
 *       on the ground (property B4).
 *
 * ORDER OF CHECKS (the first failure wins, so the reported cause is stable)
 *   0 arguments non-NULL, interface complete       BAD_ARGUMENT
 *   1 exact structure of the manifest              MALFORMED
 *   2 key_id is not 0                              BAD_KEY_ID
 *   3 test key refused in production lifecycle     TEST_KEY_IN_PRODUCTION
 *   4 release key found, chain valid               UNKNOWN_KEY
 *   5 signature verifies                           BAD_SIGNATURE
 *   6 target_id and hw_rev match this unit         WRONG_TARGET
 *   7 key_epoch >= stored epoch                    KEY_REVOKED
 *   8 version_counter >= stored counter            ROLLBACK
 *   9 every image hashes to its digest             IMAGE_MISMATCH
 *
 * PROPERTIES THE CODE IS WRITTEN TO HAVE (checked by test, not proved)
 *   B1  fsb_manifest_parse never reads outside [buffer, buffer + length).
 *   B2  fsb_decide returns FSB_REASON_OK only if all nine checks passed.
 *   B3  No policy acceptance (checks 6 to 9) uses a manifest field before
 *       the signature verified.
 *   B4  fsb_decide never changes a counter.
 *   B5  The first failing check is the one reported.
 *
 * FIELDS READ BEFORE THE SIGNATURE
 *   key_id (checks 2 and 3) and key_epoch (the key lookup, check 4) come
 *   from bytes that are not yet authentic. They are used only to refuse early
 *   or to find the verification key. An attacker who edits them can cause a
 *   refusal, which an attacker who edits any byte can cause anyway. They can
 *   never cause a boot.
 *
 * TIMING BUDGET
 *   Not measured. See fsac_secure_boot.c.
 *
 * USAGE (the caller, in the loader)
 *   reason = fsb_decide(&ops, manifest, manifest_length, &result);
 *   if (reason == FSB_REASON_OK) { start the hypervisor; }
 *   else                         { record result; do not start; }
 *   later, on the ground, with the maintenance session armed:
 *   status = fsb_commit(&ops, &result, ground_session_ok);
 *   The caller must use the return values (MISRA Rule 17.7).
 *
 * MISRA NOTES
 *   * Fixed-width types only (Directive 4.6).
 *   * Reason and commit codes are enum values here, unlike the sensor driver's
 *     uint8_t codes, because this module is not mirrored in Ada. To be
 *     confirmed against Rule 10.4 in the compliance record.
 *   * _Static_assert needs C11. Allowed under MISRA C:2012 Amendment 3.
 *   * No deviations are requested by this header.
 *
 * WHAT THIS DOES NOT COVER
 *   * The cryptographic primitives and the Root of Trust (behind fsb_ops_t).
 *   * Whether the real library rejects non-canonical signatures (rule L-1).
 *   * Timing of the check, and runtime integrity after boot.
 *   * The format is checked; the MEANING of image contents is not.
*/

#ifndef FSAC_SECURE_BOOT_H
#define FSAC_SECURE_BOOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>


// manifest layout (secure_boot.md, section 5), all integers little-endian
#define FSB_FORMAT_VERSION    (1U)
#define FSB_HEADER_SIZE       (32U)
#define FSB_ENTRY_SIZE        (40U)
#define FSB_SIGNATURE_SIZE    (64U)
#define FSB_DIGEST_SIZE       (32U)
#define FSB_MAX_IMAGES        (8U)
#define FSB_MIN_MANIFEST      (FSB_HEADER_SIZE + FSB_ENTRY_SIZE + FSB_SIGNATURE_SIZE)
#define FSB_MAX_MANIFEST      (FSB_HEADER_SIZE + (FSB_ENTRY_SIZE * FSB_MAX_IMAGES) + FSB_SIGNATURE_SIZE)

_Static_assert(FSB_MIN_MANIFEST == 136U, "one-image manifest must be 136 bytes");
_Static_assert(FSB_MAX_MANIFEST == 416U, "eight-image manifest must be 416 bytes");

// key ids with the high bit set are test keys
#define FSB_KEY_ID_TEST_BIT   (0x8000U)

// illustrative image IDs and one shared size limit; PLACEHOLDERS, the real
// values come from the partition table and the slot map (one limit per slot)
#define FSB_IMAGE_ID_FIRST    (1U)
#define FSB_IMAGE_ID_LAST     (4U)
#define FSB_IMAGE_MAX_SIZE    (0x00400000U)


// result codes, in the order of the checks of secure_boot.md, section 6.1
// FSB_REASON_BAD_ARGUMENT is "check 0": a caller error, refused (fail closed)
typedef enum
{
    FSB_REASON_OK = 0,
    FSB_REASON_BAD_ARGUMENT,
    FSB_REASON_MALFORMED,
    FSB_REASON_BAD_KEY_ID,
    FSB_REASON_TEST_KEY_IN_PRODUCTION,
    FSB_REASON_UNKNOWN_KEY,
    FSB_REASON_BAD_SIGNATURE,
    FSB_REASON_WRONG_TARGET,
    FSB_REASON_KEY_REVOKED,
    FSB_REASON_ROLLBACK,
    FSB_REASON_IMAGE_MISMATCH
} fsb_reason_t;


// one image entry of the manifest
typedef struct
{
    uint16_t image_id;                   // which image (1 .. FSB_IMAGE_ID_LAST)
    uint32_t size;                       // bytes, 1 .. FSB_IMAGE_MAX_SIZE
    uint8_t  digest[FSB_DIGEST_SIZE];    // SHA-256 of the image bytes
} fsb_image_entry_t;

// output of the strict reader; every field is UNVERIFIED until the
// signature has been checked
typedef struct
{
    uint32_t          target_id;                  // aircraft family and LRU type
    uint16_t          hw_rev;                     // hardware revision
    uint16_t          key_id;                     // release key; high bit = test key
    uint32_t          key_epoch;                  // compared with the stored epoch
    uint32_t          version_counter;            // compared with the stored counter
    uint16_t          image_count;                // 1 .. FSB_MAX_IMAGES
    uint32_t          signed_len;                 // bytes covered by the signature
    fsb_image_entry_t entries[FSB_MAX_IMAGES];    // first image_count are used
} fsb_manifest_t;

// what fsb_decide reports (secure_boot.md, section 6.3)
typedef struct
{
    fsb_reason_t reason;                 // FSB_REASON_OK or the first failing check
    uint8_t      failed_check;           // 0 = none (or before the checks), 1 .. 9
    bool         header_readable;        // the strict reader accepted the structure
    bool         fields_authentic;       // the signature verified
    bool         counter_jump_warning;   // version_counter more than 1 above the stored one
    uint16_t     key_id;                 // meaningful only if header_readable
    uint32_t     key_epoch;              // meaningful only if header_readable
    uint32_t     version_counter;        // meaningful only if header_readable
    uint16_t     bad_image_id;           // image that failed check 9, 0 if none
} fsb_result_t;


// interface to the Root of Trust and the crypto library (secure_boot.md, section 8)

typedef enum
{
    FSB_LIFECYCLE_TEST = 0,
    FSB_LIFECYCLE_PRODUCTION = 1
} fsb_lifecycle_t;

// opaque key handle; its meaning belongs to the crypto layer
typedef uint32_t fsb_key_handle_t;

// identity of the unit being booted
typedef struct
{
    uint32_t target_id;
    uint16_t hw_rev_min;   // supported hardware revisions form a range here,
    uint16_t hw_rev_max;   // a simplification of "a set" in secure_boot.md, 5.1
} fsb_unit_t;

typedef struct
{
    void *     ctx;    // passed back unchanged to every function below
    fsb_unit_t unit;

    // find the release key and validate its certificate chain
    bool (*lookup_release_key)(void * ctx, uint16_t key_id, uint32_t key_epoch,
                               fsb_key_handle_t * key_out);

    // Ed25519 verification; must return false for ANY malformed input (rule L-2)
    bool (*verify_signature)(void * ctx, fsb_key_handle_t key, const uint8_t * message,
                             size_t length, const uint8_t * signature);

    // SHA-256
    bool (*hash_sha256)(void * ctx, const uint8_t * data, size_t length,
                        uint8_t * digest_out);

    // copy the image to its EXECUTION memory and return a pointer to the bytes
    // that will run, or NULL on failure; hashing happens on that pointer (rule C-3)
    const uint8_t * (*load_image)(void * ctx, uint16_t image_id, uint32_t size);

    uint32_t        (*rot_get_version_counter)(void * ctx);
    uint32_t        (*rot_get_key_epoch)(void * ctx);
    fsb_lifecycle_t (*rot_get_lifecycle)(void * ctx);

    // advance both counters; the hardware refuses to decrease them
    bool            (*rot_commit)(void * ctx, uint32_t version_counter, uint32_t key_epoch);
} fsb_ops_t;


// interface

/*
 * fsb_manifest_parse
 *   strict reader (secure_boot.md, 5.5); pure: no crypto, no state, no side effect
 *   returns FSB_REASON_OK, FSB_REASON_MALFORMED or FSB_REASON_BAD_ARGUMENT
 *   on any result other than OK, *out is zeroed
*/
fsb_reason_t fsb_manifest_parse(const uint8_t * buffer, size_t length,
                                fsb_manifest_t * out);

/*
 * fsb_decide
 *   boot decision (secure_boot.md, 6.1); runs the nine ordered checks; the first
 *   failure is reported in result->reason and result->failed_check; never changes
 *   a counter; boots (returns FSB_REASON_OK) or refuses, there is no third outcome
 *   PRECONDITION (checked, fail closed): ops, every function pointer in ops,
 *   manifest and result are non-NULL
*/
fsb_reason_t fsb_decide(const fsb_ops_t * ops, const uint8_t * manifest,
                        size_t manifest_length, fsb_result_t * result);


// outcome of a commit
typedef enum
{
    FSB_COMMIT_DONE = 0,
    FSB_COMMIT_NOT_ALLOWED,   // not on the ground with the session armed, or the result is not a clean boot
    FSB_COMMIT_ROT_FAILED     // the Root of Trust refused or failed
} fsb_commit_status_t;

/*
 * fsb_commit
 *   advances the counters to the values of an authentic manifest
 *   (secure_boot.md, section 4, rules AR-3 and AR-5)
 *   ground_session_ok is the caller's statement that weight-on-wheels and the
 *   armed maintenance switch hold; this module cannot check it
 *   result must be the one fsb_decide produced for this boot
*/
fsb_commit_status_t fsb_commit(const fsb_ops_t * ops, const fsb_result_t * result,
                               bool ground_session_ok);

#endif