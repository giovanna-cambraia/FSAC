# FSAC: Plan for Security Aspects of Certification (PSecAC)

| Item | Value |
| :--- | :--- |
| File | `docs/05_security/PSecAC.md` |
| Standards vocabulary | RTCA DO-326A / ED-202A (process), DO-356A / ED-203A (methods), DO-355 / ED-204 (continued airworthiness, named only) |
| Scope | The airworthiness security work of the FSAC project: what is done, in what order, with what evidence |
| Inputs | `security_architecture.md`, `TARA.md`, `FHA.md`, `ICD_mission_bus.md`, `secure_boot.md` |
| Status | **Plan of a learning and portfolio project. There is no certification authority, no applicant and no aircraft programme behind it.** It uses the structure of a PSecAC so the work can be reviewed the way a real one would be. |
| Vocabulary note | The names of the DO-326A work products in section 4 are written as the author recalls them. Check them against your copy of the standard before quoting them anywhere. |

## 1. Purpose

A PSecAC says: *how will we show that this system is secure enough for the aircraft it flies on, and what will we hand over as proof?* This one does the same for the FSAC, at the scale of a single developer.

Three aims:

1. **One place for the security argument.** What is protected, from whom, by which measure, verified by which test.
2. **Honest status.** Each piece of evidence says whether it was written, run, or only planned.
3. **A change rule.** When something changes, this file says which analyses must be re-opened.

## 2. System and context

| Item | Content |
| :--- | :--- |
| System | The FSAC: three LRUs, each a command lane and a monitor lane, plus an I/O FPGA and a hardware Root of Trust (`security_architecture.md`, section 2) |
| Safety context | An aerodynamically unstable airframe; the flight-critical function must never be reduced by a security reaction in flight (`security_architecture.md`, section 1) |
| Interfaces in scope | Mission bus (E1), maintenance and data loader (E2), debug (E3), CCDL (E4), sensor buses (E5), supply chain (E6), removable media (E7), physical and EM (E8) |
| What is built | Secure boot reader and decision, mission-bus parser, sensor driver. The CCDL, the maintenance session (P7), the log (P8) and the hardware are specified, not built. |
| Certification target | None. The project follows the structure of DO-326A and DO-178C Level A for the flight-critical code, as a training exercise. |

## 3. Security scope

The scope is the security architecture document, sections 2 to 4:

| Scope element | Where defined |
| :--- | :--- |
| Trust zones Z0 to Z4 and flows F1 to F8 | `security_architecture.md`, section 2 |
| Assets A1 to A8 | section 3 |
| Entry points E1 to E8 | section 4 |
| Measures SM-01 to SM-12 | section 5 |
| Attackers AT-1 to AT-6 | `TARA.md`, section 2 |

**Out of scope, by decision:** the aircraft network beyond the mission bus, other aircraft systems, ground infrastructure beyond the maintenance laptop, and continued airworthiness (handling vulnerabilities after delivery).

## 4. Process and work products

The steps follow the DO-326A process. Names are as recalled (see the vocabulary note).

| Process step | Work product | File | State |
| :--- | :--- | :--- | :-: |
| Plan | This plan | `PSecAC.md` | written |
| Security scope definition | Scope | `security_architecture.md`, sections 2 to 4 | written |
| Preliminary risk assessment (aircraft and system level) | Threat and risk assessment | `TARA.md` | written, see debt D-11 |
| Security architecture | Measures and flows | `security_architecture.md`, section 5 | written |
| Security requirements | Placeholder IDs `SECR-*` | tables in each document; index in Part 6 | placeholders |
| Implementation | Code of the measures | `fsac_secure_boot`, `fsac_gw_1553` | written, not yet run by the user |
| Security effectiveness: verification | Tests and reviews | section 6 of this file | in progress |
| Security effectiveness: independent review | None possible | section 7 | not met |
| Compliance summary | Compliance matrix, security rows | Part 6, file 5 | planned |
| Continued airworthiness | none | | not covered |

## 5. Assurance approach

### 5.1 Level of assurance

DO-356A / ED-203A associate a security risk with a security assurance level. **The levels and their objectives are not reproduced in this project.** The risk matrix in `TARA.md`, section 1.3, is a project convention, not the standard's table.

The working rule used instead:

| Rule | Statement |
| :-: | :--- |
| A-1 | Any measure that counters a scenario with a risk of Medium or above before measures gets at least one test and one review. |
| A-2 | Any code that touches untrusted bytes (the manifest reader, the bus parser) is written to the same coding rules as the flight-critical C (C11, MISRA C:2012 style) and tested against malformed input with a deterministic fuzz campaign. |
| A-3 | Evidence is labelled: **proved**, **tested**, **reviewed**, **assumed**. No evidence is described with a stronger word than it earned. |

