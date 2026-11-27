# FSAC: Threat Analysis and Risk Assessment (TARA)

| Item | Value |
| :--- | :--- |
| File | `docs/05_security/TARA.md` |
| Standards vocabulary | RTCA DO-326A / EUROCAE ED-202A (process), DO-356A / ED-203A (methods) |
| Inputs | `security_architecture.md` (zones, flows, assets A1-A8, entry points E1-E8, measures SM-01..SM-12), `docs/02_system/FHA.md` (failure-condition severity) |
| Outputs | Risk per threat scenario, the measure that covers it, residual risk, requirements for `docs/03_requirements/` |
| Status | Preliminary risk assessment of a learning and portfolio project. **Not a certified security case.** Section 8 lists what it does not cover. |
| Links to the FHA | Every scenario names the failure condition (`FC-xx`) of the **preliminary** FHA whose severity it inherits. If the FHA changes, the severities here change with it. |
| Qualitative values | Every likelihood is a judgement with a reason, not a measured value. |

## 1. Method

The method follows the shape of the DO-326A preliminary security risk assessment, in five steps:

1. **Scenario**: an adversary (or an accident that looks like one) uses an entry point (E1-E8) to attack an asset (A1-A8).
2. **Safety effect**: what the attack can do to the aircraft, if the attack fully succeeds and no *security* measure works. Safety mechanisms (voting, fail-silent hardware, fault detection) count as part of the aircraft: the class of a failure condition already includes them. This gives the *severity*.
3. **Likelihood (attack)**: how easy the attack is, given exposure and required capability, assuming *no security measure*. This is the *threat likelihood*.
4. **Risk**: combination of severity and threat likelihood, before measures (R0).
5. **Measures and residual risk**: which SM-xx measures counter the scenario, the likelihood after them, and the resulting risk (R1).

### 1.1 Severity: inherited, never invented

A security threat inherits the severity of the failure condition it can cause. This document does not define its own severity scale. The classes below are those of `FHA.md`, section 3, and each scenario names its failure condition in the `FC` column.

| Class | Meaning (summary) | Failure conditions of `FHA.md`, section 6 |
| :--- | :--- | :--- |
| Catastrophic (CAT) | Loss of the aircraft, or conditions preventing continued safe flight and landing | FC-01, FC-02, FC-05, FC-06, FC-09, FC-16, FC-21, FC-22, FC-24 |
| Hazardous (HAZ) | Large reduction in safety margins or functional capability; serious or fatal injury to a small number of occupants | FC-04, FC-07, FC-11, FC-12, FC-13, FC-14, FC-18, FC-25 |
| Major (MAJ) | Significant reduction in safety margins or capability; increased crew workload | FC-10, FC-15, FC-17, FC-19 |
| Minor (MIN) | Slight reduction in margins or capability | FC-03, FC-08, FC-20 |
| No Safety Effect (NSE) | No effect on safety | FC-23, and scenarios with no failure condition |

Context for this aircraft: it is aerodynamically unstable, and loss of stability leads to structural breakup in under 120 ms (24 frames). So **any attack that can corrupt or stop the control law in flight is rated CAT**.

### 1.2 Likelihood

| Level | Meaning |
| :--- | :--- |
| Frequent | Attack needs no special access and little skill, and the entry point is exposed in normal operation |
| Probable | Needs access that a determined actor can obtain, or moderate skill |
| Remote | Needs physical access to the aircraft, or specialised skill and tools |
| Extremely remote | Needs insider access, or access to the supply chain or signing facility, plus specialised skill |
| Improbable | **Used only after measures (R1).** The attack needs two independent protections to fail together, or it depends on one hardware protection that has no known bypass at this level of analysis. This is the author's judgement, and the Measures column gives the reason |

The first four levels are used before measures and are justified one line at a time in section 3. A scenario stays at "Extremely remote" after measures when one thing (for example the signing key) defeats every measure at once.

### 1.3 Risk matrix (before and after measures)

