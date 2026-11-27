# FSAC: Plan for Security Aspects of Certification (PSecAC)

| Item | Value |
| :--- | :--- |
| File | `docs/05_security/PSecAC.md` |
| Standards vocabulary | RTCA DO-326A / ED-202A (process), DO-356A / ED-203A (methods), DO-355 / ED-204 (continued airworthiness, named only) |
| Scope | The airworthiness security work of the FSAC project: what is done, in what order, with what evidence |
| Inputs | `security_architecture.md`, `TARA.md`, `docs/02_system/FHA.md`, `ICD_mission_bus.md`, `secure_boot.md`, `docs/03_requirements/requirements_index.md` |
| Status | **Plan of a learning and portfolio project, with a record of the evidence so far (revision 2). There is no certification authority, no applicant and no aircraft programme behind it.** It uses the structure of a PSecAC so the work can be reviewed the way a real one would be. |
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
| Safety context | An aerodynamically unstable airframe; the flight-critical function must never be reduced by a security reaction in flight (`security_architecture.md`, section 1). Severities come from `FHA.md`, which is itself a preliminary assessment. |
| Interfaces in scope | Mission bus (E1), maintenance and data loader (E2), debug (E3), CCDL (E4), sensor buses (E5), supply chain (E6), removable media (E7), physical and EM (E8) |
| What is built | **Secure boot** reader, decision and commit: implemented and tested against a fake verifier. **Mission-bus parser**: implemented; its test is written and reported passing. **Sensor driver**: implemented and tested. The CCDL, the maintenance session (P7), the log (P8), the hypervisor and the hardware are specified, not built. |
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
| Plan | This plan | `PSecAC.md` | written, revision 2 |
| Security scope definition | Scope | `security_architecture.md`, sections 2 to 4 | written |
| Preliminary risk assessment (aircraft and system level) | Threat and risk assessment | `TARA.md`, revision 2 (severities taken from `FHA.md`) | written |
| Security architecture | Measures and flows | `security_architecture.md`, section 5 | written |
| Security requirements | `SECR-*` IDs | `docs/03_requirements/requirements_index.md`, section 4 (25 statements) | written; 6 further proposals not adopted |
| Implementation | Code of the measures | `fsac_secure_boot`, `fsac_gw_1553` | written |
| Security effectiveness: verification | Tests, links and reviews | section 6 of this file | in progress |
| Security effectiveness: independent review | None possible | section 7 | not met |
| Compliance summary | Compliance matrix, security rows | `docs/07_cert_data/` (Part 6) | planned |
| Continued airworthiness | none | | not covered |

## 5. Assurance approach

### 5.1 Level of assurance

DO-356A / ED-203A associate a security risk with a security assurance level. **The levels and their objectives are not reproduced in this project.** The risk matrix in `TARA.md`, section 1.3, is a project convention, not the standard's table.

The working rule used instead:

| Rule | Statement |
| :-: | :--- |
| A-1 | Any measure that counters a scenario with a risk of Medium or above before measures gets at least one test and one review. |
| A-2 | Any code that touches untrusted bytes (the manifest reader, the bus parser) is written to the same coding rules as the flight-critical C (C11, MISRA C:2012 style) and tested against malformed input with a deterministic fuzz campaign. |
| A-3 | Evidence is labelled: **proved**, **tested**, **reviewed**, **assumed** or **written**. No evidence is described with a stronger word than it earned. |

### 5.2 What counts as evidence

| Label | Meaning | Example today |
| :--- | :--- | :--- |
| Proved | A tool showed it for all inputs within stated assumptions | GNATprove: 218 checks, all proved, for the SPARK core, signal management, modes and the bridge |
| Tested | A repeatable test passed on the owner's machine, output pasted | `test_secure_boot`: 846 passed, 0 failed |
| Reviewed | A person read it against a checklist | none yet |
| Written | Exists in the repository, but the owner's run is not recorded here with numbers | the gateway tests (the owner reports them passing; the numbers are not recorded) |
| Assumed | Stated as a precondition, not checked here | the crypto library and the Root of Trust behave as `secure_boot.md`, section 8 lists |

## 6. Activities and verification

Evidence status as of this revision. "Tested" always means against the fakes and fixtures named in the row, on the owner's machine.

