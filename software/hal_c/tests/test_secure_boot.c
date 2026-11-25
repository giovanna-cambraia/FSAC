/* ===========================================================================
 * FSAC - Flight Stability Augmentation Computer
 * ===========================================================================
 * File        : software/hal_c/tests/test_secure_boot.c
 * Module      : Tests of the secure boot (strict reader, decision, commit)
 * Language    : C11
 * Assurance   : Test code, not part of the delivered software
 * Partition   : none (host test program)
 * Requirements: SECR-BOOT-0001 .. SECR-BOOT-0008, SECR-TARA-0003
 *               (placeholder IDs)
 *
 * PURPOSE
 *   Exercises every decision path of fsac_secure_boot.c with a FAKE Root of
 *   Trust and a FAKE crypto library. One test group per row of the table in
 *   security/signing/secure_boot.md, section 10, plus the ordering of the
 *   checks and the commit rules. Threats covered: T-08, T-09, T-13, T-23,
 *   T-24 (docs/05_security/TARA.md).
 *
 * WHAT THE FAKE IS, AND IS NOT
 *   The fake "signature" and the fake "digest" are simple deterministic
 *   functions (a rolling byte hash). They are NOT cryptography and prove
 *   nothing about Ed25519 or SHA-256. They have one useful property: changing
 *   any single byte of the input always changes the output, so tampering
 *   tests need no hard-coded "now fail" switch: the fake fails by itself.
 *   The manifest is built by a writer in THIS file, from the byte offsets of
 *   secure_boot.md section 5, not by the code under test, so the reader is
 *   checked against an independent description of the format.
 *
 * TEST GROUPS
 *   P  strict reader: good manifests, length sweep, field defects, zeroed output
 *   D  decision: good paths, each check in order, tamper sweeps, ordering,
 *      the hashed bytes are the loaded bytes, NULL and incomplete interface
 *   C  commit: ground only, clean boot only, counters never go down
 *   S  scenario: install, commit, rollback attempt (T-09)
 *
 * BUILD AND RUN (from software/hal_c/tests)
 *   gcc -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Wshadow -I../include \
 *       -o test_secure_boot test_secure_boot.c ../src/secure_boot/fsac_secure_boot.c
 *   ./test_secure_boot
 *   Exit code 0 when every check passed, 1 otherwise.
 *   Optional, where the compiler supports it (Linux or WSL): add
 *   -g -fsanitize=address,undefined. Group P allocates each input at its exact
 *   length so an out-of-bounds read by the reader is caught.
 *
 * MISRA NOTES
 *   * Test code is outside the MISRA claim. It uses the standard library
 *     (stdio, stdlib, string) which the delivered code does not.
 *
 * WHAT THIS DOES NOT COVER
 *   * The real crypto library and Root of Trust.
 *   * Timing. * Behaviour on a target. * Structural coverage is not measured
 *     by this file (run gcov as for the sensor driver).
*/

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsac_secure_boot.h"


// constants of the test unit
#define UNIT_TARGET    (0xF5AC0001U)
#define UNIT_HW_MIN    (1U)
#define UNIT_HW_MAX    (3U)

#define BUF_CAP        (512U)    // larger than the largest manifest (416)
#define IMG_BYTES      (128U)    // bytes available per fake image slot
#define IMG_SIZE       (64U)     // size declared by the default manifest
#define IMG_SLOTS      (8U)

#define KEY_PROD       (0x0007U)
#define KEY_TEST       (0x8001U)

// rot defaults: stored version 5, stored epoch 2
#define ROT_VERSION    (5U)
#define ROT_EPOCH      (2U)

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

// fake crypto: deterministic, NOT cryptography

// rolling byte hash: a change of any one byte always changes the result,
// because 31 is odd and so invertible modulo 256
static uint8_t roll(uint8_t seed, const uint8_t * data, size_t len)
{
    uint8_t h = seed;
    size_t  i;

    for (i = 0U; i < len; i++)
    {
        h = (uint8_t)(((uint32_t)h * 31U) + (uint32_t)data[i]);
    }
    return h;
}

// fake 32-byte digest: 16 bytes from the content, 16 bytes from the length
static void fake_digest(const uint8_t * data, size_t len, uint8_t * out)
{
    uint8_t h = roll(0x9EU, data, len);
    size_t  i;

    for (i = 0U; i < 16U; i++)
    {
        out[i] = (uint8_t)((uint32_t)h + (uint32_t)i);
    }
    for (i = 16U; i < 32U; i++)
    {
        out[i] = (uint8_t)((uint32_t)len + (uint32_t)i);
    }
}

// fake 64-byte signature: 32 bytes from content and key, 32 bytes from length
static void fake_mac(uint32_t key, const uint8_t * data, size_t len, uint8_t * out)
{
    uint8_t h = roll((uint8_t)((key ^ 0xA5U) & 0xFFU), data, len);
    size_t  i;

    for (i = 0U; i < 32U; i++)
    {
        out[i] = (uint8_t)((uint32_t)h + (uint32_t)i);
    }
    for (i = 32U; i < 64U; i++)
    {
        out[i] = (uint8_t)((uint32_t)len + (uint32_t)i);
    }
}

static uint32_t fake_handle(uint16_t key_id)
{
    return 0x1000U + (uint32_t)key_id;
}

