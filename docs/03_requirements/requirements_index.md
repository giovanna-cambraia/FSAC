
# FSAC: Requirements Index

| Item | Value |
| :--- | :--- |
| File | `docs/03_requirements/requirements_index.md` |
| Purpose | The ID scheme, the ID ranges in use, and the full list of security requirements |
| Consumers | The trace tool (Part 6, file 4), the compliance matrix (file 5), every file header |
| Status | **Index of a learning and portfolio project. Most statements are placeholders.** Section 6 lists the ranges whose statements have not been written down yet. |

## 1. Purpose

Every source file header cites requirement IDs. Until now those IDs lived only in headers and in the ADRs. This file is the one place that says which IDs exist, what range each area uses, and which of them already have a statement, a verification method and a piece of evidence.

It does not replace the requirement documents (`SYS`, `HLR`, `LLR`). Those do not exist yet. This file is what they will be written against.

## 2. ID scheme

Form: `<LEVEL>-<AREA>-<NNNN>`, for example `HLR-HSI-0013`.

| Part | Values | Meaning |
| :--- | :--- | :--- |
| LEVEL | `SYS`, `HLR`, `LLR` | System, high-level, low-level requirement |
| LEVEL | `SECR` | Security requirement. It has no level part: it is `SECR-<AREA>-<NNNN>` |
| AREA | `HSI`, `SIG`, `MOD`, ... | The functional area, see section 3 |
| NNNN | `0001` to `9999` | Four digits, zero padded |

### 2.1 Rules

| Rule | Statement |
| :-: | :--- |
| I-1 | **An ID is never reused and never renumbered.** A requirement that is dropped keeps its ID and gets the state `withdrawn`. |
| I-2 | Gaps in the numbering are allowed. A gap is not an error. |
| I-3 | One requirement states one thing, with one "shall". A sentence with two obligations becomes two IDs. |
| I-4 | Every requirement has a verification method: **Test**, **Proof**, **Analysis**, **Review** or **Inspection**. |
| I-5 | Every requirement has a state: `placeholder`, `stated`, `verified`, `withdrawn`. `verified` needs evidence labelled *proved* or *tested* (PSecAC, section 5.2). |
| I-6 | A header that cites a range writes it as `HLR-SIG-0013 .. HLR-SIG-0024`. The trace tool expands the range into its individual IDs (decision for file 4). |

## 3. Areas and ranges in use

"Statements" says whether the statement text of each ID exists in a document the author has seen.

| Area | Meaning | IDs in use | Count | Where they appear | Statements |
| :--- | :--- | :--- | :-: | :--- | :--- |
| HSI | Hardware-software interface, sensor driver | `HLR-HSI-0001 .. 0013` | 13 | Header of `fsac_hsi_sensor.h` (0001 to 0012); ADR-007 adds 0013; ADR-008 cites 0012; the handoff cites 0011 | 0012 and 0013 only. 0011 is described (mailbox mapped as device memory, a BSP matter). The rest: **not seen** |
| SIG (first block) | Signal management: vocabulary, mid-value select | `HLR-SIG-0001 .. 0012` (assumed) | 12 | Not seen in any document | **not seen** |
| SIG (cross-check) | Fault detection with leaky bucket | `HLR-SIG-0013 .. 0024` | 12 | ADR-009 | **not seen** (ADR-009 gives the design, not the statements) |
| SIG (observer) | Analytical redundancy | `HLR-SIG-0025 .. 0034` | 10 | ADR-010 | **not seen** |
| SIG (voter) | Voting and reference-aided voting | `HLR-SIG-0035 .. 0048` | 14 | ADR-011 | **not seen** |
| MOD | Mode logic | `HLR-MOD-0001 .. 0016` | 16 | ADR-012 | **not seen** |
| CTL | Control laws, SPARK core | **unknown** | ? | Headers of Part 2 | **not seen** |
| ARC, BOOT, GW, MNT, DBG, LOG | Security | see section 4 | 25 in total with TARA and PLAN | Security documents of Part 5 and `PSecAC.md` | all written, section 4 |
| TARA, PLAN | Process requirements on the security documents | see section 4 | 10 (5 each) | `TARA.md`, `PSecAC.md` | all written, section 4 |

The first block of `SIG` (0001 to 0012) is an assumption: ADR-009 starts at 0013, which suggests the vocabulary package and `Mid_Value_Select` took the numbers before it. Confirm with the harvest command.

## 4. Security requirements

Statements are the ones in `security_architecture.md` (section 8), `secure_boot.md` (section 11), `TARA.md` (section 9) and `PSecAC.md` (section 12). Two of them carry the **corrected wording** requested in the PSecAC debt register.

