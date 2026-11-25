/*
 * fsac_secure_boot.h
 *
 * PURPOSE
 *   Strict manifest reader and boot decision for the FSAC secure boot chain.
 *   Public interface. The cryptography is NOT here: it is reached through the
 *   function table fsb_ops_t, so the decision logic can be tested with a fake.
 *
 * DESIGN SOURCES
 *   security/signing/secure_boot.md   (sections 5 to 8, ADR-013)
 *   docs/05_security/TARA.md          (T-08, T-09, T-13, T-23, T-24)
 *
 * REQUIREMENTS (placeholders, see docs/03_requirements/SEC/)
 *   SECR-BOOT-0001 .. SECR-BOOT-0008, SECR-TARA-0003
 *
 * ASSURANCE LEVEL
 *   To be assigned from the security risk assessment (DO-356A / ED-203A).
 *   Written to the same coding rules as the flight-critical C: C11, MISRA C:2012
 *   style, no dynamic allocation, no recursion, bounded loops.
 *
 * DECISIONS
 *   ADR-013  Ed25519 manifest signature, SHA-256 image digests.
 *   ADR-008  NULL checks only at the public boundary (this header's functions).
 *
 * PROPERTIES THE CODE IS WRITTEN TO HAVE (checked by test, not proved)
 *   B1  fsb_manifest_parse never reads outside [buffer, buffer + length).
 *   B2  fsb_decide returns FSB_REASON_OK only if all nine ordered checks passed.
 *   B3  No policy ACCEPTANCE (checks 6 to 9) uses a manifest field before the
 *       signature verified. Fields read earlier can only lead to a refusal or
 *       to a key lookup (see "Fields read before the signature" below).
 *   B4  fsb_decide never changes a counter. Only fsb_commit does.
 *   B5  The first failing check is the one reported.
 *
 * WHAT THIS DOES NOT COVER
 *   - The cryptographic primitives and the Root of Trust (behind fsb_ops_t).
 *   - Whether the real library rejects non-canonical signatures (L-1).
 *   - Timing of the check. - Runtime integrity after boot.
 *   - The format is checked; the MEANING of image contents is not.
 *
 * Fields read before the signature
 *   key_id (check 2, 3) and key_epoch (key lookup, check 4) come from bytes that
 *   are not yet authentic. They are used only to refuse early or to find the
 *   verification key. An attacker who edits them can cause a refusal, which an
 *   attacker who edits any byte can cause anyway. They can never cause a boot.
*/
#ifndef FSAC_SECURE_BOOT_H
#define FSAC_SECURE_BOOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// ---- Manifest layout (secure_boot.md section 5), all integers little-endian ---- 
#define FSB_FORMAT_VERSION   (1u)
#define FSB_HEADER_SIZE      (32u)
#define FSB_ENTRY_SIZE       (40u)
#define FSB_SIGNATURE_SIZE   (64u)
#define FSB_DIGEST_SIZE      (32u)
#define FSB_MAX_IMAGES       (8u)
#define FSB_MIN_MANIFEST     (FSB_HEADER_SIZE + FSB_ENTRY_SIZE + FSB_SIGNATURE_SIZE)  /* 136 */
#define FSB_MAX_MANIFEST     (FSB_HEADER_SIZE + (FSB_ENTRY_SIZE * FSB_MAX_IMAGES) + FSB_SIGNATURE_SIZE) /* 416 */

#define FSB_KEY_ID_TEST_BIT  (0x8000u)

// Illustrative image IDs and one shared size limit. PLACEHOLDERS: the real values come from the partition table and the slot map (a limit per slot, not one)
#define FSB_IMAGE_ID_FIRST   (1u)
#define FSB_IMAGE_ID_LAST    (4u)
#define FSB_IMAGE_MAX_SIZE   (0x00400000u)

// Results

//Reasons, in the order of the checks of secure_boot.md section 6.1; FSB_REASON_BAD_ARGUMENT is "check 0": a caller error, refused (fail closed)
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

typedef struct
{
    uint16_t image_id;
    uint32_t size;
    uint8_t  digest[FSB_DIGEST_SIZE];
} fsb_image_entry_t;

// Output of the strict reader; every field is UNVERIFIED until the signature has been checked  
typedef struct
{
    uint32_t          target_id;
    uint16_t          hw_rev;
    uint16_t          key_id;
    uint32_t          key_epoch;
    uint32_t          version_counter;
    uint16_t          image_count;
    uint32_t          signed_len;      /* bytes covered by the signature = length - 64 */
    fsb_image_entry_t entries[FSB_MAX_IMAGES];
} fsb_manifest_t;