// the fake Root of Trust and library
typedef struct
{
    // behaviour switches
    bool            key_found;
    bool            hash_ok;
    bool            load_ok;
    bool            commit_ok;
    fsb_lifecycle_t lifecycle;
    uint32_t        rot_version;
    uint32_t        rot_epoch;

    // observations
    uint32_t        n_lookup;
    uint32_t        n_verify;
    uint32_t        n_hash;
    uint32_t        n_load;
    uint32_t        n_commit;
    uint16_t        last_lookup_key_id;
    uint32_t        last_lookup_epoch;
    const uint8_t * last_verify_msg;
    size_t          last_verify_len;
    const uint8_t * last_verify_sig;
    const uint8_t * last_load_ptr;
    uint32_t        last_load_size;
    bool            hash_misuse;      // hash was not given the loaded bytes
    uint32_t        last_commit_version;
    uint32_t        last_commit_epoch;

    // fake image storage, the "execution memory"
    uint8_t         images[IMG_SLOTS][IMG_BYTES];
} fake_t;

static void fake_init(fake_t * f)
{
    size_t k;
    size_t j;

    (void)memset(f, 0, sizeof(*f));
    f->key_found   = true;
    f->hash_ok     = true;
    f->load_ok     = true;
    f->commit_ok   = true;
    f->lifecycle   = FSB_LIFECYCLE_PRODUCTION;
    f->rot_version = ROT_VERSION;
    f->rot_epoch   = ROT_EPOCH;
    for (k = 0U; k < IMG_SLOTS; k++)
    {
        for (j = 0U; j < IMG_BYTES; j++)
        {
            f->images[k][j] = (uint8_t)(((k * 37U) + (j * 3U) + 1U) & 0xFFU);
        }
    }
}

static bool f_lookup(void * ctx, uint16_t key_id, uint32_t key_epoch, fsb_key_handle_t * key_out)
{
    fake_t * f = (fake_t *)ctx;

    f->n_lookup++;
    f->last_lookup_key_id = key_id;
    f->last_lookup_epoch  = key_epoch;
    if (!f->key_found)
    {
        return false;
    }
    *key_out = fake_handle(key_id);
    return true;
}

static bool f_verify(void * ctx, fsb_key_handle_t key, const uint8_t * msg, size_t len,
                     const uint8_t * sig)
{
    fake_t * f = (fake_t *)ctx;
    uint8_t  expect[64];
    uint8_t  diff = 0U;
    size_t   i;

    f->n_verify++;
    f->last_verify_msg = msg;
    f->last_verify_len = len;
    f->last_verify_sig = sig;
    fake_mac(key, msg, len, expect);
    for (i = 0U; i < 64U; i++)
    {
        diff = (uint8_t)(diff | (uint8_t)(expect[i] ^ sig[i]));
    }
    return diff == 0U;
}

static bool f_hash(void * ctx, const uint8_t * data, size_t len, uint8_t * digest_out)
{
    fake_t * f = (fake_t *)ctx;

    f->n_hash++;
    if ((data != f->last_load_ptr) || (len != (size_t)f->last_load_size))
    {
        f->hash_misuse = true;
    }
    if (!f->hash_ok)
    {
        return false;
    }
    fake_digest(data, len, digest_out);
    return true;
}

static const uint8_t * f_load(void * ctx, uint16_t image_id, uint32_t size)
{
    fake_t * f = (fake_t *)ctx;

    f->n_load++;
    f->last_load_ptr  = NULL;
    f->last_load_size = 0U;
    if (!f->load_ok || (image_id < 1U) || (image_id > IMG_SLOTS) || (size > IMG_BYTES))
    {
        return NULL;
    }
    f->last_load_ptr  = f->images[image_id - 1U];
    f->last_load_size = size;
    return f->last_load_ptr;
}

static uint32_t f_get_version(void * ctx)
{
    return ((fake_t *)ctx)->rot_version;
}

static uint32_t f_get_epoch(void * ctx)
{
    return ((fake_t *)ctx)->rot_epoch;
}

static fsb_lifecycle_t f_get_lifecycle(void * ctx)
{
    return ((fake_t *)ctx)->lifecycle;
}

// models the hardware: a counter can never go down
static bool f_commit(void * ctx, uint32_t version, uint32_t epoch)
{
    fake_t * f = (fake_t *)ctx;

    f->n_commit++;
    f->last_commit_version = version;
    f->last_commit_epoch   = epoch;
    if (!f->commit_ok)
    {
        return false;
    }
    if ((version < f->rot_version) || (epoch < f->rot_epoch))
    {
        return false;
    }
    f->rot_version = version;
    f->rot_epoch   = epoch;
    return true;
}

static void make_ops(fake_t * f, fsb_ops_t * o)
{
    o->ctx                     = f;
    o->unit.target_id          = UNIT_TARGET;
    o->unit.hw_rev_min         = (uint16_t)UNIT_HW_MIN;
    o->unit.hw_rev_max         = (uint16_t)UNIT_HW_MAX;
    o->lookup_release_key      = f_lookup;
    o->verify_signature        = f_verify;
    o->hash_sha256             = f_hash;
    o->load_image              = f_load;
    o->rot_get_version_counter = f_get_version;
    o->rot_get_key_epoch       = f_get_epoch;
    o->rot_get_lifecycle       = f_get_lifecycle;
    o->rot_commit              = f_commit;
}

static fsb_reason_t run(fake_t * f, const uint8_t * buf, size_t len, fsb_result_t * r)
{
    fsb_ops_t ops;

    make_ops(f, &ops);
    return fsb_decide(&ops, buf, len, r);
}

static bool no_calls(const fake_t * f)
{
    return (f->n_lookup == 0U) && (f->n_verify == 0U) && (f->n_hash == 0U)
        && (f->n_load == 0U) && (f->n_commit == 0U);
}

static bool counters_are(const fake_t * f, uint32_t version, uint32_t epoch)
{
    return (f->rot_version == version) && (f->rot_epoch == epoch);
}


