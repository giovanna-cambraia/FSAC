# FSAC: Requirements Index

| Item | Value |
| :--- | :--- |
| File | `docs/03_requirements/requirements_index.md` |
| Purpose | The ID scheme, the ID ranges in use, and the full list of security requirements |
| Consumers | The trace checker (`traceability/trace_check.py`), the link files (`traceability/links/`), the compliance matrix (Part 6), every file header |
| Status | **Index of a learning and portfolio project. Most statements are not written.** Only the 25 security and process requirements of section 4 have statements here. Every `HLR-*` and `SYS-*` ID in the repository is cited by code and tests but defined nowhere (section 3). |
| Checker result at this revision | 173 IDs seen, **25 defined (all in section 4), 148 undefined**, 1 link file, 0 errors. `trace_check.py` reads definitions only from the first cell of the section 4 tables, and ignores any table whose header says "proposed". |

## 1. Purpose

Every source file header cites requirement IDs. This file is the one place that says which IDs exist, what range each area uses, and which of them already have a statement, a verification method and a piece of evidence.

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
| I-5 | Every requirement has a state: `placeholder`, `stated`, `verified`, `withdrawn`. `verified` needs evidence labelled *proved* or *tested* (PSecAC, section 5.2). A note under the table says what the evidence does not show. |
| I-6 | A header that cites a range writes it as `HLR-SIG-0013 .. HLR-SIG-0024`. The trace checker expands the range into its individual IDs; the second end may be written as four digits. |
| I-7 | The first token of an ID is always the level, even where an area code has the same spelling: `HLR-SYS-0001` is level HLR, area SYS, while `SYS-TIM-0001` is level SYS, area TIM. |

## 3. Areas and ranges in use

Built from the harvest of the repository and the output of the trace checker. "Cited by" lists the files whose headers or text cite the range. "Statements" says whether the statement text exists in any document.

| Area | Meaning | IDs in use | Cited by | Statements |
| :--- | :--- | :--- | :--- | :--- |
| HSI | Hardware-software interface, sensor driver | `HLR-HSI-0001 .. 0013` | `fsac_hsi_sensor.h` (0001 to 0012), `fsac_sensor_ingest.c`, `test_sensor_ingest.c`, `hal_c/misra/README.md`; 0013 by ADR-007, `fsac-platform_ports.ads` and `test_bridge.adb` | 0012 (NULL arguments are reported and never dereferenced) is stated in ADR-008, and 0013 (a sample is rejected when any hw_flags bit is set) in ADR-007. The rest are not written |
| SIG | Signal management | `HLR-SIG-0001 .. 0048`, in five blocks: 0001 to 0004 (`fsac-signal_mgmt.ads`), 0005 to 0012 (`mid_value_select`), 0013 to 0024 (`cross_check`, ADR-009), 0025 to 0034 (`observer`, ADR-010), 0035 to 0048 (`voter`, ADR-011) | those files and `test_signal_mgmt.adb` | not written |
| MOD | Mode logic | `HLR-MOD-0001 .. 0016` | `fsac-modes.ads`, ADR-012, `test_signal_mgmt.adb` | not written |
| CTL | Control laws, SPARK core | `HLR-CTL-0001 .. 0034`, in four blocks: 0001 to 0003 (`fsac-control.ads`), 0004 to 0012 (`fsac-control-params.ads`), 0013 to 0019 (`gain_schedule`), 0020 to 0034 (`pitch_rate_damper`) | those files, `test_core.adb` (cites 0013 and 0020), `test_signal_mgmt.adb` (0020), the root `README.md` (0012) | not written |
| NUM | Numerics, fixed point | `HLR-NUM-0001 .. 0006` and `0010 .. 0018`; **0007 to 0009 are cited nowhere** | `fsac-types.ads` (0001 to 0006), `fsac-fixed_math` (0010 to 0018), `test_core.adb` | not written |
| BRG | Ada/C bridge | `HLR-BRG-0001 .. 0006` | `fsac-platform_ports.ads`, `test_bridge.adb` | not written |
| SYS | Root package (level HLR, area SYS, rule I-7) | `HLR-SYS-0001 .. 0004` | `fsac.ads` | not written |
| SUB | Probably the Ada language subset (inferred from the file, not confirmed) | `HLR-SUB-0001 .. 0008` | `fsac.adc` (the `pragma Restrictions` file) | not written |
| TIM, SAF | System requirements (level SYS) | `SYS-TIM-0001 .. 0003`, `SYS-SAF-0001` | `fsac.ads` (lines 28 to 31); `SYS-SAF-0001` also `FDIR_timing_analysis.md` | not written |
| ARC, BOOT, GW, MNT, DBG, LOG, TARA, PLAN | Security and process | see section 4 | Part 5 documents, code and tests | **written** (section 4) |

