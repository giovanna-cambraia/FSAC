# FSAC: Secure Boot, Chain of Trust and Key Management

| Item | Value |
| :--- | :--- |
| File | `security/signing/secure_boot.md` |
| Measures implemented | SM-01 (secure boot chain), SM-02 (signed updates, anti-rollback), SM-12 (key management) |
| Threats covered | T-08, T-09, T-13, T-23, T-24 (`TARA.md`) |
| Requirements | `SECR-BOOT-0001`, `SECR-BOOT-0002`, `SECR-TARA-0003`, new ones in section 11 |
| Implemented by | `software/hal_c/src/secure_boot/fsac_secure_boot.c` (strict manifest reader and boot decision) |
| Decision | ADR-013 (section 12) |
| Status | Design of a learning and portfolio project. **No cryptographic primitive is written in this repository.** Signature verification and hashing are provided by a vetted library or by the hardware Root of Trust, behind the interface of section 8. |

## 1. Purpose and where this runs

Secure boot answers one question: *is every executable image and every parameter file that is about to run exactly what an authorised party signed, and is it new enough?*

It runs **on the ground, before flight**. This is the only place where the governing principle (`security_architecture.md`, section 1) allows a security check to *refuse*: refusing to start on the ground is safe, refusing in flight is not.

| Moment | Behaviour on verification failure |
| :--- | :--- |
| Power-up on the ground | Refuse to start this LRU. It is lost like any fail-silent LRU (ADR-001). The other two LRUs are unaffected, and the mode logic sees `Healthy_Lrus = 2` (Degraded_1) |
| Installation of a new image on the ground | Refuse to install. The previously installed image stays active |
| Restart in flight (reset after a power glitch) | The same check runs on the image that is already installed and committed. If it passes, the LRU rejoins. If it fails, the LRU stays down, like any lost LRU. Nothing else changes |

A restart in flight is not a new image: it re-verifies bytes that passed the same check on the ground. The check never runs on mission data, and an attacker on the mission bus cannot reach it (zone Z2 has no path to the boot chain).

## 2. Chain of trust
Hardware Root of Trust (immutable: ROM + one-time fuses)
| holds: hash of the ROOT public key (fuses), monotonic counters, lifecycle state
| verifies, with the root key:
v
Stage 1: Loader (signed; verified by ROM)
| verifies, with a RELEASE key certified by the root:
v
Signed manifest ---- lists ----> Stage 2: Hypervisor image
Stage 3: Partition images (P1..P8, per lane)
Parameter file (A3)
| every listed image is hashed and compared before it runs
v
Hypervisor starts partitions (only after the whole manifest verified)

| Rule | Statement |
| :-: | :--- |
| C-1 | **Each stage verifies the next before handing over control.** No stage runs code it has not verified. |
| C-2 | **The chain stops at the first failure.** There is no "continue and report". |
| C-3 | **Verify the bytes that will execute.** The image is copied to its execution memory first, then hashed there. Hashing an external copy and then loading a different read of it is a time-of-check to time-of-use hole. |
| C-4 | **No partial start.** The hypervisor starts partitions only after the manifest and every image in it verified. Starting P1 while P3 failed is not allowed. |
| C-5 | **The ROM is the only unconditional trust.** Everything else, including the loader, is verified. |

## 3. Key hierarchy

| Key | Where the private key lives | Where the public key (or its hash) lives | Signs | Lifetime |
| :--- | :--- | :--- | :--- | :--- |
| **Root key** | Offline, in a hardware security module under dual control | Hash in the device fuses, full key in the loader certificate chain | Release-key certificates and the loader | Very long. Changing it needs new hardware |
| **Release key** (one or more) | Signing facility | Certificate signed by the root key, carried in the manifest bundle | Manifests | Per release series. Revoked by raising the key epoch |
| **Test keys** | Anywhere (they are not secret) | Compiled only into test builds | Test manifests | Short. Never valid in production |
| **Device keys** | Root of Trust only, never exported | Root of Trust | CCDL authentication and device identity (SM-07), outside this document | Per unit |