| Severity \ Likelihood | Improbable | Extremely remote | Remote | Probable | Frequent |
| :--- | :-: | :-: | :-: | :-: | :-: |
| **CAT** | Low | Medium | High | Unacceptable | Unacceptable |
| **HAZ** | Low | Low | Medium | High | Unacceptable |
| **MAJ** | Acceptable | Low | Low | Medium | High |
| **MIN** | Acceptable | Acceptable | Low | Low | Medium |
| **NSE** | Acceptable | Acceptable | Acceptable | Acceptable | Acceptable |

Reading rule: a risk of Medium or above before measures needs at least one measure. After measures, the residual risk shall be Low or Acceptable, or be listed in section 7 as accepted with a reason, or as open.

This matrix is a project convention chosen for this document. DO-356A / ED-203A define the real assurance-level mapping, and it is not reproduced here (see section 8).

## 2. Attacker model

| ID | Attacker | Capability | Typical entry points |
| :-: | :--- | :--- | :--- |
| AT-1 | Compromised aircraft system on the mission bus | Sends arbitrary messages on a shared bus, in flight | E1 |
| AT-2 | Ground crew with a stolen or infected laptop or media | Physical connector access, ground only | E2, E7 |
| AT-3 | Opportunist with physical access to the LRU | Tools, time, no inside knowledge | E3, E4 |
| AT-4 | Supply-chain attacker | Modifies a toolchain, library, or component before delivery | E6 |
| AT-5 | Insider | Legitimate access to build or signing process | E6, E2 |
| AT-6 | Accident that behaves like an attack | Bit flips, babbling node, wrong file loaded | E1, E4, E5, E7 |

AT-6 is included on purpose: several measures (CRC, authentication code, strict parsing) are justified as much by accidents as by adversaries.

## 3. Threat scenarios

Columns: **FC** = failure condition of `FHA.md` whose severity the scenario inherits, **Sev** = its class, **TL** = threat likelihood before measures, **R0** = risk before measures, **R1** = residual risk after the measures work as designed.

### 3.1 Mission bus (E1, zone Z2, flow F1)

| ID | FC | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-01 | FC-24, FC-23 | AT-1 sends malformed frames (bad word count, truncated, oversized) to crash or corrupt the gateway parser | A7 | Gateway crash or memory corruption could spread into Z0 | CAT | Probable | Unacceptable | SM-04 (strict parser), SM-03 (MPU isolation), SM-10 | Low |
| T-02 | FC-23 | AT-1 sends well-formed messages that are *not* on the whitelist | A7 | Unwanted advisory data reaches the gateway output; Z0 never reads it | NSE | Probable | Acceptable | SM-04 (the whitelist drops it) | Acceptable |
| T-03 | FC-23 | AT-1 sends whitelisted messages with out-of-range field values | A7 | Wrong advisory data accepted; no flight-critical function reads it | NSE | Probable | Acceptable | SM-04 (range checks, reserved words must be zero) | Acceptable |
| T-04 | FC-24, FC-07 | AT-1 floods the bus to exhaust gateway CPU or buffers | A7, A4 | Gateway starved; if it shared resources with Z0, the control loop is delayed | CAT | Frequent | Unacceptable | SM-04 (rate limit per message, fixed output ring), SM-03, SM-10, and Z0 does not depend on P6 | Low |
| T-05 | FC-24, FC-02 | AT-1 tries to make the gateway read or write control state | A5, A4 | Direct corruption of control state | CAT | Probable | Unacceptable | SM-03 (P6 has no access to control state, MPU-enforced), one-way flow F4 | Low |
| T-06 | FC-23 | AT-1 replays an old valid message | A7, A8 | Stale advisory data accepted | NSE | Probable | Acceptable | SM-04 (the rate limit bounds the replay rate; **no receive-side replay detection is defined in the ICD**, and transmit data is marked stale after a set age) | Acceptable |
| T-07 | FC-24 | Security reaction used as a weapon: AT-1 sends traffic designed to make the LRU stop or degrade ("make it defend itself to death") | A4, A5 | Self-inflicted loss of the flight function | CAT | Frequent | Unacceptable | Architecture principle (section 1 of `security_architecture.md`: in flight only drop, count, log), SM-04 (the gateway interface has no callback and no mode, so a rejection can only move a counter), SM-03 (Z0 does not read P6), SECR-ARC-0002 | Low |