// manifest writer (independent of the code under test)
// offsets from security/signing/secure_boot.md, section 5
typedef struct
{
    uint32_t target_id;
    uint16_t hw_rev;
    uint16_t key_id;
    uint32_t key_epoch;
    uint32_t version;
    uint16_t image_count;
    uint16_t ids[8];
    uint32_t sizes[8];
    uint32_t hash_len[8];    // 0 = hash over the declared size
} mspec_t;

static void set16(uint8_t * b, size_t off, uint16_t v)
{
    b[off]      = (uint8_t)(v & 0xFFU);
    b[off + 1U] = (uint8_t)((v >> 8) & 0xFFU);
}

static void set32(uint8_t * b, size_t off, uint32_t v)
{
    b[off]      = (uint8_t)(v & 0xFFU);
    b[off + 1U] = (uint8_t)((v >> 8) & 0xFFU);
    b[off + 2U] = (uint8_t)((v >> 16) & 0xFFU);
    b[off + 3U] = (uint8_t)((v >> 24) & 0xFFU);
}

static void spec_default(mspec_t * s)
{
    uint16_t i;

    (void)memset(s, 0, sizeof(*s));
    s->target_id   = UNIT_TARGET;
    s->hw_rev      = 2U;
    s->key_id      = (uint16_t)KEY_PROD;
    s->key_epoch   = ROT_EPOCH;
    s->version     = ROT_VERSION + 1U;    // 6
    s->image_count = 3U;
    for (i = 0U; i < 8U; i++)
    {
        s->ids[i]   = (uint16_t)(i + 1U);
        s->sizes[i] = IMG_SIZE;
    }
}

// writes the manifest into buf (filler 0xAA beyond its end) and returns its length
static size_t build(uint8_t * buf, const mspec_t * s, const fake_t * f)
{
    size_t  n   = (size_t)s->image_count;
    size_t  len = 32U + (40U * n) + 64U;
    size_t  i;
    size_t  j;
    uint8_t digest[32];
    uint8_t mac[64];

    for (i = 0U; i < BUF_CAP; i++)
    {
        buf[i] = 0xAAU;
    }
    buf[0] = 0x46U;
    buf[1] = 0x53U;
    buf[2] = 0x4DU;
    buf[3] = 0x46U;
    set16(buf, 4U, 1U);
    set16(buf, 6U, 0U);
    set32(buf, 8U, (uint32_t)len);
    set32(buf, 12U, s->target_id);
    set16(buf, 16U, s->hw_rev);
    set16(buf, 18U, s->key_id);
    set32(buf, 20U, s->key_epoch);
    set32(buf, 24U, s->version);
    set16(buf, 28U, s->image_count);
    set16(buf, 30U, 0U);

    for (i = 0U; i < n; i++)
    {
        size_t   off  = 32U + (40U * i);
        uint32_t hlen = (s->hash_len[i] != 0U) ? s->hash_len[i] : s->sizes[i];

        if (hlen > IMG_BYTES)
        {
            hlen = IMG_BYTES;
        }
        set16(buf, off, s->ids[i]);
        set16(buf, off + 2U, 0U);
        set32(buf, off + 4U, s->sizes[i]);
        fake_digest(f->images[s->ids[i] - 1U], (size_t)hlen, digest);
        for (j = 0U; j < 32U; j++)
        {
            buf[off + 8U + j] = digest[j];
        }
    }

    fake_mac(fake_handle(s->key_id), buf, len - 64U, mac);
    for (j = 0U; j < 64U; j++)
    {
        buf[len - 64U + j] = mac[j];
    }
    return len;
}

// default 3-image manifest
static size_t fresh(uint8_t * buf, const fake_t * f)
{
    mspec_t s;

    spec_default(&s);
    return build(buf, &s, f);
}

static fsb_reason_t parse_after16(const fake_t * f, size_t off, uint16_t v)
{
    uint8_t        buf[BUF_CAP];
    size_t         len = fresh(buf, f);
    fsb_manifest_t m;

    set16(buf, off, v);
    return fsb_manifest_parse(buf, len, &m);
}

static fsb_reason_t parse_after32(const fake_t * f, size_t off, uint32_t v)
{
    uint8_t        buf[BUF_CAP];
    size_t         len = fresh(buf, f);
    fsb_manifest_t m;

    set32(buf, off, v);
    return fsb_manifest_parse(buf, len, &m);
}

static bool manifest_is_zero(const fsb_manifest_t * m)
{
    return (m->target_id == 0U) && (m->hw_rev == 0U) && (m->key_id == 0U)
        && (m->key_epoch == 0U) && (m->version_counter == 0U) && (m->image_count == 0U)
        && (m->signed_len == 0U) && (m->entries[0].image_id == 0U)
        && (m->entries[0].size == 0U) && (m->entries[0].digest[0] == 0U)
        && (m->entries[7].image_id == 0U) && (m->entries[7].size == 0U);
}

// group P: strict reader
static void test_parser_good(void)
{
    static const uint16_t counts[3] = { 1U, 3U, 8U };
    static const size_t   lens[3]   = { 136U, 216U, 416U };
    uint32_t              k;

    group("P-01 parser: good manifests of 1, 3 and 8 images");
    for (k = 0U; k < 3U; k++)
    {
        fake_t         f;
        mspec_t        s;
        uint8_t        buf[BUF_CAP];
        fsb_manifest_t m;
        size_t         len;
        uint16_t       i;

        fake_init(&f);
        spec_default(&s);
        s.image_count = counts[k];
        len = build(buf, &s, &f);
        CHECK(len == lens[k]);
        CHECK(fsb_manifest_parse(buf, len, &m) == FSB_REASON_OK);
        CHECK(m.target_id == UNIT_TARGET);
        CHECK(m.hw_rev == 2U);
        CHECK(m.key_id == KEY_PROD);
        CHECK(m.key_epoch == ROT_EPOCH);
        CHECK(m.version_counter == (ROT_VERSION + 1U));
        CHECK(m.image_count == counts[k]);
        CHECK(m.signed_len == (uint32_t)(lens[k] - 64U));
        for (i = 0U; i < counts[k]; i++)
        {
            uint8_t  d[32];
            uint32_t j;
            bool     same = true;

            fake_digest(f.images[i], IMG_SIZE, d);
            CHECK(m.entries[i].image_id == (uint16_t)(i + 1U));
            CHECK(m.entries[i].size == IMG_SIZE);
            for (j = 0U; j < 32U; j++)
            {
                if (m.entries[i].digest[j] != d[j])
                {
                    same = false;
                }
            }
            CHECK(same);
        }
    }
}