### 5.2 What counts as evidence

| Label | Meaning | Example |
| :--- | :--- | :--- |
| Proved | A tool showed it for all inputs within stated assumptions | GNATprove results for the SPARK core |
| Tested | A repeatable test passed on the user's machine, output pasted | `test_secure_boot`, once run |
| Reviewed | A person read it against a checklist | none yet |
| Written | Exists in the repository, not yet run or reviewed | the secure boot and gateway code today |
| Assumed | Stated as a precondition, not checked here | the crypto library behaves as secure_boot.md, section 8 lists |

## 6. Activities and verification

Evidence status as of this writing. "Written" means the file exists and was compiled in the author's environment or is waiting for its first run on the user's machine.

| Activity | Counters (TARA) | Evidence | Status |
| :--- | :-: | :--- | :-: |
| Strict manifest reader and boot decision tests | T-08, T-09, T-13, T-24 | `software/hal_c/tests/test_secure_boot.c` | written, not run |
| Manifest tamper sweep (every bit flipped) | T-08 | group D-05 of the same test | written, not run |
| Production refuses a test key | T-24 | group D-04 | written, not run |
| Anti-rollback and commit rules | T-09 | groups D-06, C-01, S-01 | written, not run |
| Gateway parser tests per ICD row | T-01 to T-06 | `software/hal_c/tests/test_gw_1553.c` | written, not run |
| Length sweep with exact allocation | T-01 | group G-05 | written, not run |
| Deterministic fuzz campaign, 200000 frames | T-01 | group G-13 | written, not run |
| A rejection only moves a counter | T-07 | the `step()` check in `test_gw_1553.c` | written, not run |
| Structural coverage of both modules | all of the above | `gcov` on both tests | planned |
| Test that no gateway anomaly changes any mode or control output | T-07 | integration test with `modes` | planned (Part 6 and later) |
| Review of the memory map for P6 against control state | T-05 | `software/config/memory_map/` | not started, the map does not exist yet |
| Maintenance interlock test | T-11, T-12 | needs `ICD_maintenance.md` | not started |
| Authenticated CCDL frame tests | T-15, T-16 | needs `ICD_ccdl.md` | not started |
| Reproducible build check | T-21, T-22 | `ci/gates.yaml` | not started |
| Review of hardware debug fuse and key handling | T-14, T-23 | `HW_PHAC`, process review | not started |
| Penetration test | all | none | not planned |

Rows marked "written, not run" become "tested" only when the user pastes the output of the command in the file header.

## 7. Organisation, independence and the origin of the data

| Topic | Statement |
| :--- | :--- |
| People | One developer owns the repository. |
| Independence | Real DO-326A and DO-178C practice needs reviewers independent of the author. **That is not met here** and cannot be in a single-developer project. |
| Compensation | Every file is built, run and checked by the owner on their own machine; results are pasted, not assumed. Documents list their own open items. |
| AI assistance | Most files of Part 5 and Part 6 were drafted with an AI assistant. The assistant could not always run them. A file the assistant wrote but nobody ran is labelled "written". |
| Consequence | A reviewer should treat "written" as a claim about intent, and only "tested" or "proved" as evidence. |

## 8. Schedule and milestones

Milestones follow the project's parts and git tags. No calendar dates are promised.

| Milestone | Content | Suggested tag | Done when |
| :--- | :--- | :--- | :--- |
| M1 | Security documents and code of Part 5 | `part5-security` | the three runs of section 6 are pasted and clean |
| M2 | FHA, this plan, requirement index, trace tool | `part6-docs` | the files exist and the trace checker passes |
| M3 | Compliance matrix and campaign plan | `part6-compliance` | every row has a status, none hides a gap |
| M4 | Maintenance session (P7) and CCDL specification | none yet | `ICD_maintenance.md` and `ICD_ccdl.md` written |
| M5 | First security review by someone other than the author | none yet | a written review exists |

## 9. Configuration management and change control

| Item | Rule |
| :--- | :--- |
| Baseline | A git tag per milestone. A test result belongs to the commit it was run on; results from another commit do not count. |
| Signing keys | No private signing key is ever in the repository (`secure_boot.md`, K-1). Test keys are generated locally by a script. |
| FPGA bitstream | ADR-007 requires the bitstream version to be recorded with the software baseline. This goes in the configuration index (Part 6, file 7). |
| Toolchain | Pinned by hash when `ci/docker/` exists (SM-11). Until then, the compiler version used for each run is recorded with its output. |
| Change impact | See section 10. |

## 10. Interaction with safety and the change rule