Rules:

| Rule | Statement |
| :-: | :--- |
| K-1 | **The repository contains no private signing key**, ever. Test keys are not in the repository either; a script generates them locally, and their private halves are not committed. |
| K-2 | **The device holds public keys only.** The only secret on the unit is the device key, and it never leaves the Root of Trust. |
| K-3 | **Test keys are marked by range** (section 5.1): `key_id` with the high bit set. A production-configured boot refuses them. |
| K-4 | **Dual control for the root key.** Two people are needed to use it. Its use is logged. |
| K-5 | **Revocation is by counter, not by list.** Raising the key epoch invalidates every release key of an older epoch. No revocation list has to be fetched, which matters because the aircraft is not online. |

This is a design for a learning project. A real programme needs a controlled signing facility and a key ceremony procedure. Residual risk RR-03 of the TARA records this.

## 4. Anti-rollback counters

The Root of Trust holds two monotonic counters. "Monotonic" means they can be incremented, never decremented, and the hardware enforces it.

| Counter | Meaning | Compared with |
| :--- | :--- | :--- |
| `rot_version_counter` | Newest software version ever committed on this unit | `manifest.version_counter` |
| `rot_key_epoch` | Newest key epoch ever committed | `manifest.key_epoch` |

### 4.1 Rules

| Rule | Statement |
| :-: | :--- |
| AR-1 | A manifest is refused if `version_counter < rot_version_counter`. Equal is allowed: it is the same version booting again. |
| AR-2 | A manifest is refused if `key_epoch < rot_key_epoch`. |
| AR-3 | **A counter advances only at commit**, never at verification. Commit happens once, on the ground, after the new image verified and the LRU reached its ready state (section 7). |
| AR-4 | A counter advances to the manifest's value at commit. A `version_counter` more than one above the stored value is logged as a warning (section 6.4) and does not refuse the boot. |
| AR-5 | Commit needs weight-on-wheels and the maintenance switch armed (SM-05). It cannot happen in flight. |

Why commit is separate: if the counter advanced at verification, a power loss between "verify" and "reach ready" could leave the unit with a counter ahead of what it can run. Splitting the steps means the counter only moves after the unit has actually run the new software on the ground.

### 4.2 Two slots

Each image has two storage slots, A and B. An installation writes the inactive slot. The active slot changes only after the new slot verified. Until commit, the previous slot is still valid, so a failed installation never leaves the unit without a bootable image.

The previous slot is allowed to boot because its counter equals `rot_version_counter` (it was committed). It is not a downgrade: AR-1 still holds.

## 5. Manifest format

The manifest is a fixed binary layout. All multi-byte integers are **little-endian**. All offsets are in bytes from the start of the manifest. There are no optional fields, no variable-length strings and no padding bytes that carry meaning.

### 5.1 Header (32 bytes, offset 0)

| Offset | Size | Field | Rule |
| :-: | :-: | :--- | :--- |
| 0 | 4 | `magic` | The four bytes `F`, `S`, `M`, `F` (0x46 0x53 0x4D 0x46) in this order |
| 4 | 2 | `format_version` | Exactly `1`. Any other value is refused |
| 6 | 2 | `flags` | Exactly `0`. Reserved |
| 8 | 4 | `manifest_len` | Must equal `32 + 40 * image_count + 64` exactly |
| 12 | 4 | `target_id` | Must equal the unit's target identity (aircraft family, LRU type) |
| 16 | 2 | `hw_rev` | Must be in the set of hardware revisions this loader supports |
| 18 | 2 | `key_id` | Identifies the release key. `0` is invalid. High bit set (0x8000 to 0xFFFF) marks a **test key** |
| 20 | 4 | `key_epoch` | See AR-2 |
| 24 | 4 | `version_counter` | See AR-1 |
| 28 | 2 | `image_count` | From 1 to 8 inclusive |
| 30 | 2 | `reserved` | Exactly `0` |