| Activity | Counters (TARA) | Evidence | Status |
| :--- | :-: | :--- | :-: |
| Strict manifest reader and boot decision tests | T-08, T-09, T-13, T-24 | `software/hal_c/tests/test_secure_boot.c`, groups P-01 to P-04, D-01 to D-08, C-01, S-01 | **tested**: 846 passed, 0 failed, fake verifier |
| Manifest tamper sweep (every bit of the manifest flipped) | T-08 | group D-05 | **tested** (the sweep found a flaw in the first fake; section 7.1) |
| Production refuses a test key | T-24 | group D-04 | **tested** |
| Anti-rollback and commit rules | T-09 | groups D-06, C-01, S-01 | **tested** |
| Structural coverage of `fsac_secure_boot.c` | all of the above | `gcov` | **tested**: 100 percent of 121 lines, 100 percent of 122 branches |
| Gateway parser tests per ICD row | T-01 to T-06 | `software/hal_c/tests/test_gw_1553.c`, groups G-02 to G-05, G-07 to G-12 | written; reported passing, numbers not recorded |
| Length sweep with exact allocation | T-01 | group G-05 | written; reported passing; sanitizer run not done |
| Deterministic fuzz campaign, 200000 frames | T-01 | group G-13 | written; reported passing |
| A rejection only moves a counter (gateway half of the claim) | T-07 | groups G-06 and G-13 | written; reported passing |
| Structural coverage of `fsac_gw_1553.c` | | `gcov` | not recorded |
| Run of the boot and gateway tests under a memory sanitizer | T-01 (`SECR-GW-0002`, `SECR-BOOT-0003`) | needs a Linux or WSL run | not done |
| MISRA tool check of `fsac_secure_boot` and `fsac_gw_1553` | | no tool run | not done |
| Trace links for the security requirements | all | `traceability/links/security.links`, `traceability/trace_check.py` | **run**: 1 link file, 0 errors, every path and anchor resolves. The checker verifies links, not results, and is not a qualified tool |
| Test that no gateway anomaly changes any mode or control output | T-07 (integration half) | integration test with `modes` | planned (Part 6 and later) |
| Review of the memory map for P6 against control state | T-05 | `software/config/memory_map/` | not started (the map does not exist yet) |
| Maintenance interlock test | T-11, T-12 | needs `ICD_maintenance.md` | not started |
| Authenticated CCDL frame tests | T-15, T-16 | needs `ICD_ccdl.md` | not started |
| Reproducible build check | T-21, T-22 | `ci/gates.yaml` | not started |
| Review of hardware debug fuse and key handling | T-14, T-23 | `HW_PHAC`, process review | not started |
| Repository scan for private signing keys (`SECR-PLAN-0004`) | T-23 | a scan of the repository | not done |
| Penetration test | all | none | not planned |

### 6.1 Verification record at this revision

The full record belongs to the verification campaign document (Part 6). This is a snapshot, so no number is only in chat.

| Run | Result |
| :--- | :--- |
| GNATprove, `fsac_core.gpr` | **218 checks, all proved** |
| `test_core` | 127 passed, 0 failed |
| `test_signal_mgmt` | 201 passed, 0 failed |
| `test_bridge` | 39 passed, 0 failed |
| `test_sensor_ingest` | 154 passed, 0 failed |
| `test_secure_boot` | **846 passed, 0 failed** (first run 845 and 1 failed, section 7.1) |
| Coverage of `fsac_secure_boot.c` | lines 100 percent of 121, branches 100 percent of 122, taken 100 percent, calls 100 percent of 38 |
| `test_gw_1553` | reported passing; numbers not recorded |
| `trace_check.py` | 173 IDs seen, 25 defined, 148 undefined, 1 link file, 0 errors |

| Environment | Value |
| :--- | :--- |
| Commit | `fa03aba`, **plus changes not committed at the time**: the gateway test file, the corrections of section 11 and the fixed fake verifier. The tag of milestone M1 will fix this. |
| Platform | Windows, Git Bash (MINGW64) |
| Compiler | GCC (GNAT-FSF-builds) 16.1.0 |
| Prover | GNATprove FSF 16.1.0 |
| Build tool | GPRbuild 26.0.0 (2026-04-15) |

One result is unexplained: GNATprove reports 218 checks where the assistant's notes predicted 216. Every check proved, which is the property that matters, but the difference of two has no known cause.

## 7. Organisation, independence and the origin of the data

| Topic | Statement |
| :--- | :--- |
| People | One developer owns the repository. |
| Independence | Real DO-326A and DO-178C practice needs reviewers independent of the author. **That is not met here** and cannot be in a single-developer project. |
| Compensation | Every file is built, run and checked by the owner on their own machine; results are pasted, not assumed. Documents list their own open items. |
| AI assistance | Most files of Part 5 and Part 6 were drafted with an AI assistant. The assistant did not run the final versions of its files, so a file whose run is not recorded is labelled "written". |
| Consequence | A reviewer should treat "written" as a claim about intent, and only "tested" or "proved" as evidence. |