Notes:

- **T-02, T-03 and T-06 are NSE** because `FHA.md` (FC-23) classes a gateway failure as having no safety effect while the isolation holds, and the data is advisory (P-4 of the ICD). The effect on consumers of mission data *other than the FSAC* is outside this FHA (`FHA.md`, section 9, item 2). If the real message set carries data that another system relies on, these three scenarios must be re-rated.
- **T-07** is the scenario the governing principle exists for. R1 is Low only if the rule is truly implemented: no code path from a gateway anomaly to a mode change. Half of that is shown by test: groups G-06 and G-13 of `test_gw_1553.c` check that every call moves exactly one counter and changes nothing else. The other half, that the mode logic is unaffected, needs the integration test listed in section 6.

### 3.2 Maintenance and data loader (E2, E7, zone Z3, flows F2, F5)

| ID | FC | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-08 | FC-21, FC-02 | AT-2 or AT-5 installs a modified OFP | A1 | Modified control law | CAT | Remote | High | SM-01, SM-02 (signed manifest), SM-05 (interlock), SM-12 | Medium |
| T-09 | FC-21 | AT-2 installs an old, validly signed OFP with a known flaw (rollback) | A1 | Known-vulnerable control law | CAT | Remote | High | SM-02 (anti-rollback counter in hardware, counter advances only at commit), SM-05 (installation only through the interlocked session) | Low |
| T-10 | FC-06 | AT-2 installs a modified parameter file (gains, limits) | A3 | Wrong gain on an unstable airframe | CAT | Remote | High | SM-08 (signed parameters, predicates as last gate), SM-05 | Low |
| T-11 | FC-22 | AT-2 opens a maintenance session in flight | A1, A3, A5 | Any of T-08 to T-10, live | CAT | Remote | High | SM-05 (weight-on-wheels and armed switch, no session in flight); SM-02 and SM-08 (even a session installs only signed files) | Low |
| T-12 | FC-14, FC-11 | AT-2 resets a health or mode latch through the maintenance session | A5 | A failed sensor is re-enabled, or the mode changes | HAZ | Remote | Medium | SM-05 (authenticated session); the mode latch is one-way within a flight and resets on the ground only (ADR-012) | Low |
| T-13 | FC-25 | AT-6: wrong but validly signed file loaded by mistake (wrong aircraft, wrong LRU) | A1, A3 | Control law or parameters do not match the airframe | HAZ | Probable | High | SM-02: the manifest carries the target identity and hardware revision, and the boot refuses a mismatch (check 6) | Low |

T-08 stays at Medium even after measures. The reason is in section 7 (the signing facility is the single point of trust).

### 3.3 Debug and physical access (E3, E4, E8)

| ID | FC | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-14 | FC-21 | AT-3 uses JTAG or UART to read memory or write code | A1, A2, A5 | Full compromise | CAT | Remote | High | SM-06 (debug fused off in production; a hardware measure whose inspection is not done, section 7, RR-06) | Low |
| T-15 | FC-05, FC-18 | AT-3 injects or alters CCDL frames | A4, A5 | A fake or altered frame misleads the consensus | CAT | Remote | High | SM-07 (authentication code and sequence number), ADR-002 (fail-silent hardware) | Low |
| T-16 | FC-18 | AT-6: a babbling LRU floods the CCDL | A4 | Consensus delayed, loop timing disturbed | HAZ | Probable | High | SM-07, SM-10, bounded CCDL processing per frame | Low |
| T-17 | FC-21 | AT-3 uses voltage or clock glitching against the boot | A1, A2 | Boot verification skipped | CAT | Remote | High | Hardware Root of Trust (supplier matter). **Not analysed here.** | **Open** |