### 5.2 Image entry (40 bytes each, starting at offset 32)

| Offset in entry | Size | Field | Rule |
| :-: | :-: | :--- | :--- |
| 0 | 2 | `image_id` | Must be a known ID (section 5.4). No duplicates inside one manifest |
| 2 | 2 | `reserved` | Exactly `0` |
| 4 | 4 | `size` | From 1 to the maximum size of that image's slot |
| 8 | 32 | `digest` | SHA-256 of the image bytes |

### 5.3 Signature (64 bytes, at the end)

| Offset | Size | Field | Rule |
| :-: | :-: | :--- | :--- |
| `manifest_len - 64` | 64 | `signature` | Ed25519 signature over the bytes from offset 0 up to (not including) the signature |

### 5.4 Sizes and image IDs

| Images | Manifest bytes |
| :-: | :-: |
| 1 | 136 |
| 3 | 216 |
| 8 (maximum) | 416 |

Formula: `32 + 40 * N + 64`. Illustrative image IDs (placeholder, to be aligned with the real partition table):

| `image_id` | Content |
| :-: | :--- |
| 1 | Hypervisor |
| 2 | Partitions of the command lane |
| 3 | Partitions of the monitor lane |
| 4 | Parameter file (A3) |

### 5.5 What the strict reader enforces

The reader is the first code that touches untrusted bytes, so it is as strict as the gateway parser:

1. The buffer length equals `manifest_len` exactly (not "at least").
2. `manifest_len` is consistent with `image_count` *before* any entry is read, so no read goes past the buffer.
3. Magic, format version, flags and reserved fields have exactly their defined values.
4. Every enumerated field is in its range; image IDs are known and unique.
5. There are **no trailing bytes** after the signature.
6. **The signature is checked before any field is trusted for a decision.** The reader parses to *locate* the signed region and the signature, but the decision logic uses fields only after verification. (The structural checks above are done first because they are what make it safe to hand a bounded buffer to the verifier.)

A parser that tolerates a manifest it does not fully understand is a parser with a larger attack surface. The reader rejects, as a whole, anything that is not exactly this format.

## 6. Boot decision

### 6.1 Order of checks (the first failure wins)

| Order | Check | Refusal reason | Related threat |
| :-: | :--- | :--- | :-: |
| 0 | Caller passed a NULL or incomplete interface | `BAD_ARGUMENT` | |
| 1 | Buffer length and structural shape (section 5.5, items 1 to 5) | `MALFORMED` | T-08 |
| 2 | `key_id` is valid (not 0) | `BAD_KEY_ID` | T-24 |
| 3 | Lifecycle is production and `key_id` is a test key | `TEST_KEY_IN_PRODUCTION` | T-24 |
| 4 | Release key found for `(key_id, key_epoch)` and its certificate chain valid | `UNKNOWN_KEY` | T-23 |
| 5 | Ed25519 signature verifies | `BAD_SIGNATURE` | T-08 |
| 6 | `target_id` and `hw_rev` match this unit | `WRONG_TARGET` | T-13 |
| 7 | `key_epoch >= rot_key_epoch` | `KEY_REVOKED` | T-23 |
| 8 | `version_counter >= rot_version_counter` | `ROLLBACK` | T-09 |
| 9 | Each listed image: size within slot, then copied to execution memory, then SHA-256 equals `digest` | `IMAGE_MISMATCH` | T-08, T-21 |

Why this order: structure first so nothing reads out of bounds; then the cheapest checks that reject test keys and unknown keys; then the signature; then policy checks (target, epoch, counter) that rely on fields which are now authentic; last, the expensive hashing of images.

Checks 6, 7 and 8 come after the signature on purpose: before the signature verifies, those fields are attacker-controlled and must not drive a decision.

### 6.2 Outcomes