### 7.1 Defects found by running, not by writing

The assistant's files contained errors that reading did not catch and running did. They are listed because they show what the method found, and what remains hidden in files that have not been run.

| Found by | Defect | In | Fix |
| :--- | :--- | :--- | :--- |
| Compiling the gateway | `bool` used without `#include <stdbool.h>` | `fsac_gw_1553.c` | include added |
| The tamper sweep of group D-05 | The fake signature could be fooled: a change of `key_id` cancelled a change of data, so a tampered manifest still "verified" | `test_secure_boot.c` (the fake, not the code under test) | the key handle is now written into the signature bytes; 846 checks pass |
| First run of the trace checker | It found none of the 25 definitions (the table separator pattern was too strict) and counted markdown outside `docs/` as implementation | `trace_check.py` | both fixed |
| Reading the checker's output | The "tested" column counts header citations, so it overstates coverage (`SECR-ARC` showed tested 2 while `SECR-ARC-0001` has no test) | `trace_check.py` | a `links` column was added; the compliance matrix uses links only |
| Writing the code against the documents | Several documents contradicted the code: the order of the broadcast and address checks, the rule on counter jumps, the claim that no field is used before the signature, image IDs that made an eight-image manifest impossible | `ICD_mission_bus.md`, `secure_boot.md`, `fsac_secure_boot.h` | corrected (section 11) |
| Applying the file layout | Documents named folders that do not exist in the repository | several | corrected (section 11, D-13) |

## 8. Schedule and milestones

Milestones follow the project's parts and git tags. No calendar dates are promised.

| Milestone | Content | Suggested tag | Done when |
| :--- | :--- | :--- | :--- |
| M1 | Security documents and code of Part 5 | `part5-security` | the corrections of section 11 are applied and the gateway test numbers are recorded. The three runs are otherwise done |
| M2 | FHA, this plan, requirements index, trace checker and link files | `part6-docs` | the files exist and the checker reports no error. **Not yet: the HLR statements are not written** |
| M3 | Compliance matrix and verification campaign plan | `part6-compliance` | every row has a status, none hides a gap. Files go in `docs/07_cert_data/` |
| M4 | Maintenance session (P7) and CCDL specification | none yet | `ICD_maintenance.md` and `ICD_ccdl.md` written |
| M5 | First security review by someone other than the author | none yet | a written review exists |

## 9. Configuration management and change control

| Item | Rule |
| :--- | :--- |
| Baseline | A git tag per milestone. A test result belongs to the commit it was run on; results from another commit do not count. Section 6.1 records the commit and what was uncommitted. |
| Signing keys | No private signing key is ever in the repository (`secure_boot.md`, K-1). Test keys are generated locally by a script. A scan to confirm this is not done (section 6). |
| FPGA bitstream | ADR-007 requires the bitstream version to be recorded with the software baseline. This goes in the configuration index (Part 6). |
| Toolchain | Pinned by hash when `ci/docker/` exists (SM-11). Until then, the compiler version used for each run is recorded with its output (section 6.1). |
| Generated files | Coverage files, test executables and `trace_matrix.csv` are not committed (`.gitignore`). |
| Change impact | See section 10. |

## 10. Interaction with safety and the change rule

| Question | Answer |
| :--- | :--- |
| Where does a security threat get its severity? | From `FHA.md`, section 5. Each `TARA.md` scenario names its failure condition, and the mapping is `FHA.md`, section 8.1. |
| Which rule overrides any security convenience? | The governing principle: in flight, an untrusted input is dropped, counted and logged; it never reduces the flight-critical function (`security_architecture.md`, section 1; SECR-ARC-0002). |
| Who decides if a conflict arises between a security measure and a safety function? | The safety function wins. The measure is changed. |

**Change rule.** Re-open the named analysis when:

| Change | Re-open |
| :--- | :--- |
| A new entry point, interface or zone | `security_architecture.md` and `TARA.md` |
| A failure condition added or reclassified in `FHA.md` | `TARA.md`, section 3, severity column, and `FHA.md`, section 8.1 |
| A new message in the mission-bus ICD | `ICD_mission_bus.md`, `fsac_gw_1553`, `test_gw_1553.c` |
| A change to the manifest layout or to the order of boot checks | `secure_boot.md`, `fsac_secure_boot`, `test_secure_boot.c` |
| A real Root of Trust or crypto library chosen | `secure_boot.md`, section 8 and ADR-013 |
| A requirement added, adopted or withdrawn | `requirements_index.md`, `traceability/links/security.links` |