T-17 is listed so it is not forgotten. It is carried to section 7 as an open item, not rated after measures.

### 3.4 Sensors and actuators (E5)

| ID | FC | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-18 | FC-08 | AT-3 spoofs one sensor on a sensor bus | A4 | One wrong sensor value, masked by the median (proof M1) | MIN | Remote | Low | Wired buses and physical segregation. Mid-value select and cross-check are safety mechanisms already counted in FC-08, and are not cryptographic | Acceptable |
| T-19 | FC-09 | AT-3 spoofs two sensors at once | A4 | Majority wrong, observer may be steered | CAT | Remote | High | Analytical redundancy (ADR-003) helps only partly; physical segregation | Medium |
| T-20 | FC-13 | AT-6: sensor bus corruption by EMI | A4 | Corrupted sample | HAZ | Probable | High | CRC and checks in the driver (Part 3, ADR-007), DO-160G for the hardware side | Low |

T-19 is honest about a limit: with three sensors, two wrong ones win the vote. The measures reduce the chance (segregation, plausibility checks, observer) but do not remove it.

### 3.5 Supply chain and build (E6)

| ID | FC | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-21 | FC-21, FC-02 | AT-4 compromises the compiler or a library | A1 | Malicious code in a correctly signed OFP | CAT | Extremely remote | Medium | SM-11 (pinned toolchain by hash, reproducible builds, SBOM) | Medium |
| T-22 | FC-21 | AT-5 modifies source in the repository | A1 | Malicious code | CAT | Extremely remote | Medium | Review, traceability, SM-11 (two builds of one commit must match) | Low |
| T-23 | FC-21 | AT-5 or AT-4 steals the private signing key | A2 | Attacker signs a valid OFP | CAT | Extremely remote | Medium | SM-12 (keys only in the signing facility, revocation by counter) | Medium |
| T-24 | FC-21 | Test keys left in a production image | A2 | Anyone with the test private key can sign | CAT | Probable | Unacceptable | SM-12 (test keys separate and labelled); the boot refuses a test-labelled key in a production lifecycle, whatever the signature (check 3, tested: group D-04 of `test_secure_boot.c`) | Low |

### 3.6 Audit and log (A6)

| ID | FC | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-25 | none | AT-1 floods the system with events to fill the log (entry point E1) | A6 | Evidence lost; later events not recorded. No direct safety effect | NSE | Frequent | Acceptable | SM-09 (rate-limited security events) | Acceptable |
| T-26 | none | AT-2 edits or deletes log entries (entry point E2) | A6 | Evidence of an incident removed. No direct safety effect | NSE | Remote | Acceptable | SM-09 (hash chain makes tampering evident) | Acceptable |

T-25 and T-26 have no failure condition: losing audit evidence does not by itself change what the aircraft does. FC-19 (loss of built-in test or annunciation) is a different thing, because flooding the security log does not stop built-in test. If a regulator requires the audit log to be a safety function, the FHA needs a new failure condition and these two rows must be re-rated.

## 4. Summary by risk

| R0 | Count | Scenarios |
| :--- | :-: | :--- |
| Unacceptable | 5 | T-01, T-04, T-05, T-07, T-24 |
| High | 11 | T-08, T-09, T-10, T-11, T-13, T-14, T-15, T-16, T-17, T-19, T-20 |
| Medium | 4 | T-12, T-21, T-22, T-23 |
| Low | 1 | T-18 |
| Acceptable | 5 | T-02, T-03, T-06, T-25, T-26 |

| R1 (residual) | Count | Scenarios |
| :--- | :-: | :--- |
| Open (not analysed) | 1 | T-17 |
| Medium | 4 | T-08, T-19, T-21, T-23 (see section 7) |
| Low | 15 | T-01, T-04, T-05, T-07, T-09, T-10, T-11, T-12, T-13, T-14, T-15, T-16, T-20, T-22, T-24 |
| Acceptable | 6 | T-02, T-03, T-06, T-18, T-25, T-26 |