// What fsb_decide reports (secure_boot.md section 6.3)
typedef struct
{
    fsb_reason_t reason;
    uint8_t      failed_check;       /* 0 = none (or before the ordered checks), 1..9 */
    bool         header_readable;    /* the strict reader accepted the structure */
    bool         fields_authentic;   /* the signature verified; version/epoch/key are authentic */
    bool         counter_jump_warning; /* version_counter more than one above the stored one */
    uint16_t     key_id;             /* meaningful only if header_readable */
    uint32_t     key_epoch;          /* meaningful only if header_readable */
    uint32_t     version_counter;    /* meaningful only if header_readable */
    uint16_t     bad_image_id;       /* image that failed check 9, 0 if none */
} fsb_result_t;

// Interface to the Root of Trust and the crypto library (section 8)
typedef enum
{
    FSB_LIFECYCLE_TEST = 0,
    FSB_LIFECYCLE_PRODUCTION = 1
} fsb_lifecycle_t;

typedef uint32_t fsb_key_handle_t;   /* opaque; meaning belongs to the crypto layer */

// Identity of the unit being booted. 
typedef struct
{
    uint32_t target_id;
    uint16_t hw_rev_min;   /* supported hardware revisions form a range here, */
    uint16_t hw_rev_max;   /* a simplification of "a set" in secure_boot.md 5.1 */
} fsb_unit_t;

typedef struct
{
    void *ctx;   /* passed back unchanged to every function */
    fsb_unit_t unit;

    /* Find the release key and validate its certificate chain. */
    bool (*lookup_release_key)(void *ctx, uint16_t key_id, uint32_t key_epoch,
                               fsb_key_handle_t *key_out);
    /* Ed25519 verification. Must return false for ANY malformed input (L-2). */
    bool (*verify_signature)(void *ctx, fsb_key_handle_t key, const uint8_t *message,
                             size_t length, const uint8_t *signature);
    /* SHA-256. */
    bool (*hash_sha256)(void *ctx, const uint8_t *data, size_t length, uint8_t *digest_out);
    /* Copy the image to its EXECUTION memory and return a pointer to the bytes that
     * will run, or NULL on failure. Hashing happens on that pointer (rule C-3). */
    const uint8_t *(*load_image)(void *ctx, uint16_t image_id, uint32_t size);

    uint32_t        (*rot_get_version_counter)(void *ctx);
    uint32_t        (*rot_get_key_epoch)(void *ctx);
    fsb_lifecycle_t (*rot_get_lifecycle)(void *ctx);
    /* Advance both counters. The hardware refuses to decrease them. */
    bool            (*rot_commit)(void *ctx, uint32_t version_counter, uint32_t key_epoch);
} fsb_ops_t;

// API

/* Strict reader (secure_boot.md 5.5). Pure: no crypto, no state, no side effect.
 * Returns FSB_REASON_OK, FSB_REASON_MALFORMED or FSB_REASON_BAD_ARGUMENT.
 * On any result other than OK, *out is zeroed. */
fsb_reason_t fsb_manifest_parse(const uint8_t *buffer, size_t length, fsb_manifest_t *out);

/* Boot decision (secure_boot.md 6.1). Runs the nine ordered checks; the first
 * failure is reported in result->reason and result->failed_check. Never changes a
 * counter. Boots (returns FSB_REASON_OK) or refuses: there is no third outcome.
 * PRECONDITION (checked, fail closed): ops, every function pointer in ops,
 * manifest and result are non-NULL. */
fsb_reason_t fsb_decide(const fsb_ops_t *ops, const uint8_t *manifest, size_t manifest_length,
                        fsb_result_t *result);

typedef enum
{
    FSB_COMMIT_DONE = 0,
    FSB_COMMIT_NOT_ALLOWED,   /* not on the ground with the session armed, or result not a clean boot */
    FSB_COMMIT_ROT_FAILED     /* the Root of Trust refused or failed */
} fsb_commit_status_t;

/* Commit (secure_boot.md section 4, AR-3, AR-5). Advances the counters to the values
 * of an authentic manifest. ground_session_ok is the caller's statement that
 * weight-on-wheels and the armed maintenance switch hold; this module cannot check it.
 * `result` must be the one fsb_decide produced for this boot. */
fsb_commit_status_t fsb_commit(const fsb_ops_t *ops, const fsb_result_t *result,
                               bool ground_session_ok);

#endif