No file in `docs/` states any `HLR-*` or `SYS-*` requirement. The IDs in code headers point at no text yet.

## 4. Security requirements

The statements below are the definitions. They are repeated, for reading, in `security_architecture.md`, `secure_boot.md`, `TARA.md` and `PSecAC.md`; this file is the source.

How to read the **State** column:

- `verified`: tested on the owner's machine, which rule I-5 requires. See notes 1 and 2.
- `stated`: the statement exists. The evidence is written, linked, or not yet run with recorded numbers.
- `placeholder`: the statement exists, but the evidence it needs does not exist yet.

Where the evidence is recorded: `traceability/links/security.links`. A test link names a test group, not just a file. The checker confirms that the file and the group label exist; it does not run the test.

**Note 1.** `verified` for the boot requirements means: tested on the owner's machine (846 checks passed, 0 failed, with 100 percent line and branch coverage of `fsac_secure_boot.c`) **against a fake verifier**. The cryptographic library and the Root of Trust are assumptions (`secure_boot.md`, section 13).

**Note 2.** For `SECR-BOOT-0006`, "on the ground" is the caller's statement (`ground_session_ok`); the module cannot check it.

### 4.1 Architecture and boot

| ID | Statement | Method | Evidence | State |
| :--- | :--- | :-: | :--- | :-: |
| SECR-ARC-0001 | No untrusted input shall reach Z0 other than through a sanitized one-way copy or a verified ground-only installation. | Review, Test | **Review of the memory map for P6 against control state: not started** (the map does not exist). The gateway parser is linked as implementation only; its tests check the parser, not the isolation, so they are deliberately not linked. | placeholder |
| SECR-ARC-0002 | A security reaction in flight shall never stop or degrade the flight-critical function. | Test | Gateway half: `test_gw_1553.c`, group G-06 (every call moves one counter and nothing else), plus the interface that has no callback and no mode. Integration test with the mode logic: planned. | placeholder |
| SECR-BOOT-0001 | Every executable image shall be verified against a signed manifest before it runs. | Test | `test_secure_boot.c`, groups D-01 and D-07 | verified (note 1) |
| SECR-BOOT-0002 | An image whose version counter is below the stored counter shall be refused. | Test | groups D-06 and S-01 | verified (note 1) |
| SECR-BOOT-0003 | The manifest reader shall accept only a buffer that has exactly the format of `secure_boot.md`, section 5, and shall refuse any other without reading outside the buffer. | Test | groups P-01 to P-04 (the length sweep allocates each input at its exact size; a sanitizer run is not done) | verified (note 1) |
| SECR-BOOT-0004 | No manifest field shall cause an acceptance or a counter change until the signature has verified; fields read earlier may only cause a refusal or select the verification key. | Test, Review | groups D-05 and D-08 | verified (note 1) |
| SECR-BOOT-0005 | The boot shall verify the bytes that will execute, after copying them to execution memory. | Test | group D-01 (the `hash_misuse` check) | verified (note 1) |
| SECR-BOOT-0006 | A counter shall advance only at commit, on the ground, and never by a failed or unverified boot. | Test | groups C-01, D-01 and S-01 | verified (notes 1 and 2) |
| SECR-BOOT-0007 | The boot decision shall have exactly two outcomes, boot or refuse, and no partial start. | Test, Review | The decision half: groups D-01 and D-03. **The "no partial start" half belongs to the hypervisor, which is not built.** | stated, partly verified |
| SECR-BOOT-0008 | A production-lifecycle unit shall refuse a manifest signed with a test key, whatever the signature result. | Test | group D-04 | verified (note 1) |

### 4.2 Gateway, maintenance, debug, log

| ID | Statement | Method | Evidence | State |
| :--- | :--- | :-: | :--- | :-: |
| SECR-GW-0001 | The mission gateway shall accept only messages listed in the mission-bus ICD, with the exact word count and field ranges listed there. | Test | `test_gw_1553.c`, groups G-02, G-03 and G-04. The owner reports it passing; the numbers are not recorded here. | stated, evidence written |
| SECR-GW-0002 | The mission gateway shall never write outside its output buffer, for any input. | Test, Analysis | groups G-05 and G-13. **A normal run does not show this; it needs a run under a memory sanitizer (`-fsanitize=address,undefined`), which is not done.** | stated, evidence written |
| SECR-MNT-0001 | Maintenance sessions shall exist only on the ground with the maintenance switch armed. | Test | needs `ICD_maintenance.md` and partition P7. Not started. | placeholder |
| SECR-DBG-0001 | Debug interfaces shall be disabled in production hardware. | Inspection | hardware review (`HW_PHAC`). Not started. | placeholder |
| SECR-LOG-0001 | Security events shall be logged with a hash chain and a rate limit. | Test | needs partition P8, not built. | placeholder |