static void test_parser_length_sweep(void)
{
    fake_t  f;
    uint8_t buf[BUF_CAP];
    size_t  good_len;
    size_t  len;

    group("P-02 parser: every input length from 0 to 424, exact-size allocation");
    fake_init(&f);
    good_len = fresh(buf, &f);
    CHECK(good_len == 216U);
    for (len = 0U; len <= 424U; len++)
    {
        size_t         alloc = (len > 0U) ? len : 1U;
        uint8_t *      p     = (uint8_t *)malloc(alloc);
        fsb_manifest_t m;
        fsb_reason_t   r;

        if (p == NULL)
        {
            CHECK(false);
            continue;
        }
        (void)memcpy(p, buf, len);
        r = fsb_manifest_parse(p, len, &m);
        if (len == good_len)
        {
            CHECK(r == FSB_REASON_OK);
        }
        else
        {
            CHECK(r == FSB_REASON_MALFORMED);
        }
        free(p);
    }
}

static void test_parser_defects(void)
{
    fake_t         f;
    uint8_t        buf[BUF_CAP];
    size_t         len;
    fsb_manifest_t m;
    uint32_t       i;

    group("P-03 parser: field defects");
    fake_init(&f);

    // magic: each of the four bytes
    for (i = 0U; i < 4U; i++)
    {
        len = fresh(buf, &f);
        buf[i] ^= 0x01U;
        CHECK(fsb_manifest_parse(buf, len, &m) == FSB_REASON_MALFORMED);
    }

    // format_version (offset 4), flags (6), header reserved (30)
    CHECK(parse_after16(&f, 4U, 0U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 4U, 2U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 4U, 0x0100U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 6U, 1U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 6U, 0x8000U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 30U, 1U) == FSB_REASON_MALFORMED);

    // manifest_len (offset 8): off by one either way, zero, all ones
    CHECK(parse_after32(&f, 8U, 215U) == FSB_REASON_MALFORMED);
    CHECK(parse_after32(&f, 8U, 217U) == FSB_REASON_MALFORMED);
    CHECK(parse_after32(&f, 8U, 0U) == FSB_REASON_MALFORMED);
    CHECK(parse_after32(&f, 8U, 0xFFFFFFFFU) == FSB_REASON_MALFORMED);

    // image_count (offset 28): 0, 9, a wrong but plausible count, all ones
    CHECK(parse_after16(&f, 28U, 0U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 28U, 9U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 28U, 2U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 28U, 4U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 28U, 0xFFFFU) == FSB_REASON_MALFORMED);

    // entry 0: reserved (offset 34), id (32), size (36); entry 1 id (72)
    CHECK(parse_after16(&f, 34U, 1U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 32U, 0U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 32U, 9U) == FSB_REASON_MALFORMED);
    CHECK(parse_after16(&f, 72U, 1U) == FSB_REASON_MALFORMED);     // duplicate id
    CHECK(parse_after32(&f, 36U, 0U) == FSB_REASON_MALFORMED);
    CHECK(parse_after32(&f, 36U, 0x00400001U) == FSB_REASON_MALFORMED);

    // boundaries that must be ACCEPTED by the reader
    CHECK(parse_after32(&f, 36U, 1U) == FSB_REASON_OK);
    CHECK(parse_after32(&f, 36U, 0x00400000U) == FSB_REASON_OK);
    CHECK(parse_after16(&f, 32U, 8U) == FSB_REASON_OK);            // id 8 is known
    CHECK(parse_after16(&f, 32U, 1U) == FSB_REASON_OK);

    // the reader does not judge policy fields: those belong to the decision
    CHECK(parse_after32(&f, 12U, 0xDEADBEEFU) == FSB_REASON_OK);   // target_id
    CHECK(parse_after16(&f, 16U, 0xFFFFU) == FSB_REASON_OK);       // hw_rev
    CHECK(parse_after16(&f, 18U, 0U) == FSB_REASON_OK);            // key_id 0

    // an all-zero and an all-ones buffer of a plausible length
    (void)memset(buf, 0x00, sizeof(buf));
    CHECK(fsb_manifest_parse(buf, 216U, &m) == FSB_REASON_MALFORMED);
    (void)memset(buf, 0xFF, sizeof(buf));
    CHECK(fsb_manifest_parse(buf, 216U, &m) == FSB_REASON_MALFORMED);
}