*(Counts are for navigation. The scenario tables of section 3 are authoritative. Each set adds up to 26. Update the counts whenever a row changes.)*

## 5. Coverage: every entry point and every measure is used

| Entry point | Scenarios |
| :--- | :--- |
| E1 mission bus | T-01 to T-07, T-25 |
| E2 maintenance port | T-08 to T-13, T-26 |
| E3 debug | T-14 |
| E4 CCDL | T-15, T-16 |
| E5 sensor buses | T-18 to T-20 |
| E6 supply chain | T-21 to T-24 |
| E7 removable media | T-08, T-13 |
| E8 physical and EM | T-17, T-20 (T-20 only EMI, the rest DO-160G) |

| Measure | Counters |
| :--- | :--- |
| SM-01 | T-08 |
| SM-02 | T-08, T-09, T-11, T-13 |
| SM-03 | T-01, T-04, T-05, T-07 |
| SM-04 | T-01 to T-07 |
| SM-05 | T-08 to T-12 |
| SM-06 | T-14 |
| SM-07 | T-15, T-16 |
| SM-08 | T-10, T-11 |
| SM-09 | T-25, T-26 |
| SM-10 | T-01, T-04, T-16 |
| SM-11 | T-21, T-22 |
| SM-12 | T-08, T-23, T-24 |

No measure is unused. Two scenarios (T-17, T-19) are not fully countered, and section 7 says so.

## 6. Verification each scenario needs (feeds Part 6)

Status uses the labels of `PSecAC.md`, section 5.2: *tested* means a test passed on the owner's machine, *written* means the file exists and the owner has not recorded its numbers, *planned* and *not started* mean there is no evidence yet.

| Verification | Scenarios | Where | Status |
| :--- | :--- | :--- | :-: |
| Parser tests with malformed, truncated and oversized frames; deterministic fuzzing; coverage | T-01, T-02, T-03, T-04, T-06 | `software/hal_c/tests/test_gw_1553.c`, groups G-02 to G-05, G-07, G-13 | written; the owner reports it passing, numbers not recorded |
| Test that a rejection changes nothing but one counter | T-07 (gateway half) | same file, groups G-06 and G-13 | written; reported passing |
| Test that no gateway anomaly changes any mode or control output | T-07 (integration half) | integration test with the mode logic | planned |
| Test that the gateway cannot reach control state (MPU map review) | T-05 | `software/config/memory_map/`, review | not started (the map does not exist yet) |
| Boot decision tests: bad signature, old counter, wrong target, test key in production | T-08, T-09, T-13, T-24 | `software/hal_c/tests/test_secure_boot.c`, groups P-01 to P-04, D-01 to D-08, C-01, S-01 | **tested**: 846 passed, 0 failed; 100 percent line and branch coverage of `fsac_secure_boot.c`; against a fake verifier |
| Maintenance interlock test: no session without weight-on-wheels and armed switch | T-11, T-12 | `ICD_maintenance.md`, test later | not started |
| Authenticated CCDL frame rejection tests | T-15, T-16 | `ICD_ccdl.md`, later | not started |
| Reproducible build check: two builds identical | T-21, T-22 | `ci/gates.yaml` | not started |
| Review of hardware debug fuse and key handling | T-14, T-23 | `HW_PHAC`, process review | not started |

## 7. Residual risk and open items