### 4.3 Process requirements on the security documents

| ID | Statement | Method | Evidence | State |
| :--- | :--- | :-: | :--- | :-: |
| SECR-TARA-0001 | Every security measure shall be traceable to at least one threat scenario of `TARA.md`. | Inspection | `TARA.md`, section 5 (coverage tables). Inspection by the author only. | stated |
| SECR-TARA-0002 | Every scenario with a risk of Medium or above before measures shall have at least one measure and one verification. | Inspection | `TARA.md`, sections 3 and 6. Inspection by the author only. | stated |
| SECR-TARA-0003 | A boot image signed with a test key shall be refused by a production-configured boot. This is the same obligation as `SECR-BOOT-0008`: it is satisfied by that requirement and verified once, there. | Test | group D-04 (through `SECR-BOOT-0008`) | verified (note 1) |
| SECR-TARA-0004 | No anomaly detected by the mission gateway shall change a mode, a latch or a control output. | Test | Gateway half: group G-06 and the interface with no callback and no mode. Integration test with the mode logic: planned. | stated, partly written |
| SECR-TARA-0005 | `TARA.md` shall be reviewed whenever a measure, an entry point or a failure condition in `FHA.md` changes. | Inspection | `PSecAC.md`, section 10 (change rule) | stated |
| SECR-PLAN-0001 | Every security measure shall name the threat scenarios it counters and the evidence that it works. | Inspection | `PSecAC.md`, section 6 | stated |
| SECR-PLAN-0002 | Evidence shall be labelled proved, tested, reviewed, written or assumed, and shall not be described with a stronger label. | Inspection | `PSecAC.md`, section 5.2 | stated |
| SECR-PLAN-0003 | A test result shall be recorded with the commit and the tool versions it was produced with. | Inspection | to be added to the verification campaign document. Not written. | placeholder |
| SECR-PLAN-0004 | No private signing key shall be stored in the repository. | Inspection | a repository scan for private keys. **Not done.** `secure_boot.md`, rule K-1, states the rule, but a statement of a rule is not evidence that it holds. | placeholder |
| SECR-PLAN-0005 | The analyses named in `PSecAC.md`, section 10, shall be re-opened when the listed change occurs. | Inspection | `PSecAC.md`, section 10 (change rule) | stated |

## 5. Overlaps and gaps found while building this index

| ID | Finding | State |
| :-: | :--- | :--- |
| X-1 | `SECR-TARA-0003` and `SECR-BOOT-0008` said the same thing. | **Resolved**: both IDs are kept (rule I-1), and `SECR-TARA-0003` now says it is satisfied by `SECR-BOOT-0008` and verified once. |
| X-2 | The parser's own properties had no requirement IDs. The gateway header states properties G1 to G4, and only two `SECR-GW` IDs exist. | Open: the six proposals of section 5.1, adopted or rejected by the owner. |
| X-3 | `SECR-BOOT-0007` is half the hypervisor's job. | Open until the hypervisor is specified: the decision stays here, "no partial start" moves to a hypervisor requirement. |
| X-4 | The restart-in-flight rule of `secure_boot.md`, section 1, has no ID. | Open: proposed as `SECR-BOOT-0009` below. |
| X-5 | Headers cite ranges, so a plain search finds only the two ends. | **Resolved**: rule I-6, and the trace checker expands ranges. |
| X-6 | A header that cites a range counts every ID in it as "tested", even when no test covers some of them. For example the area table shows `SECR-ARC tested 2` while `SECR-ARC-0001` has no test. | Open, by design: only link files with anchors say which test covers which requirement. The compliance matrix is built from the links, never from header citations. |
| X-7 | No `HLR-*` or `SYS-*` statement exists. The 148 undefined IDs are cited by code and tests, defined by nothing. | Open: the statements are the next series of documents. |
| X-8 | `HLR-NUM-0007` to `0009` are cited by nothing. | Open: either the numbers are free, or a file cites them in a form the pattern misses. |

### 5.1 Proposed new security requirements (not adopted until the owner says so)

These are not definitions: the table is titled "Proposed", and the checker ignores it. The last column shows the evidence that already exists, because the gateway tests and the boot decision were written against these rules.