static void test_parser_output_and_args(void)
{
    fake_t         f;
    uint8_t        buf[BUF_CAP];
    size_t         len;
    fsb_manifest_t m;

    group("P-04 parser: output zeroed on failure, NULL arguments");
    fake_init(&f);
    len = fresh(buf, &f);

    (void)memset(&m, 0xFF, sizeof(m));
    buf[0] ^= 0x01U;
    CHECK(fsb_manifest_parse(buf, len, &m) == FSB_REASON_MALFORMED);
    CHECK(manifest_is_zero(&m));

    (void)memset(&m, 0xFF, sizeof(m));
    CHECK(fsb_manifest_parse(buf, 0U, &m) == FSB_REASON_MALFORMED);
    CHECK(manifest_is_zero(&m));

    len = fresh(buf, &f);
    CHECK(fsb_manifest_parse(NULL, len, &m) == FSB_REASON_BAD_ARGUMENT);
    CHECK(fsb_manifest_parse(buf, len, NULL) == FSB_REASON_BAD_ARGUMENT);
}

// group D: decision
static void test_decide_good(void)
{
    static const uint16_t counts[3] = { 1U, 3U, 8U };
    uint32_t              k;

    group("D-01 decision: good manifests of 1, 3 and 8 images");
    for (k = 0U; k < 3U; k++)
    {
        fake_t       f;
        mspec_t      s;
        uint8_t      buf[BUF_CAP];
        size_t       len;
        fsb_result_t res;

        fake_init(&f);
        spec_default(&s);
        s.image_count = counts[k];
        len = build(buf, &s, &f);

        CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
        CHECK(res.reason == FSB_REASON_OK);
        CHECK(res.failed_check == 0U);
        CHECK(res.header_readable);
        CHECK(res.fields_authentic);
        CHECK(!res.counter_jump_warning);
        CHECK(res.bad_image_id == 0U);
        CHECK(res.key_id == KEY_PROD);
        CHECK(res.key_epoch == ROT_EPOCH);
        CHECK(res.version_counter == (ROT_VERSION + 1U));

        // each step ran once, every image was loaded and hashed
        CHECK(f.n_lookup == 1U);
        CHECK(f.n_verify == 1U);
        CHECK(f.n_load == counts[k]);
        CHECK(f.n_hash == counts[k]);
        // the decision never touches a counter (B4)
        CHECK(f.n_commit == 0U);
        CHECK(counters_are(&f, ROT_VERSION, ROT_EPOCH));
        // the signature was checked over the whole signed region, exactly
        CHECK(f.last_lookup_key_id == KEY_PROD);
        CHECK(f.last_lookup_epoch == ROT_EPOCH);
        CHECK(f.last_verify_msg == buf);
        CHECK(f.last_verify_len == (len - 64U));
        CHECK(f.last_verify_sig == &buf[len - 64U]);
        // C-3: the hashed bytes are the loaded bytes
        CHECK(!f.hash_misuse);
    }
}