| Outcome | Meaning | Action |
| :--- | :--- | :--- |
| `BOOT_OK` | All nine checks passed | Hand over to the hypervisor; the unit goes to ready |
| `BOOT_REFUSED(reason)` | Any check failed | Do not start; record the reason; the LRU stays down |

There is no third outcome such as "boot with warnings". A boot is allowed or refused.

### 6.3 What is recorded on refusal

A fixed-size record: the reason code, the order of the failed check, and the manifest's `version_counter` and `key_id` *if the structure was valid enough to read them*. Fields from an unverified manifest are marked as unverified in the record. The record goes into the tamper-evident log (SM-09), rate limited.

### 6.4 Warning on a counter jump (AR-4)

If a verified manifest has `version_counter` more than one step above `rot_version_counter`, the boot is still allowed (a legitimate release may skip numbers), but the log records a warning. This catches an attempt to burn the counter range. It never refuses a boot.

## 7. Installation and commit sequence (ground only)

1. Maintenance session is open (SM-05: weight-on-wheels, switch armed).
2. The new manifest and images are received and written into the **inactive** slot.
3. The full boot decision (section 6) runs on the inactive slot, **without** advancing any counter.
4. If it passes, the active slot flips to the new slot and the unit starts it.
5. When the unit reaches its ready state on the ground, the maintenance session **commits**: `rot_version_counter` and `rot_key_epoch` advance to the manifest's values.
6. If the unit does not reach ready, the previous slot becomes active again. The counters have not moved.

## 8. Interface to the Root of Trust and the crypto library

The boot code never contains cryptography. It calls this small interface. In tests it is replaced by a fake that can be told to return any answer, which is how every decision path is exercised (file 7 of this part).

| Function | Purpose | Result |
| :--- | :--- | :--- |
| `verify_signature(key, message, length, signature)` | Check an Ed25519 signature | `OK` or `FAIL` |
| `hash_sha256(data, length, digest_out)` | SHA-256 | the 32-byte digest |
| `lookup_release_key(key_id, key_epoch)` | Find the release key and validate its certificate | key handle or `NOT_FOUND` |
| `rot_get_version_counter()` | Read the committed version counter | integer |
| `rot_get_key_epoch()` | Read the committed key epoch | integer |
| `rot_get_lifecycle()` | `TEST` or `PRODUCTION` (cannot go back to `TEST`) | enumeration |
| `rot_commit(version_counter, key_epoch)` | Advance both counters (ground only) | `OK` or `FAIL` |

Requirements on the real library (the boot code cannot check these, so they are written down):

| Req | Statement |
| :-: | :--- |
| L-1 | The Ed25519 verification **rejects non-canonical signatures** and keys of small order. A library that accepts several encodings of one signature breaks "one manifest, one signature". |
| L-2 | `verify_signature` returns `FAIL` for any malformed input, including a wrong length, instead of undefined behaviour. |
| L-3 | The library is vetted, and its version is pinned by hash (SM-11). |

## 9. Test keys and the production switch

| Question | Answer |
| :--- | :--- |
| What marks a test key? | `key_id >= 0x8000` |
| What stops it in production? | Check 3 of section 6.1, which uses the lifecycle of the Root of Trust |
| Can lifecycle go from production back to test? | No. The hardware does not allow it |
| Can a test build accept production keys? | Yes. A test unit can run production-signed images; that is not an attack |
| Who tests this? | A boot test with a fake verifier that returns "signature OK" for a test-key manifest, and checks that production lifecycle still refuses (SECR-TARA-0003) |

The check does not depend on the signature. A test-key manifest is refused in production even if the signature is valid, because *validity under a test key proves nothing*.

## 10. Verification (feeds the boot test)