| ID | Item | Why it remains | Decision |
| :-: | :--- | :--- | :--- |
| RR-01 | T-17 (glitching against the boot) | Hardware Root of Trust internals and side channels are a supplier and DO-254 matter | Open, carried to the supplier requirements |
| RR-02 | T-19 (two sensors spoofed) | Three sensors and a vote cannot mask two wrong ones | Accepted as a known limit; physical segregation and plausibility checks reduce but do not remove |
| RR-03 | T-08, T-23 (signing facility) | Every guarantee of the boot chain depends on the private key staying secret | Accepted for a learning project; a real programme needs a controlled signing facility and a key ceremony |
| RR-04 | T-21 (toolchain) | Trust in compiler, libraries and silicon cannot be removed | Reduced by SM-11, accepted |
| RR-05 | Severities come from the preliminary FHA | The FHA is itself a learning-project assessment, written from the architecture and not from a platform hazard list | Revisit every severity if a failure condition is added or reclassified (`PSecAC.md`, section 10) |
| RR-06 | The "Improbable" ratings of T-09, T-14 and T-15 rely on hardware (the monotonic counter, the debug fuse, the fail-silent LRU) that is specified, not built, and not inspected | The tests exercise the decision logic against a fake, not the hardware | Accepted for now; closes when the hardware plan (`HW_PHAC`) exists and the inspection is done |
| RR-07 | "Improbable" is a judgement | There is no measured likelihood | Each use names its reason in the Measures column; a reviewer may disagree one row at a time |

## 8. What this document does not cover

1. **The real assurance-level mapping.** DO-356A / ED-203A associate risk with a security assurance level. The numeric levels and the objectives per level are not reproduced here, because inventing them would be worse than leaving them out. The risk matrix of section 1.3 is a project convention, not the standard's table.
2. **Quantitative likelihood.** Likelihood levels are judgements with one-line reasons, not measured data.
3. **Side channels and fault injection.** See RR-01.
4. **AFDX.** Only the 1553B path is analysed in detail.
5. **Other aircraft systems.** The compromise of another system on the mission bus is assumed (AT-1), not analysed. The effect of the FSAC's mission data on those systems is outside the FHA (`FHA.md`, section 9, item 2).
6. **Continued airworthiness.** Handling of vulnerabilities after delivery is out of scope.
7. **Penetration testing.** None has been done.
8. **Audit evidence as a safety function.** See the note under section 3.6.

## 9. Requirements

The IDs are defined in `docs/03_requirements/requirements_index.md`, section 4. The statements are repeated here for reading.

| ID | Statement |
| :--- | :--- |
| SECR-TARA-0001 | Every security measure shall be traceable to at least one threat scenario of this document. |
| SECR-TARA-0002 | Every scenario with a risk of Medium or above before measures shall have at least one measure and one verification. |
| SECR-TARA-0003 | A boot image signed with a test key shall be refused by a production-configured boot. (Same content as `SECR-BOOT-0008`: it is satisfied by that requirement and verified once.) |
| SECR-TARA-0004 | No anomaly detected by the mission gateway shall change a mode, a latch or a control output. |
| SECR-TARA-0005 | This document shall be reviewed whenever a measure, an entry point or a failure condition in `FHA.md` changes. |

## 10. Revision history

| Revision | Change |
| :-: | :--- |
| 1 | First version. Severity placeholders (`FC-xx`), because `FHA.md` did not exist. |
| 2 | Written against the preliminary `FHA.md` and the tested code. **Failure conditions:** every scenario now names its `FC` from the FHA (D-12). **Severities re-rated to match the FHA:** T-02, T-03 and T-06 from MAJ or MIN to NSE (FC-23, advisory data that Z0 never reads); T-18 from CAT to MIN (FC-08, one sensor is masked by the median, which is a safety mechanism already inside the failure condition); T-25 and T-26 from MIN to NSE with no failure condition, because audit evidence has no direct safety effect. **Missing likelihood level:** revision 1 listed residual risks of Low for catastrophic scenarios, which the matrix could not produce; the level "Improbable" is now defined (1.2, 1.3) and its use is flagged as judgement (RR-07). **Counts:** the residual Medium count is 4 (D-11), and all counts were recomputed from the tables and add up to 26. **Measures:** T-07, T-09 and T-11 now list the second measure that their Low rating depends on. **Coverage:** T-25 and T-26 now appear under entry points E1 and E2, which revision 1 omitted. **Verification:** section 6 now has a status column and records the boot tests (846 passed) and the gateway tests (reported passing). **Residual items:** RR-05 reworded, RR-06 and RR-07 added. T-06 now says plainly that the ICD defines no receive-side replay detection. |