static void test_decide_bad_argument(void)
{
    fake_t       f;
    mspec_t      s;
    uint8_t      buf[BUF_CAP];
    size_t       len;
    fsb_result_t res;
    fsb_ops_t    ops;
    fsb_ops_t    broken;

    group("D-02 decision: NULL and incomplete interface (check 0)");
    fake_init(&f);
    spec_default(&s);
    len = build(buf, &s, &f);
    make_ops(&f, &ops);

    CHECK(fsb_decide(NULL, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    CHECK(res.reason == FSB_REASON_BAD_ARGUMENT);
    CHECK(res.failed_check == 0U);
    CHECK(fsb_decide(&ops, NULL, len, &res) == FSB_REASON_BAD_ARGUMENT);
    CHECK(fsb_decide(&ops, buf, len, NULL) == FSB_REASON_BAD_ARGUMENT);

    broken = ops; broken.lookup_release_key = NULL;
    CHECK(fsb_decide(&broken, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    broken = ops; broken.verify_signature = NULL;
    CHECK(fsb_decide(&broken, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    broken = ops; broken.hash_sha256 = NULL;
    CHECK(fsb_decide(&broken, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    broken = ops; broken.load_image = NULL;
    CHECK(fsb_decide(&broken, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    broken = ops; broken.rot_get_version_counter = NULL;
    CHECK(fsb_decide(&broken, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    broken = ops; broken.rot_get_key_epoch = NULL;
    CHECK(fsb_decide(&broken, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    broken = ops; broken.rot_get_lifecycle = NULL;
    CHECK(fsb_decide(&broken, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    broken = ops; broken.rot_commit = NULL;
    CHECK(fsb_decide(&broken, buf, len, &res) == FSB_REASON_BAD_ARGUMENT);
    CHECK(res.failed_check == 0U);

    // nothing was called through any of the refused interfaces
    CHECK(no_calls(&f));
}

static void test_decide_malformed(void)
{
    fake_t       f;
    uint8_t      buf[BUF_CAP];
    size_t       len;
    fsb_result_t res;

    group("D-03 decision: malformed structure (check 1)");
    fake_init(&f);
    len = fresh(buf, &f);
    buf[2] ^= 0x01U;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_MALFORMED);
    CHECK(res.failed_check == 1U);
    CHECK(!res.header_readable);
    CHECK(!res.fields_authentic);
    CHECK(no_calls(&f));

    // too short and too long
    len = fresh(buf, &f);
    CHECK(run(&f, buf, len - 1U, &res) == FSB_REASON_MALFORMED);
    CHECK(run(&f, buf, len + 1U, &res) == FSB_REASON_MALFORMED);
    CHECK(run(&f, buf, 0U, &res) == FSB_REASON_MALFORMED);
    CHECK(no_calls(&f));
}

static void test_decide_key_checks(void)
{
    fake_t       f;
    mspec_t      s;
    uint8_t      buf[BUF_CAP];
    size_t       len;
    fsb_result_t res;

    group("D-04 decision: key id, test key in production, unknown key (checks 2 to 4)");

    // key id 0 (even though the fake would sign it)
    fake_init(&f);
    spec_default(&s);
    s.key_id = 0U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_BAD_KEY_ID);
    CHECK(res.failed_check == 2U);
    CHECK(res.header_readable);
    CHECK(!res.fields_authentic);
    CHECK(f.n_lookup == 0U);

    // test key, production lifecycle, signature "valid": refused before the signature
    fake_init(&f);
    spec_default(&s);
    s.key_id = (uint16_t)KEY_TEST;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_TEST_KEY_IN_PRODUCTION);
    CHECK(res.failed_check == 3U);
    CHECK(!res.fields_authentic);
    CHECK(f.n_lookup == 0U);
    CHECK(f.n_verify == 0U);

    // an undefined lifecycle value is treated as production
    f.lifecycle = (fsb_lifecycle_t)7;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_TEST_KEY_IN_PRODUCTION);

    // test key, test lifecycle: boots
    f.lifecycle = FSB_LIFECYCLE_TEST;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);

    // the key id boundary: 0x7FFF is a production key, 0x8000 is a test key
    fake_init(&f);
    spec_default(&s);
    s.key_id = 0x7FFFU;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
    fake_init(&f);
    s.key_id = 0x8000U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_TEST_KEY_IN_PRODUCTION);

    // unknown key
    fake_init(&f);
    spec_default(&s);
    len = build(buf, &s, &f);
    f.key_found = false;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_UNKNOWN_KEY);
    CHECK(res.failed_check == 4U);
    CHECK(f.n_lookup == 1U);
    CHECK(f.n_verify == 0U);
    CHECK(!res.fields_authentic);
}

static void test_decide_tamper(void)
{
    static const size_t targeted[7] = { 12U, 16U, 18U, 20U, 24U, 36U, 40U };
    fake_t       f;
    mspec_t      s;
    uint8_t      buf[BUF_CAP];
    uint8_t      tmp[BUF_CAP];
    size_t       len;
    size_t       i;
    uint32_t     bit;
    fsb_result_t res;
    bool         never_ok = true;

    group("D-05 decision: tampering (check 5)");
    fake_init(&f);
    spec_default(&s);
    len = build(buf, &s, &f);

    // targeted: a valid structure with one signed field changed is BAD_SIGNATURE,
    // not a policy error: policy fields are not trusted before the signature
    for (i = 0U; i < 7U; i++)
    {
        (void)memcpy(tmp, buf, len);
        tmp[targeted[i]] ^= 0x01U;
        CHECK(run(&f, tmp, len, &res) == FSB_REASON_BAD_SIGNATURE);
        CHECK(res.failed_check == 5U);
        CHECK(!res.fields_authentic);
    }

    // every byte of the signature, one bit each
    for (i = 0U; i < 64U; i++)
    {
        (void)memcpy(tmp, buf, len);
        tmp[len - 64U + i] ^= (uint8_t)(1U << (i % 8U));
        CHECK(run(&f, tmp, len, &res) == FSB_REASON_BAD_SIGNATURE);
    }

    // sweep: no single flipped bit anywhere in the manifest ever boots
    for (i = 0U; i < len; i++)
    {
        for (bit = 0U; bit < 8U; bit++)
        {
            (void)memcpy(tmp, buf, len);
            tmp[i] ^= (uint8_t)(1U << bit);
            if (run(&f, tmp, len, &res) == FSB_REASON_OK)
            {
                never_ok = false;
            }
        }
    }
    CHECK(never_ok);
    CHECK(f.n_commit == 0U);
    CHECK(counters_are(&f, ROT_VERSION, ROT_EPOCH));
    CHECK(!f.hash_misuse);
}

static void test_decide_policy(void)
{
    fake_t       f;
    mspec_t      s;
    uint8_t      buf[BUF_CAP];
    size_t       len;
    fsb_result_t res;

    group("D-06 decision: target, epoch, rollback (checks 6 to 8)");

    // wrong target (signed, so the signature is fine)
    fake_init(&f);
    spec_default(&s);
    s.target_id = UNIT_TARGET + 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_WRONG_TARGET);
    CHECK(res.failed_check == 6U);
    CHECK(res.fields_authentic);
    CHECK(f.n_load == 0U);

    // hardware revision: 0 and 4 refused, 1 and 3 accepted
    fake_init(&f);
    spec_default(&s);
    s.hw_rev = 0U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_WRONG_TARGET);
    s.hw_rev = 4U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_WRONG_TARGET);
    s.hw_rev = 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
    s.hw_rev = 3U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);

    // key epoch: below refused, equal and above accepted
    fake_init(&f);
    spec_default(&s);
    s.key_epoch = ROT_EPOCH - 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_KEY_REVOKED);
    CHECK(res.failed_check == 7U);
    CHECK(res.fields_authentic);
    s.key_epoch = ROT_EPOCH;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
    s.key_epoch = ROT_EPOCH + 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);

    // version: below refused; equal, +1 accepted without warning; +2 and more with warning
    fake_init(&f);
    spec_default(&s);
    s.version = ROT_VERSION - 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_ROLLBACK);
    CHECK(res.failed_check == 8U);
    CHECK(res.fields_authentic);
    CHECK(f.n_load == 0U);

    s.version = ROT_VERSION;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
    CHECK(!res.counter_jump_warning);

    s.version = ROT_VERSION + 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
    CHECK(!res.counter_jump_warning);

    s.version = ROT_VERSION + 2U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
    CHECK(res.counter_jump_warning);

    s.version = 0xFFFFFFFFU;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
    CHECK(res.counter_jump_warning);

    // the stored counter at its maximum: no overflow, no warning, accepted
    fake_init(&f);
    f.rot_version = 0xFFFFFFFFU;
    spec_default(&s);
    s.version = 0xFFFFFFFFU;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);
    CHECK(!res.counter_jump_warning);

    // stored counter zero, manifest zero
    fake_init(&f);
    f.rot_version = 0U;
    spec_default(&s);
    s.version = 0U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_OK);

    // a warning never changes a counter
    CHECK(f.n_commit == 0U);
}