| Question | Answer |
| :--- | :--- |
| Where does a security threat get its severity? | From `FHA.md`, section 5. The mapping of TARA scenarios to failure conditions is `FHA.md`, section 8.1. |
| Which rule overrides any security convenience? | The governing principle: in flight, an untrusted input is dropped, counted and logged; it never reduces the flight-critical function (`security_architecture.md`, section 1; SECR-ARC-0002). |
| Who decides if a conflict arises between a security measure and a safety function? | The safety function wins. The measure is changed. |

**Change rule.** Re-open the named analysis when:

| Change | Re-open |
| :--- | :--- |
| A new entry point, interface or zone | `security_architecture.md` and `TARA.md` |
| A failure condition added or reclassified in `FHA.md` | `TARA.md`, section 3, severity column |
| A new message in the mission-bus ICD | `ICD_mission_bus.md`, `fsac_gw_1553`, `test_gw_1553.c` |
| A change to the manifest layout or to the order of boot checks | `secure_boot.md`, `fsac_secure_boot`, `test_secure_boot.c` |
| A real Root of Trust or crypto library chosen | `secure_boot.md`, section 8 and ADR-013 |

## 11. Document debt register

Corrections requested during the writing of Part 5 that were not yet applied, or applied only on request. Each should be closed before milestone M1.

| ID | File | Correction | State |
| :-: | :--- | :--- | :-: |
| D-01 | `fsac_secure_boot.h` | Set `FSB_IMAGE_ID_LAST` to `(8U)` so an eight-image manifest can exist | open |
| D-02 | `fsac_gw_1553.c` | Add `#include <stdbool.h>` before the project include | open |
| D-03 | `secure_boot.md`, rule AR-4 | Replace with: a counter advances to the manifest's value at commit; a `version_counter` more than one above the stored value is logged as a warning and does not refuse the boot | open |
| D-04 | `secure_boot.md`, SECR-BOOT-0004 | Replace with: no manifest field shall cause an acceptance or a counter change until the signature has verified; fields read earlier may only cause a refusal or select the verification key | open |
| D-05 | `secure_boot.md`, section 6.1 | Add a row 0, "caller passed a NULL or incomplete interface", reason `BAD_ARGUMENT` | open |
| D-06 | `secure_boot.md`, section 5.4 | Note that image IDs 5 to 8 are reserved placeholders | open |
| D-07 | `ICD_mission_bus.md`, section 6 | Swap rows 3 and 4: broadcast (`rej_broadcast`) before other address (`rej_address`) | open |
| D-08 | `ICD_mission_bus.md`, section 7 | Say the record holds the validated data words, the message ID, a sequence number and the minor-frame number, and neither the command word nor the raw bytes | open |
| D-09 | `ICD_mission_bus.md`, section 3 | Add the frame format paragraph (little-endian words, command word layout, no mode codes listed) | open |
| D-10 | `fsac_gw_1553.h` and the ICD note in D-09 | Replace the word-count-0 sentence: a transmit request with count 0 is not listed and ends as `REJ_NOT_LISTED`; a receive frame with count 0 implies 66 bytes and ends as `REJ_LENGTH` if that long, otherwise `REJ_FRAMING` | open |
| D-11 | `TARA.md`, section 4 | The residual table lists T-08, T-19, T-21 and T-23 under "Medium" but says 3; the count is 4 | open |
| D-12 | `TARA.md`, section 3 | Replace placeholder `FC-xx` references with IDs from `FHA.md`, section 8.1 | open |

The author will resend any of these files in full on request.

An optional consistency check from the repository root, once the patches are applied:

    grep -rn "FC-xx" docs/
    grep -rn "FSB_IMAGE_ID_LAST" software/hal_c/

The first should print nothing. The second should show the value 8U.

## 12. Requirements (placeholders to add to `docs/03_requirements/SEC/`)

| ID | Statement |
| :--- | :--- |
| SECR-PLAN-0001 | Every security measure shall name the threat scenarios it counters and the evidence that it works. |
| SECR-PLAN-0002 | Evidence shall be labelled proved, tested, reviewed, written or assumed, and shall not be described with a stronger label. |
| SECR-PLAN-0003 | A test result shall be recorded with the commit and the tool versions it was produced with. |
| SECR-PLAN-0004 | No private signing key shall be stored in the repository. |
| SECR-PLAN-0005 | The analyses named in section 10 shall be re-opened when the listed change occurs. |

## 13. What this plan does not cover

1. **A real certification.** There is no authority, no applicant and no aircraft programme.
2. **Independent review.** Section 7 says it is not met.
3. **The exact content of the DO-326A work products.** The names are recalled; the content is the author's interpretation.
4. **Numeric assurance levels.** See section 5.1.
5. **Continued airworthiness.** Handling vulnerabilities after delivery is out of scope.
6. **Hardware security.** The Root of Trust, fuses and side channels belong to a hardware plan (`HW_PHAC`), not written here.
7. **Penetration testing.** None is planned.