## 11. Document debt register

Corrections requested during the writing of Part 5. A resent file closes an item **when the owner has replaced the old copy**; the assistant cannot see the repository, so those items stay "to confirm" until the owner says so.

| ID | File | Correction | State |
| :-: | :--- | :--- | :-: |
| D-01 | `fsac_secure_boot.h` | Set `FSB_IMAGE_ID_LAST` to `(8U)` so an eight-image manifest can exist | closed (checked in the repository) |
| D-02 | `fsac_gw_1553.c` | Add the `stdbool.h` include | closed (the file compiles and its test runs) |
| D-03 | `secure_boot.md`, rule AR-4 | A counter advances to the manifest's value at commit; a jump of more than one is a warning, not a refusal | fixed in revision 2 of the file; to confirm |
| D-04 | `secure_boot.md`, `SECR-BOOT-0004` | Fields read before the signature may only refuse or select the key | fixed in revision 2 of the file and in the index; to confirm |
| D-05 | `secure_boot.md`, section 6.1 | Row 0, `BAD_ARGUMENT` | fixed in revision 2; to confirm |
| D-06 | `secure_boot.md`, section 5.4 | Image IDs 5 to 8 are reserved placeholders | fixed in revision 2; to confirm |
| D-07 | `ICD_mission_bus.md`, section 6 | Broadcast checked before other addresses | fixed in revision 2; to confirm |
| D-08 | `ICD_mission_bus.md`, section 7 | The record holds the validated words, not the command word or raw bytes | fixed in revision 2; to confirm |
| D-09 | `ICD_mission_bus.md`, section 3 | Frame format added (section 3.1) | fixed in revision 2; to confirm |
| D-10 | `ICD_mission_bus.md` and `fsac_gw_1553.h` | Word count 0: a transmit request is not listed; a receive frame implies 66 bytes | **half open**: fixed in the ICD (revision 2); the comment in `fsac_gw_1553.h` still has the old sentence |
| D-11 | `TARA.md`, section 4 | The count of Medium residuals is 4 | fixed in revision 2; to confirm |
| D-12 | `TARA.md`, section 3 | Real failure-condition IDs instead of the placeholders | fixed in revision 2; to confirm |
| D-13 | several | Folder names: the repository uses `secure_boot_loader` and `mission_gateway` | **partly open**: fixed in `secure_boot.md`; the file banners of `fsac_secure_boot.c` and `fsac_gw_1553.c`, and the build comments of `test_secure_boot.c` and `test_gw_1553.c`, still name the old folders |
| D-14 | `test_secure_boot.c` | The fake signature could be fooled by a key change | closed (846 checks pass) |
| D-15 | `requirements_index.md`, section 5.1 | Six gateway rules and the boot restart rule are proposed, not adopted | open: an owner decision |
| D-16 | `FHA.md`, section 8.1 | Replace the TARA mapping table with the corrected one | to confirm |
| D-17 | `trace_check.py` | Search subfolders for link files (`rglob`), and the optional warning when no link file exists | to confirm |

## 12. Requirements

The IDs are defined in `docs/03_requirements/requirements_index.md`, section 4. The statements are repeated here for reading.

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
8. **Tool qualification.** The trace checker, the test programs and the fakes are review aids. None is a qualified tool.
9. **Static analysis by a MISRA tool, and sanitizer runs.** Neither is done (section 6).

## 14. Revision history

| Revision | Change |
| :-: | :--- |
| 1 | First version: plan only, all evidence "written". |
| 2 | **Evidence statuses** changed to what ran: the boot code is tested (846 checks, 100 percent coverage, fake verifier), the gateway is written and reported passing, the trace checker and link file are run. **Section 6** gained the rows for coverage, the sanitizer run, the MISRA tool check, the key scan and the links. **Section 6.1** records the runs, the commit and the tool versions, and the unexplained GNATprove count. **Section 7.1** added: the defects found by running. **Section 5.2** gives today's example for each label. **Section 9** records the generated files that are not committed. **Section 11** brought up to date (D-01 to D-14) and extended (D-15 to D-17). **Section 8** moves the compliance documents to `docs/07_cert_data/` and says M2 is not done. |