static void test_decide_images(void)
{
    fake_t       f;
    mspec_t      s;
    uint8_t      buf[BUF_CAP];
    size_t       len;
    fsb_result_t res;
    uint32_t     p;

    group("D-07 decision: images (check 9)");

    // one byte of image p changed: that image is reported, earlier ones were hashed
    for (p = 0U; p < 3U; p++)
    {
        fake_init(&f);
        spec_default(&s);
        len = build(buf, &s, &f);
        f.images[s.ids[p] - 1U][5] ^= 0x01U;
        CHECK(run(&f, buf, len, &res) == FSB_REASON_IMAGE_MISMATCH);
        CHECK(res.failed_check == 9U);
        CHECK(res.fields_authentic);
        CHECK(res.bad_image_id == s.ids[p]);
        CHECK(f.n_load == (p + 1U));
        CHECK(f.n_hash == (p + 1U));
        CHECK(f.n_commit == 0U);
        CHECK(counters_are(&f, ROT_VERSION, ROT_EPOCH));
    }

    // the last byte of an image changed
    fake_init(&f);
    spec_default(&s);
    len = build(buf, &s, &f);
    f.images[0][IMG_SIZE - 1U] ^= 0x80U;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_IMAGE_MISMATCH);
    CHECK(res.bad_image_id == s.ids[0]);

    // size one too large and one too small compared with the digest
    fake_init(&f);
    spec_default(&s);
    s.hash_len[1] = IMG_SIZE - 1U;     // digest over 63 bytes, manifest says 64
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_IMAGE_MISMATCH);
    CHECK(res.bad_image_id == s.ids[1]);
    spec_default(&s);
    s.hash_len[2] = IMG_SIZE + 1U;     // digest over 65 bytes, manifest says 64
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_IMAGE_MISMATCH);
    CHECK(res.bad_image_id == s.ids[2]);

    // the load step fails: nothing is hashed
    fake_init(&f);
    spec_default(&s);
    len = build(buf, &s, &f);
    f.load_ok = false;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_IMAGE_MISMATCH);
    CHECK(res.bad_image_id == s.ids[0]);
    CHECK(f.n_load == 1U);
    CHECK(f.n_hash == 0U);

    // the hash step fails
    fake_init(&f);
    spec_default(&s);
    len = build(buf, &s, &f);
    f.hash_ok = false;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_IMAGE_MISMATCH);
    CHECK(res.bad_image_id == s.ids[0]);
    CHECK(f.n_load == 1U);
    CHECK(f.n_hash == 1U);

    // a size larger than the fake slot cannot be loaded
    fake_init(&f);
    spec_default(&s);
    s.sizes[0] = IMG_BYTES + 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_IMAGE_MISMATCH);
}

static void test_decide_order(void)
{
    fake_t       f;
    mspec_t      s;
    uint8_t      buf[BUF_CAP];
    size_t       len;
    fsb_result_t res;

    group("D-08 decision: the first failing check is the one reported");

    // rollback AND corrupted image: rollback (8) before images (9)
    fake_init(&f);
    spec_default(&s);
    s.version = ROT_VERSION - 1U;
    len = build(buf, &s, &f);
    f.images[0][3] ^= 0x01U;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_ROLLBACK);
    CHECK(f.n_load == 0U);

    // wrong target AND rollback: target (6) before rollback (8)
    fake_init(&f);
    spec_default(&s);
    s.target_id = UNIT_TARGET + 1U;
    s.version   = ROT_VERSION - 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_WRONG_TARGET);

    // revoked epoch AND rollback: epoch (7) before rollback (8)
    fake_init(&f);
    spec_default(&s);
    s.key_epoch = ROT_EPOCH - 1U;
    s.version   = ROT_VERSION - 1U;
    len = build(buf, &s, &f);
    CHECK(run(&f, buf, len, &res) == FSB_REASON_KEY_REVOKED);

    // test key in production AND unknown key: test key (3) before lookup (4)
    fake_init(&f);
    spec_default(&s);
    s.key_id = (uint16_t)KEY_TEST;
    len = build(buf, &s, &f);
    f.key_found = false;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_TEST_KEY_IN_PRODUCTION);
    CHECK(f.n_lookup == 0U);

    // key id 0 AND unknown key: key id (2) before lookup (4)
    fake_init(&f);
    spec_default(&s);
    s.key_id = 0U;
    len = build(buf, &s, &f);
    f.key_found = false;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_BAD_KEY_ID);

    // tampered target AND rollback: the signature (5) is checked before both
    fake_init(&f);
    spec_default(&s);
    s.version = ROT_VERSION - 1U;
    len = build(buf, &s, &f);
    buf[12] ^= 0x01U;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_BAD_SIGNATURE);

    // malformed AND test key: structure (1) first
    fake_init(&f);
    spec_default(&s);
    s.key_id = (uint16_t)KEY_TEST;
    len = build(buf, &s, &f);
    buf[0] ^= 0x01U;
    CHECK(run(&f, buf, len, &res) == FSB_REASON_MALFORMED);
    CHECK(res.failed_check == 1U);
}

