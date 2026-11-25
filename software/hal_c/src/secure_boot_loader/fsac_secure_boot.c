/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/src/secure_boot/fsac_secure_boot.c
 * Module      : Secure boot, strict manifest reader and boot decision
 * Language    : C11, written to MISRA C:2012 (Amendment 2/3)
 * Assurance   : To be assigned from the security risk assessment (DO-356A)
 * Partition   : none. Runs in the loader, before the hypervisor starts any
 *               partition (security/signing/secure_boot.md, section 2).
 * Requirements: SECR-BOOT-0001 .. SECR-BOOT-0008, SECR-TARA-0003
 *               (placeholder IDs)
 *
 * PURPOSE
 *   Decides, on the ground, whether this unit may start: is every image the
 *   manifest lists exactly what an authorised party signed, and is it new
 *   enough? Three entry points:
 *     fsb_manifest_parse  strict reader, pure, no crypto
 *     fsb_decide          the nine ordered checks, never changes a counter
 *     fsb_commit          advances the anti-rollback counters, ground only
 *   The cryptography and the Root of Trust are NOT here: they are reached
 *   through the function table fsb_ops_t (see fsac_secure_boot.h), so the
 *   decision logic can be tested with a fake verifier.
 *
 * DESIGN RULES (each one maps to a MISRA or DO-326A argument)
 *   R1  No dynamic memory. No static variables that change. The only statics
 *       are two read-only zero structures (MISRA Rule 21.3).
 *   R2  No hidden state. Everything the decision needs is passed in; nothing
 *       is remembered between calls.
 *   R3  Bounded execution. Every loop has a fixed bound (at most 8 images,
 *       32 digest bytes). No recursion (MISRA Rule 17.2).
 *   R4  Every pointer argument is checked for NULL at the public boundary and
 *       the failure is a refusal, never ignored (ADR-008, fail closed).
 *   R5  The reader checks the length before it reads anything, and checks
 *       image_count before it computes the expected length, so no read goes
 *       outside the buffer and no arithmetic can overflow (property B1).
 *   R6  No manifest field drives an ACCEPTANCE before the signature verified.
 *       key_id and key_epoch are read earlier only to refuse or to find the
 *       key (property B3).
 *   R7  Boot or refuse. There is no third outcome, no partial start.
 *   R8  Hash the bytes that will execute: the image is loaded first, then
 *       hashed through the pointer the load callback returns (rule C-3).
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
 * TIMING BUDGET
 *   Not measured. Check 9 dominates (hashing every image). A restart in
 *   flight has a time limit that this check must fit; the figure is an open
 *   item (secure_boot.md, section 13, item 5).
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
 *   * Rule 15.5 (single point of exit) is Advisory. This file uses early
 *     returns on purpose: each refusal returns at the check that failed.
 *     To be recorded in the deviation register.
 *   * Not yet checked with a MISRA tool. The compliance record for this
 *     file is open.
 *
 * WHAT THIS DOES NOT COVER
 *   The crypto primitives, the Root of Trust, timing of the check, and the
 *   meaning of image contents.
*/

#include "fsac_secure_boot.h"


// local helpers
static const fsb_manifest_t k_zero_manifest;   // zero-initialised (static storage)
static const fsb_result_t   k_zero_result;     // zero-initialised (static storage)

static const uint8_t k_magic[4] = { 0x46U, 0x53U, 0x4DU, 0x46U };   // 'F' 'S' 'M' 'F'

// little-endian readers, byte by byte, so alignment and host endianness never matter
static uint16_t rd16(const uint8_t * p)
{
    return (uint16_t)((uint16_t)p[0] | (uint16_t)((uint16_t)p[1] << 8));
}