| Check | Threat | Expected result |
| :--- | :-: | :--- |
| A good manifest of 1, 3 and 8 images | | `BOOT_OK` |
| Length off by one, either way; trailing byte; length field lying about `image_count` | T-08 | `MALFORMED`, no read past the buffer |
| Wrong magic, format version, non-zero flags, non-zero reserved | T-08 | `MALFORMED` |
| `image_count` of 0 and 9; duplicate image ID; unknown image ID | T-08 | `MALFORMED` |
| `key_id` 0 | T-24 | `BAD_KEY_ID` |
| Test key in production lifecycle, signature "valid" | T-24 | `TEST_KEY_IN_PRODUCTION` |
| Test key in test lifecycle | | `BOOT_OK` |
| Key not found | T-23 | `UNKNOWN_KEY` |
| One flipped bit anywhere in the signed region; one flipped bit in the signature | T-08 | `BAD_SIGNATURE` |
| Wrong `target_id`; unsupported `hw_rev` | T-13 | `WRONG_TARGET` |
| `key_epoch` below the stored epoch | T-23 | `KEY_REVOKED` |
| `version_counter` below, equal to, and above the stored value | T-09 | `ROLLBACK`, `BOOT_OK`, `BOOT_OK` with a warning if more than one step above |
| Image one byte too large, one byte different | T-08 | `IMAGE_MISMATCH` |
| Order of reasons: a manifest with two defects | | The earlier check in section 6.1 is reported |
| Boot refusal leaves counters unchanged | T-09 | Counters identical before and after |
| Commit only through `rot_commit` and only after a successful decision | T-09 | Counters advance once |

## 11. Requirements (placeholders to add to `docs/03_requirements/SEC/`)

| ID | Statement |
| :--- | :--- |
| SECR-BOOT-0001 | Every executable image shall be verified against a signed manifest before it runs. |
| SECR-BOOT-0002 | An image whose version counter is below the stored counter shall be refused. |
| SECR-BOOT-0003 | The manifest reader shall accept only a buffer that has exactly the format of section 5, and shall refuse any other without reading outside the buffer. |
| SECR-BOOT-0004 | No manifest field shall cause an acceptance or a counter change until the signature has verified. Fields read earlier may only cause a refusal or select the verification key. |
| SECR-BOOT-0005 | The boot shall verify the bytes that will execute, after copying them to execution memory. |
| SECR-BOOT-0006 | A counter shall advance only at commit, on the ground, and never by a failed or unverified boot. |
| SECR-BOOT-0007 | The boot decision shall have exactly two outcomes, boot or refuse, and no partial start. |
| SECR-BOOT-0008 | A production-lifecycle unit shall refuse a manifest signed with a test key, whatever the signature result. |

## 12. ADR-013: signature scheme

| Item | Content |
| :--- | :--- |
| Decision | Manifests are signed with **Ed25519**. Image digests are SHA-256. |
| Reasons | Ed25519 has a small, fixed interface (32-byte public key, 64-byte signature) with few parameters to choose wrongly; this keeps the manifest layout fixed-size and the reader simple. |
| Alternative | ECDSA P-384 (listed first in `security_architecture.md`, SM-02). It is common in certified hardware and may be what a real supplier's Root of Trust offers. |
| Consequence of the alternative | Only the signature field (and the key size) would change. The manifest layout would grow: P-384 signatures are 96 bytes in raw form, so the manifest size formula becomes `32 + 40 * N + 96`. The boot code calls `verify_signature` and does not know the scheme, so the interface of section 8 stays the same. |
| Status | Accepted for the learning project. Revisit when a hardware Root of Trust is chosen. |

## 13. What this document does not cover

1. **The hardware Root of Trust itself.** Its fuses, its counter hardware and its resistance to glitching are supplier and DO-254 matters (TARA, RR-01).
2. **The cryptographic library.** Section 8 states what it must do; nothing here proves that it does.
3. **Runtime integrity after boot.** The chain verifies at start. It does not detect a later modification of memory (that is partition isolation, SM-03).
4. **Key ceremony and facility procedures.** Rules K-1 to K-5 are principles, not a procedure.
5. **Boot time budget.** Hashing images takes time, and a restart in flight has a time limit. The time of the check has not been measured.
6. **The bytes of the loader and ROM** (stage 1 and the ROM are outside this repository's scope).