**Evidence labels** are those of `PSecAC.md`, section 5.2: *written* means the file exists and has not been run by the author. No security requirement is *verified* today.

### 4.1 Architecture and boot

| ID | Statement | Method | Evidence (file, group) | State |
| :--- | :--- | :-: | :--- | :-: |
| SECR-ARC-0001 | No untrusted input shall reach Z0 other than through a sanitized one-way copy or a verified ground-only installation. | Review, Test | Memory map review (not started); gateway tests `test_gw_1553.c` | placeholder |
| SECR-ARC-0002 | A security reaction in flight shall never stop or degrade the flight-critical function. | Test | `step()` check in `test_gw_1553.c` (written); integration test with `modes` (planned) | placeholder |
| SECR-BOOT-0001 | Every executable image shall be verified against a signed manifest before it runs. | Test | `test_secure_boot.c` groups D-01, D-07 | stated, evidence written |
| SECR-BOOT-0002 | An image whose version counter is below the stored counter shall be refused. | Test | groups D-06, S-01 | stated, evidence written |
| SECR-BOOT-0003 | The manifest reader shall accept only a buffer that has exactly the format of `secure_boot.md`, section 5, and shall refuse any other without reading outside the buffer. | Test | groups P-01 to P-04 | stated, evidence written |
| SECR-BOOT-0004 | No manifest field shall cause an acceptance or a counter change until the signature has verified; fields read earlier may only cause a refusal or select the verification key. *(corrected wording, debt D-04)* | Test, Review | groups D-05, D-08 | stated, evidence written |
| SECR-BOOT-0005 | The boot shall verify the bytes that will execute, after copying them to execution memory. | Test | group D-01 (`hash_misuse` check) | stated, evidence written |
| SECR-BOOT-0006 | A counter shall advance only at commit, on the ground, and never by a failed or unverified boot. | Test | groups D-01, C-01, S-01 | stated, evidence written |
| SECR-BOOT-0007 | The boot decision shall have exactly two outcomes, boot or refuse, and no partial start. | Test, Review | decision tests (written). **The "no partial start" half belongs to the hypervisor, which is not built.** | stated, partly written |
| SECR-BOOT-0008 | A production-lifecycle unit shall refuse a manifest signed with a test key, whatever the signature result. | Test | group D-04 | stated, evidence written |

### 4.2 Gateway, maintenance, debug, log

| ID | Statement | Method | Evidence (file, group) | State |
| :--- | :--- | :-: | :--- | :-: |
| SECR-GW-0001 | The mission gateway shall accept only messages listed in the mission-bus ICD, with the exact word count and field ranges listed there. | Test | groups G-02, G-03, G-04 | stated, evidence written |
| SECR-GW-0002 | The mission gateway shall never write outside its output buffer, for any input. | Test, Analysis | groups G-05, G-13. **A normal run does not show this; it needs a sanitizer run (`-fsanitize=address,undefined`).** | stated, evidence written |
| SECR-MNT-0001 | Maintenance sessions shall exist only on the ground with the maintenance switch armed. | Test | needs `ICD_maintenance.md` and P7 | placeholder, not started |
| SECR-DBG-0001 | Debug interfaces shall be disabled in production hardware. | Inspection | hardware review (`HW_PHAC`) | placeholder, not started |
| SECR-LOG-0001 | Security events shall be logged with a hash chain and a rate limit. | Test | needs P8, not built | placeholder, not started |

### 4.3 Process requirements on the security documents

| ID | Statement | Method | Evidence | State |
| :--- | :--- | :-: | :--- | :-: |
| SECR-TARA-0001 | Every security measure shall be traceable to at least one threat scenario of `TARA.md`. | Inspection | `TARA.md`, section 5 (coverage tables) | stated |
| SECR-TARA-0002 | Every scenario with a risk of Medium or above before measures shall have at least one measure and one verification. | Inspection | `TARA.md`, sections 3 and 6 | stated |
| SECR-TARA-0003 | A boot image signed with a test key shall be refused by a production-configured boot. | Test | group D-04. **Same content as SECR-BOOT-0008, see section 5.** | stated, evidence written |
| SECR-TARA-0004 | No anomaly detected by the mission gateway shall change a mode, a latch or a control output. | Test | `step()` check (written); integration test (planned) | stated, partly written |
| SECR-TARA-0005 | `TARA.md` shall be reviewed whenever a measure, an entry point or a failure condition in `FHA.md` changes. | Inspection | `PSecAC.md`, section 10 (change rule) | stated |
| SECR-PLAN-0001 | Every security measure shall name the threat scenarios it counters and the evidence that it works. | Inspection | `PSecAC.md`, section 6 | stated |
| SECR-PLAN-0002 | Evidence shall be labelled proved, tested, reviewed, written or assumed, and shall not be described with a stronger label. | Inspection | `PSecAC.md`, section 5.2 | stated |
| SECR-PLAN-0003 | A test result shall be recorded with the commit and the tool versions it was produced with. | Inspection | to be added to the verification campaign (file 6) | stated |
| SECR-PLAN-0004 | No private signing key shall be stored in the repository. | Inspection | repository review; `secure_boot.md`, rule K-1 | stated |
| SECR-PLAN-0005 | The analyses named in `PSecAC.md`, section 10, shall be re-opened when the listed change occurs. | Inspection | `PSecAC.md`, section 10 | stated |