| ID | Proposed statement | Source | Method | Evidence that already exists |
| :--- | :--- | :--- | :-: | :--- |
| SECR-GW-0003 | A rejected frame shall queue no record, produce no response and move exactly one counter. | ICD rules P-5, R-1; `fsac_gw_1553.h` | Test | `test_gw_1553.c`, groups G-06 and G-13 |
| SECR-GW-0004 | Gateway counters shall saturate at their maximum and shall never wrap to zero. | ICD rule R-2 | Test | group G-10 |
| SECR-GW-0005 | A transmit response shall come only from a buffer loaded through the one-way copy, and shall be the "no data" pattern when that buffer is empty or older than the limit. | ICD rules TX-1, TX-4, TX-6, TX-7 | Test | groups G-08 and G-09 |
| SECR-GW-0006 | A reserved field that is not zero shall make the message invalid. | ICD, section 4.1 | Test | group G-03 |
| SECR-GW-0007 | The gateway shall accept at most the configured number of messages per message ID per major frame. | ICD rule R-4; threat T-04 | Test | group G-07 |
| SECR-BOOT-0009 | A restart in flight shall re-verify the committed image with the same checks; a failure shall leave that unit lost and shall change nothing else. | `secure_boot.md`, section 1 | Test, Review | the decision half is covered by groups D-01 to D-08; "changes nothing else" depends on the hypervisor and mode logic and has no test |

If these are adopted, the six rows move to section 4.2 (and `SECR-BOOT-0009` to section 4.1) with the evidence column as above, and lines are added to `traceability/links/security.links`.

## 6. Questions answered by the harvest

| Question | Answer |
| :--- | :--- |
| What are the control-law IDs? | `HLR-CTL-0001 .. 0034` in four blocks (section 3). |
| Are `HLR-SIG-0001 .. 0012` the vocabulary and `Mid_Value_Select` IDs? | Yes: 0001 to 0004 are cited by `fsac-signal_mgmt.ads`, and 0005 to 0012 by `fsac-signal_mgmt-mid_value_select.ads`. |
| Does any header cite an ID outside the ranges of section 3? | No. |
| Does any header cite `SYS` or `LLR` IDs? | `SYS` yes (`SYS-TIM`, `SYS-SAF`, in `fsac.ads`). `LLR`: none. |
| Does any document state an `HLR` requirement? | Only two, in ADRs: `HLR-HSI-0012` (ADR-008) and `HLR-HSI-0013` (ADR-007). They should move into this folder when the statements are written. |

## 7. Commands

From the repository root (Git Bash). The trace checker reads the whole repository and the link files:

    python traceability/trace_check.py
    python traceability/trace_check.py --list undefined
    python traceability/trace_check.py --csv traceability/trace_matrix.csv

The CSV is generated. It is not committed. Its `links` column lists only what the link files claim.

To list every requirement ID cited anywhere, with a count (a plain search finds only the two ends of a range):

    grep -rhoE "(SYS|HLR|LLR)-[A-Z0-9]+-[0-9]{4}|SECR-[A-Z0-9]+-[0-9]{4}" docs software security | sort | uniq -c

## 8. What this document does not cover

1. **The statements of HLR and LLR requirements.** None is written (X-7).
2. **System requirements.** `SYS-TIM-0001 .. 0003` and `SYS-SAF-0001` are cited, not stated.
3. **Allocation to partitions and to hardware.** That is the compliance matrix's job.
4. **Safety requirements derived from the FHA.** `FHA.md` produces failure conditions, not requirements. Deriving safety requirements from each `FC-xx` is a later step.
5. **Verification results.** Only the label and the place of the evidence are named here. Test numbers belong to the verification campaign document.

## 9. Revision history

| Revision | Change |
| :-: | :--- |
| 1 | First version, written before the harvest: ranges partly assumed, statements marked "not seen". |
| 2 | Rebuilt from the harvest and the checker output. **Section 3** now lists real ranges and the files that cite them (CTL 0001 to 0034, NUM with the uncited 0007 to 0009, BRG, SYS, SUB, TIM, SAF), and says "not written" where revision 1 said "not seen". **Rule I-7** added (the first token is the level). **I-6** now says the checker expands ranges. **Section 4**: states changed from "written" to `verified` for the boot requirements that were tested (note 1), with the fake-verifier and ground-session limits stated; the `SECR-ARC-0001` evidence now names the memory-map review as the missing verification and says the gateway tests are not linked to it; `SECR-TARA-0003` points to `SECR-BOOT-0008`; `SECR-PLAN-0004` says the repository scan is not done; the gateway rows say the numbers are not recorded. **Section 5**: X-1 and X-5 resolved, X-6 to X-8 added. **Section 5.1**: the evidence that already exists is listed for each proposal. **Section 6** now holds answers instead of questions. **Section 7** adds the trace checker commands. |