static uint32_t rd32(const uint8_t * p)
{
    return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

static bool image_id_known(uint16_t id)
{
    return (id >= FSB_IMAGE_ID_FIRST) && (id <= FSB_IMAGE_ID_LAST);
}

// records the first failing check and returns its reason
static fsb_reason_t refuse(fsb_result_t * result, fsb_reason_t reason, uint8_t check)
{
    result->reason = reason;
    result->failed_check = check;
    return reason;
}

// true only if every function the decision needs is present
static bool ops_complete(const fsb_ops_t * ops)
{
    return (ops->lookup_release_key != NULL) && (ops->verify_signature != NULL)
        && (ops->hash_sha256 != NULL) && (ops->load_image != NULL)
        && (ops->rot_get_version_counter != NULL) && (ops->rot_get_key_epoch != NULL)
        && (ops->rot_get_lifecycle != NULL) && (ops->rot_commit != NULL);
}

// full-length comparison: always looks at all 32 bytes, never stops early
static bool digest_equal(const uint8_t * a, const uint8_t * b)
{
    uint8_t  diff = 0U;
    uint32_t i;

    for (i = 0U; i < FSB_DIGEST_SIZE; i++)
    {
        diff = (uint8_t)(diff | (uint8_t)(a[i] ^ b[i]));
    }
    return diff == 0U;
}

// strict reader
fsb_reason_t fsb_manifest_parse(const uint8_t * buffer, size_t length, fsb_manifest_t * out)
{
    fsb_manifest_t m = k_zero_manifest;
    uint32_t       i;
    uint32_t       j;
    uint32_t       count;
    uint32_t       expected;

    if ((buffer == NULL) || (out == NULL))
    {
        return FSB_REASON_BAD_ARGUMENT;
    }
    *out = k_zero_manifest;   // on any failure below, *out stays zeroed

    // length bounds first: after this, the 32-byte header is safe to read
    if ((length < (size_t)FSB_MIN_MANIFEST) || (length > (size_t)FSB_MAX_MANIFEST))
    {
        return FSB_REASON_MALFORMED;
    }

    // fixed values: magic, format version, flags
    for (i = 0U; i < 4U; i++)
    {
        if (buffer[i] != k_magic[i])
        {
            return FSB_REASON_MALFORMED;
        }
    }
    if ((rd16(&buffer[4]) != (uint16_t)FSB_FORMAT_VERSION) || (rd16(&buffer[6]) != 0U))
    {
        return FSB_REASON_MALFORMED;
    }

    // image_count range BEFORE computing the expected length: no overflow possible
    count = rd16(&buffer[28]);
    if ((count < 1U) || (count > FSB_MAX_IMAGES) || (rd16(&buffer[30]) != 0U))
    {
        return FSB_REASON_MALFORMED;
    }

    // the declared length and the real length must both equal the formula exactly;
    // this also rejects trailing bytes and truncation
    expected = FSB_HEADER_SIZE + (FSB_ENTRY_SIZE * count) + FSB_SIGNATURE_SIZE;
    if ((rd32(&buffer[8]) != expected) || ((uint32_t)length != expected))
    {
        return FSB_REASON_MALFORMED;
    }

    m.target_id       = rd32(&buffer[12]);
    m.hw_rev          = rd16(&buffer[16]);
    m.key_id          = rd16(&buffer[18]);
    m.key_epoch       = rd32(&buffer[20]);
    m.version_counter = rd32(&buffer[24]);
    m.image_count     = (uint16_t)count;
    m.signed_len      = expected - FSB_SIGNATURE_SIZE;

    // entries: every read is inside [0, expected)
    for (i = 0U; i < count; i++)
    {
        const uint8_t * e    = &buffer[FSB_HEADER_SIZE + (FSB_ENTRY_SIZE * i)];
        uint16_t        id   = rd16(&e[0]);
        uint32_t        size = rd32(&e[4]);

        if ((rd16(&e[2]) != 0U) || !image_id_known(id)
            || (size < 1U) || (size > FSB_IMAGE_MAX_SIZE))
        {
            return FSB_REASON_MALFORMED;
        }
        for (j = 0U; j < i; j++)
        {
            if (m.entries[j].image_id == id)
            {
                return FSB_REASON_MALFORMED;   // duplicate image id
            }
        }
        m.entries[i].image_id = id;
        m.entries[i].size     = size;
        for (j = 0U; j < FSB_DIGEST_SIZE; j++)
        {
            m.entries[i].digest[j] = e[8U + j];
        }
    }

    *out = m;
    return FSB_REASON_OK;
}

// boot decision
fsb_reason_t fsb_decide(const fsb_ops_t * ops, const uint8_t * manifest,
                        size_t manifest_length, fsb_result_t * result)
{
    fsb_manifest_t   m;
    fsb_key_handle_t key = 0U;
    fsb_reason_t     parsed;
    uint32_t         rot_version;
    uint32_t         rot_epoch;
    uint32_t         i;

    if (result == NULL)
    {
        return FSB_REASON_BAD_ARGUMENT;
    }
    *result = k_zero_result;

    // check 0: interface complete (fail closed)
    if ((ops == NULL) || (manifest == NULL) || !ops_complete(ops))
    {
        return refuse(result, FSB_REASON_BAD_ARGUMENT, 0U);
    }

    // check 1: structure
    parsed = fsb_manifest_parse(manifest, manifest_length, &m);
    if (parsed != FSB_REASON_OK)
    {
        return refuse(result, FSB_REASON_MALFORMED, 1U);
    }
    result->header_readable = true;
    result->key_id          = m.key_id;
    result->key_epoch       = m.key_epoch;
    result->version_counter = m.version_counter;

    // check 2: key id valid (unauthenticated field: it may only refuse)
    if (m.key_id == 0U)
    {
        return refuse(result, FSB_REASON_BAD_KEY_ID, 2U);
    }

    // check 3: a test key is refused in production, signature or not;
    // any lifecycle value other than TEST is treated as production (fail closed)
    if ((ops->rot_get_lifecycle(ops->ctx) != FSB_LIFECYCLE_TEST)
        && ((m.key_id & FSB_KEY_ID_TEST_BIT) != 0U))
    {
        return refuse(result, FSB_REASON_TEST_KEY_IN_PRODUCTION, 3U);
    }

    // check 4: release key found and its certificate chain valid
    if (!ops->lookup_release_key(ops->ctx, m.key_id, m.key_epoch, &key))
    {
        return refuse(result, FSB_REASON_UNKNOWN_KEY, 4U);
    }

    // check 5: signature over everything before the signature
    if (!ops->verify_signature(ops->ctx, key, manifest, (size_t)m.signed_len,
                               &manifest[m.signed_len]))
    {
        return refuse(result, FSB_REASON_BAD_SIGNATURE, 5U);
    }
    result->fields_authentic = true;   // from here on the manifest fields are authentic

    // check 6: target and hardware revision
    if ((m.target_id != ops->unit.target_id)
        || (m.hw_rev < ops->unit.hw_rev_min) || (m.hw_rev > ops->unit.hw_rev_max))
    {
        return refuse(result, FSB_REASON_WRONG_TARGET, 6U);
    }

    // check 7: key epoch not revoked
    rot_epoch = ops->rot_get_key_epoch(ops->ctx);
    if (m.key_epoch < rot_epoch)
    {
        return refuse(result, FSB_REASON_KEY_REVOKED, 7U);
    }

    // check 8: anti-rollback; equal is allowed (the same version booting again)
    rot_version = ops->rot_get_version_counter(ops->ctx);
    if (m.version_counter < rot_version)
    {
        return refuse(result, FSB_REASON_ROLLBACK, 8U);
    }
    // subtraction cannot wrap: check 8 established version_counter >= rot_version
    if ((m.version_counter - rot_version) > 1U)
    {
        result->counter_jump_warning = true;   // logged by the caller, never refuses
    }

    // check 9: every image, hashed where it will execute
    for (i = 0U; i < (uint32_t)m.image_count; i++)
    {
        uint8_t         digest[FSB_DIGEST_SIZE];
        const uint8_t * img = ops->load_image(ops->ctx, m.entries[i].image_id,
                                              m.entries[i].size);

        if ((img == NULL)
            || !ops->hash_sha256(ops->ctx, img, (size_t)m.entries[i].size, digest)
            || !digest_equal(digest, m.entries[i].digest))
        {
            result->bad_image_id = m.entries[i].image_id;   // authentic: safe to log
            return refuse(result, FSB_REASON_IMAGE_MISMATCH, 9U);
        }
    }

    result->reason       = FSB_REASON_OK;
    result->failed_check = 0U;
    return FSB_REASON_OK;
}

// commit
fsb_commit_status_t fsb_commit(const fsb_ops_t * ops, const fsb_result_t * result,
                               bool ground_session_ok)
{
    if ((ops == NULL) || (result == NULL) || !ops_complete(ops))
    {
        return FSB_COMMIT_NOT_ALLOWED;
    }

    // only a clean, authentic boot decision, on the ground, may commit
    if (!ground_session_ok || (result->reason != FSB_REASON_OK) || !result->fields_authentic)
    {
        return FSB_COMMIT_NOT_ALLOWED;
    }

    // defensive: a counter never goes down, even if the result was altered
    if ((result->version_counter < ops->rot_get_version_counter(ops->ctx))
        || (result->key_epoch < ops->rot_get_key_epoch(ops->ctx)))
    {
        return FSB_COMMIT_NOT_ALLOWED;
    }

    if (!ops->rot_commit(ops->ctx, result->version_counter, result->key_epoch))
    {
        return FSB_COMMIT_ROT_FAILED;
    }
    return FSB_COMMIT_DONE;
}