// group C: commit
static void test_commit(void)
{
    fake_t       f;
    mspec_t      s;
    uint8_t      buf[BUF_CAP];
    size_t       len;
    fsb_result_t res;
    fsb_result_t forged;
    fsb_ops_t    ops;
    fsb_ops_t    broken;

    group("C-01 commit: ground only, clean boot only, counters never go down");
    fake_init(&f);
    spec_default(&s);
    len = build(buf, &s, &f);
    make_ops(&f, &ops);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_OK);

    // not on the ground with the session armed
    CHECK(fsb_commit(&ops, &res, false) == FSB_COMMIT_NOT_ALLOWED);
    CHECK(f.n_commit == 0U);
    CHECK(counters_are(&f, ROT_VERSION, ROT_EPOCH));

    // the clean commit
    CHECK(fsb_commit(&ops, &res, true) == FSB_COMMIT_DONE);
    CHECK(f.n_commit == 1U);
    CHECK(f.last_commit_version == (ROT_VERSION + 1U));
    CHECK(f.last_commit_epoch == ROT_EPOCH);
    CHECK(counters_are(&f, ROT_VERSION + 1U, ROT_EPOCH));

    // a result whose signature never verified
    forged = res;
    forged.fields_authentic = false;
    CHECK(fsb_commit(&ops, &forged, true) == FSB_COMMIT_NOT_ALLOWED);

    // a result that is not a clean boot
    forged = res;
    forged.reason = FSB_REASON_ROLLBACK;
    CHECK(fsb_commit(&ops, &forged, true) == FSB_COMMIT_NOT_ALLOWED);
    forged = res;
    forged.reason = FSB_REASON_IMAGE_MISMATCH;
    CHECK(fsb_commit(&ops, &forged, true) == FSB_COMMIT_NOT_ALLOWED);

    // an altered result that would lower a counter
    forged = res;
    forged.version_counter = ROT_VERSION;
    CHECK(fsb_commit(&ops, &forged, true) == FSB_COMMIT_NOT_ALLOWED);
    forged = res;
    forged.key_epoch = ROT_EPOCH - 1U;
    CHECK(fsb_commit(&ops, &forged, true) == FSB_COMMIT_NOT_ALLOWED);
    CHECK(f.n_commit == 1U);
    CHECK(counters_are(&f, ROT_VERSION + 1U, ROT_EPOCH));

    // the Root of Trust fails
    spec_default(&s);
    s.version = ROT_VERSION + 2U;
    len = build(buf, &s, &f);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_OK);
    f.commit_ok = false;
    CHECK(fsb_commit(&ops, &res, true) == FSB_COMMIT_ROT_FAILED);
    CHECK(counters_are(&f, ROT_VERSION + 1U, ROT_EPOCH));
    f.commit_ok = true;

    // NULL and incomplete interface
    CHECK(fsb_commit(NULL, &res, true) == FSB_COMMIT_NOT_ALLOWED);
    CHECK(fsb_commit(&ops, NULL, true) == FSB_COMMIT_NOT_ALLOWED);
    broken = ops;
    broken.rot_commit = NULL;
    CHECK(fsb_commit(&broken, &res, true) == FSB_COMMIT_NOT_ALLOWED);
    broken = ops;
    broken.rot_get_key_epoch = NULL;
    CHECK(fsb_commit(&broken, &res, true) == FSB_COMMIT_NOT_ALLOWED);
}

// group S: scenario
static void test_scenario_rollback(void)
{
    fake_t       f;
    mspec_t      s;
    uint8_t      buf[BUF_CAP];
    size_t       len;
    fsb_result_t res;
    fsb_ops_t    ops;

    group("S-01 scenario: install version 6, commit, then try version 5 (T-09)");
    fake_init(&f);                       // stored version 5, epoch 2
    make_ops(&f, &ops);

    // install version 6: decide, run, commit
    spec_default(&s);
    s.version = 6U;
    len = build(buf, &s, &f);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_OK);
    CHECK(counters_are(&f, 5U, 2U));     // not moved by the decision
    CHECK(fsb_commit(&ops, &res, true) == FSB_COMMIT_DONE);
    CHECK(counters_are(&f, 6U, 2U));

    // an old, validly signed version 5 is now refused
    s.version = 5U;
    len = build(buf, &s, &f);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_ROLLBACK);
    CHECK(counters_are(&f, 6U, 2U));

    // version 6 boots again (equal is allowed)
    s.version = 6U;
    len = build(buf, &s, &f);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_OK);
    CHECK(!res.counter_jump_warning);

    // version 7: no warning; version 9: warning; neither moves a counter
    s.version = 7U;
    len = build(buf, &s, &f);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_OK);
    CHECK(!res.counter_jump_warning);
    s.version = 9U;
    len = build(buf, &s, &f);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_OK);
    CHECK(res.counter_jump_warning);
    CHECK(counters_are(&f, 6U, 2U));

    // the revoked-key path: raise the epoch, then an old-epoch manifest is refused
    s.version   = 9U;
    s.key_epoch = 3U;
    len = build(buf, &s, &f);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_OK);
    CHECK(fsb_commit(&ops, &res, true) == FSB_COMMIT_DONE);
    CHECK(counters_are(&f, 9U, 3U));
    s.version   = 10U;
    s.key_epoch = 2U;
    len = build(buf, &s, &f);
    CHECK(fsb_decide(&ops, buf, len, &res) == FSB_REASON_KEY_REVOKED);
    CHECK(counters_are(&f, 9U, 3U));
}

// main
int main(void)
{
    printf("test_secure_boot\n");

    test_parser_good();
    test_parser_length_sweep();
    test_parser_defects();
    test_parser_output_and_args();

    test_decide_good();
    test_decide_bad_argument();
    test_decide_malformed();
    test_decide_key_checks();
    test_decide_tamper();
    test_decide_policy();
    test_decide_images();
    test_decide_order();

    test_commit();
    test_scenario_rollback();

    printf("\npassed %u, failed %u\n", (unsigned)(g_run - g_failed), (unsigned)g_failed);
    return (g_failed == 0U) ? 0 : 1;
}