## 5. Overlaps and gaps found while building this index

| ID | Finding | Suggested action |
| :-: | :--- | :--- |
| X-1 | **SECR-TARA-0003 and SECR-BOOT-0008 say the same thing.** | Keep both IDs (rule I-1) but make `SECR-TARA-0003` a pointer: "satisfied by SECR-BOOT-0008". Do not verify it twice. |
| X-2 | **The parser's own properties have no requirement IDs.** `fsac_gw_1553.h` states G1 to G4 (length checked before reading, no write outside the buffer, rejection moves only a counter). Only two `SECR-GW` IDs exist. | Adopt the proposed IDs of section 5.1, or reject them. |
| X-3 | **SECR-BOOT-0007 is half the hypervisor's job.** | Split it when the hypervisor is specified: the decision stays here, "no partial start" moves to a hypervisor requirement. |
| X-4 | **The restart-in-flight rule of `secure_boot.md`, section 1, has no ID.** | Proposed below as SECR-BOOT-0009. |
| X-5 | **The ranges in headers are written as `0001 .. 0012`.** A plain search for IDs finds only the two endpoints. | Decision I-6: the trace tool expands ranges. |

### 5.1 Proposed new security requirements (not adopted until you say so)

| ID | Proposed statement | Source | Method |
| :--- | :--- | :--- | :-: |
| SECR-GW-0003 | A rejected frame shall queue no record, produce no response and move exactly one counter. | ICD rules P-5 and R-1; `fsac_gw_1553.h`, property G4 | Test |
| SECR-GW-0004 | Gateway counters shall saturate at their maximum and shall never wrap to zero. | ICD rule R-2 | Test |
| SECR-GW-0005 | A transmit response shall come only from a buffer loaded through the one-way copy, and shall be the "no data" pattern when that buffer is empty or older than the limit. | ICD rules TX-1 and TX-4 | Test |
| SECR-GW-0006 | A reserved field that is not zero shall make the message invalid. | ICD, section 4.1 | Test |
| SECR-GW-0007 | The gateway shall accept at most the configured number of messages per message ID per major frame. | ICD rule R-4; threat T-04 | Test |
| SECR-BOOT-0009 | A restart in flight shall re-verify the committed image with the same checks; a failure shall leave that unit lost and shall change nothing else. | `secure_boot.md`, section 1 | Test, Review |

## 6. Unknown ranges: what the harvest must find

| Question | Why it matters |
| :--- | :--- |
| What are the `CTL` (or other) IDs in the headers of Part 2? | The SPARK core is the largest evidence set and has no row here yet. |
| Are `HLR-SIG-0001 .. 0012` the vocabulary and `Mid_Value_Select` IDs? | The SIG block would then be continuous. |
| Does any header cite an ID outside these ranges? | It would be a typo or an area missing from section 3. |
| Does any header cite `SYS` or `LLR` IDs? | None appear in the documents seen so far. |

## 7. Harvest command

From the repository root (Git Bash). It lists every requirement ID cited anywhere in source and documents, with a count:

    grep -rhoE "(SYS|HLR|LLR)-[A-Z0-9]+-[0-9]{4}|SECR-[A-Z0-9]+-[0-9]{4}" docs software security 2>/dev/null | sort | uniq -c

To see **which file** cites each ID (this also finds the range endpoints in headers):

    grep -rnoE "(SYS|HLR|LLR)-[A-Z0-9]+-[0-9]{4}|SECR-[A-Z0-9]+-[0-9]{4}" docs software security 2>/dev/null

Expect the first command to show **only the endpoints** of ranges, not the IDs between them (rule I-6).

## 8. What this document does not cover

1. **The statements of HLR and LLR requirements.** Section 3 marks them "not seen".
2. **System requirements.** No `SYS` ID has been seen.
3. **Allocation to partitions and to hardware.** That is the trace tool's job.
4. **Safety requirements derived from the FHA.** `FHA.md` produces failure conditions, not requirements. Deriving safety requirements from each `FC-xx` is a later step.
5. **Verification results.** Only the label and the file of the evidence are named here.