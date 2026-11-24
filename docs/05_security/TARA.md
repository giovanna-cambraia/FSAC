# FSAC: Threat Analysis and Risk Assessment (TARA)

| Item | Value |
| :--- | :--- |
| File | `docs/05_security/TARA.md` |
| Standards vocabulary | RTCA DO-326A / EUROCAE ED-202A (process), DO-356A / ED-203A (methods) |
| Inputs | `security_architecture.md` (zones, flows, assets A1-A8, entry points E1-E8, measures SM-01..SM-12), `FHA.md` (failure-condition severity) |
| Outputs | Risk per threat scenario, the measure that covers it, residual risk, requirements for `docs/03_requirements/SEC/` |
| Status | Preliminary risk assessment of a learning and portfolio project. **Not a certified security case.** Section 8 lists what it does not cover. |
| Placeholders | Every `FC-xx` reference is a placeholder until linked to the real `FHA.md`. Every likelihood value is a qualitative judgement, not a measured one. |

## 1. Method

The method follows the shape of the DO-326A preliminary security risk assessment, in five steps:

1. **Scenario**: an adversary (or an accident that looks like one) uses an entry point (E1-E8) to attack an asset (A1-A8).
2. **Safety effect**: what the attack can do to the aircraft, if the attack fully succeeds and no security measure works. This gives the *severity*.
3. **Likelihood (attack)**: how easy the attack is, given exposure and required capability, assuming *no measure*. This is the *threat likelihood*.
4. **Risk**: combination of severity and threat likelihood, before measures.
5. **Measures and residual risk**: which SM-xx measures counter the scenario, and what risk remains if those measures work as designed.

### 1.1 Severity: inherited, never invented

A security threat inherits the severity of the safety effect it can cause. This document does not define its own severity scale.

| Class | Meaning (summary) | FHA link |
| :--- | :--- | :--- |
| Catastrophic (CAT) | Loss of the aircraft, or conditions preventing continued safe flight and landing | `FC-xx` placeholder |
| Hazardous (HAZ) | Large reduction in safety margins or functional capability; serious or fatal injury to a small number of occupants | `FC-xx` placeholder |
| Major (MAJ) | Significant reduction in safety margins or capability; increased crew workload | `FC-xx` placeholder |
| Minor (MIN) | Slight reduction in margins or capability | `FC-xx` placeholder |
| No Safety Effect (NSE) | No effect on safety | none |

Context for this aircraft: it is aerodynamically unstable, and loss of stability leads to structural breakup in under 120 ms (24 frames). So **any attack that can corrupt or stop the control law in flight is rated CAT**.

### 1.2 Threat likelihood (before measures)

| Level | Meaning |
| :--- | :--- |
| Frequent | Attack needs no special access and little skill, and the entry point is exposed in normal operation |
| Probable | Needs access that a determined actor can obtain, or moderate skill |
| Remote | Needs physical access to the aircraft, or specialised skill and tools |
| Extremely remote | Needs insider access, or access to the supply chain or signing facility, plus specialised skill |

These levels are qualitative. They are justified one line at a time in section 3, so a reviewer can disagree with a single line instead of the whole table.

### 1.3 Risk matrix (before and after measures)

| Severity \ Likelihood | Extremely remote | Remote | Probable | Frequent |
| :--- | :-: | :-: | :-: | :-: |
| **CAT** | Medium | High | Unacceptable | Unacceptable |
| **HAZ** | Low | Medium | High | Unacceptable |
| **MAJ** | Low | Low | Medium | High |
| **MIN** | Acceptable | Low | Low | Medium |
| **NSE** | Acceptable | Acceptable | Acceptable | Acceptable |

Reading rule: a risk of Medium or above before measures needs at least one measure. After measures, the residual risk shall be Low or Acceptable, or be listed in section 7 as accepted with a reason.

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

Columns: **Sev** = severity if fully successful, **TL** = threat likelihood before measures, **R0** = risk before measures, **R1** = residual risk after measures work as designed.

### 3.1 Mission bus (E1, zone Z2, flow F1)

| ID | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-01 | AT-1 sends malformed frames (bad word count, bad sync, truncated) to crash or corrupt the gateway parser | A7 | Gateway crash or memory corruption could spread into Z0 | CAT | Probable | Unacceptable | SM-04 (strict parser), SM-03 (MPU isolation), SM-10 | Low |
| T-02 | AT-1 sends well-formed messages that are *not* on the whitelist | A7 | Unwanted data reaches the gateway output | MAJ | Probable | Medium | SM-04 (whitelist drops it) | Acceptable |
| T-03 | AT-1 sends whitelisted messages with out-of-range field values | A7 | Wrong data passed on to consumers of mission data | MIN | Probable | Low | SM-04 (range checks) | Acceptable |
| T-04 | AT-1 floods the bus to exhaust gateway CPU or buffers | A7, A4 | Gateway starved; if it shared resources with Z0, control loop delayed | CAT | Frequent | Unacceptable | SM-04 (rate limits, fixed output buffer), SM-03, SM-10, principle of section 1 of the architecture (Z0 does not depend on P6) | Low |
| T-05 | AT-1 tries to make the gateway read or write control state | A5, A4 | Direct corruption of control state | CAT | Probable | Unacceptable | SM-03 (P6 has no access to control state, MPU-enforced), one-way flows F4 | Low |
| T-06 | AT-1 replays an old valid message | A7, A8 | Stale mission data accepted | MIN | Probable | Low | SM-04 (sequence/age checks where the ICD defines them) | Acceptable |
| T-07 | Security reaction used as a weapon: AT-1 sends traffic designed to make the LRU stop or degrade ("make it defend itself to death") | A4, A5 | Self-inflicted loss of the flight function | CAT | Frequent | Unacceptable | **Architecture principle (section 1)**: in flight, only drop, count, log. SECR-ARC-0002 | Low |

T-07 is the scenario the governing principle exists for. The residual risk is Low only if the rule is truly implemented: no code path from a gateway anomaly to a mode change. That claim needs a test (listed in section 6).

### 3.2 Maintenance and data loader (E2, E7, zone Z3, flows F2, F5)

| ID | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-08 | AT-2 or AT-5 installs a modified OFP | A1 | Modified control law | CAT | Remote | High | SM-01, SM-02 (signed manifest), SM-05 (interlock), SM-12 | Medium |
| T-09 | AT-2 installs an old, validly signed OFP with a known flaw (rollback) | A1 | Known-vulnerable control law | CAT | Remote | High | SM-02 (anti-rollback counter) | Low |
| T-10 | AT-2 installs a modified parameter file (gains, limits) | A3 | Wrong gain on an unstable airframe | CAT | Remote | High | SM-08 (signed parameters, predicates as last gate), SM-05 | Low |
| T-11 | AT-2 opens a maintenance session in flight | A1, A3, A5 | Any of T-08..T-10, live | CAT | Remote | High | SM-05 (weight-on-wheels and armed switch, no session in flight) | Low |
| T-12 | AT-2 resets a health or mode latch through the maintenance session | A5 | A failed sensor is re-enabled | HAZ | Remote | Medium | SM-05, authenticated session; mode latch is one-way within a flight | Low |
| T-13 | AT-6: wrong but validly signed file loaded by mistake (wrong aircraft, wrong LRU) | A1, A3 | Control law or parameters do not match the airframe | HAZ | Probable | High | SM-02 manifest carries target identity; boot refuses a mismatch | Low |

T-08 stays at Medium even after measures. The reason is in section 7 (the signing facility is the single point of trust).

### 3.3 Debug and physical access (E3, E4, E8)

| ID | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-14 | AT-3 uses JTAG or UART to read memory or write code | A1, A2, A5 | Full compromise | CAT | Remote | High | SM-06 (debug fused off in production) | Low |
| T-15 | AT-3 injects or alters CCDL frames | A4, A5 | A fake or altered frame misleads the consensus | CAT | Remote | High | SM-07 (authentication code and sequence number), ADR-002 (fail-silent hardware) | Low |
| T-16 | AT-6: a babbling LRU floods the CCDL | A4 | Consensus delayed, loop timing disturbed | HAZ | Probable | High | SM-07, SM-10, bounded CCDL processing per frame | Low |
| T-17 | AT-3 uses voltage or clock glitching against the boot | A1, A2 | Boot verification skipped | CAT | Remote | High | Hardware Root of Trust (supplier matter). **Not analysed here.** | **Open** |

T-17 is listed so it is not forgotten. It is carried to section 7 as an open item, not rated.

### 3.4 Sensors and actuators (E5)

| ID | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-18 | AT-3 spoofs one sensor on a sensor bus | A4 | One wrong sensor value | CAT | Remote | High | Not cryptographic. Mid-value select and cross-check (Part 4) mask one faulty sensor; wired buses, physical segregation | Low |
| T-19 | AT-3 spoofs two sensors at once | A4 | Majority wrong, observer may be steered | CAT | Remote | High | Analytical redundancy (ADR-003) helps only partly; physical segregation | Medium |
| T-20 | AT-6: sensor bus corruption by EMI | A4 | Corrupted sample | HAZ | Probable | High | CRC and checks in the driver (Part 3), DO-160G for the hardware side | Low |

T-19 is honest about a limit: with three sensors, two wrong ones win the vote. The measures reduce the chance (segregation, plausibility checks, observer) but do not remove it.

### 3.5 Supply chain and build (E6)

| ID | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-21 | AT-4 compromises the compiler or a library | A1 | Malicious code in a correctly signed OFP | CAT | Extremely remote | Medium | SM-11 (pinned toolchain by hash, reproducible builds, SBOM) | Medium |
| T-22 | AT-5 modifies source in the repository | A1 | Malicious code | CAT | Extremely remote | Medium | Review, traceability, SM-11 (two builds of one commit must match) | Low |
| T-23 | AT-5 or AT-4 steals the private signing key | A2 | Attacker signs a valid OFP | CAT | Extremely remote | Medium | SM-12 (keys only in the signing facility, revocation by counter) | Medium |
| T-24 | Test keys left in a production image | A2 | Anyone with the test private key can sign | CAT | Probable | Unacceptable | SM-12 (test keys separate and labelled); boot rejects test-labelled keys in production configuration | Low |

T-24 is the cheapest to cause and the cheapest to prevent. It needs an explicit test: a production-configured boot shall refuse an image signed with a test key (listed in section 6).

### 3.6 Audit and log (A6)

| ID | Scenario | Asset | Safety effect | Sev | TL | R0 | Measures | R1 |
| :-: | :--- | :-: | :--- | :-: | :-: | :-: | :--- | :-: |
| T-25 | AT-1 floods the system with events to fill the log | A6 | Evidence lost; later events not recorded | MIN | Frequent | Medium | SM-09 (rate-limited security events) | Acceptable |
| T-26 | AT-2 edits or deletes log entries | A6 | Evidence of an incident removed | MIN | Remote | Low | SM-09 (hash chain makes tampering evident) | Acceptable |

## 4. Summary by risk

| R0 | Count | Scenarios |
| :--- | :-: | :--- |
| Unacceptable | 5 | T-01, T-04, T-05, T-07, T-24 |
| High | 12 | T-08, T-09, T-10, T-11, T-13, T-14, T-15, T-16, T-18, T-19, T-20 and T-17 (unrated, open) |
| Medium | 6 | T-02, T-12, T-21, T-22, T-23, T-25 |
| Low or Acceptable | 3 | T-03, T-06, T-26 |

| R1 (residual) | Count | Scenarios |
| :--- | :-: | :--- |
| Open (not analysed) | 1 | T-17 |
| Medium | 3 | T-08, T-19, T-21 and T-23 (see section 7) |
| Low or Acceptable | rest | |

*(Counts are for navigation. The scenario tables of section 3 are authoritative. Update the counts whenever a row changes.)*

## 5. Coverage: every entry point and every measure is used

| Entry point | Scenarios |
| :--- | :--- |
| E1 mission bus | T-01 to T-07 |
| E2 maintenance port | T-08 to T-13 |
| E3 debug | T-14 |
| E4 CCDL | T-15, T-16 |
| E5 sensor buses | T-18 to T-20 |
| E6 supply chain | T-21 to T-24 |
| E7 removable media | T-08, T-13 |
| E8 physical and EM | T-17, T-20 (T-20 only EMI, the rest DO-160G) |

| Measure | Counters |
| :--- | :--- |
| SM-01 | T-08 |
| SM-02 | T-08, T-09, T-13 |
| SM-03 | T-01, T-04, T-05 |
| SM-04 | T-01 to T-06 |
| SM-05 | T-08, T-10, T-11, T-12 |
| SM-06 | T-14 |
| SM-07 | T-15, T-16 |
| SM-08 | T-10 |
| SM-09 | T-25, T-26 |
| SM-10 | T-01, T-04, T-16 |
| SM-11 | T-21, T-22 |
| SM-12 | T-08, T-23, T-24 |

No measure is unused. Two scenarios (T-17, T-19) are not fully countered, and section 7 says so.

## 6. Verification each scenario needs (feeds Part 6)

| Verification | Scenarios | Where |
| :--- | :--- | :--- |
| Parser tests with malformed, truncated and oversized frames; deterministic fuzzing; coverage | T-01, T-02, T-03, T-04, T-06 | `test_gw_1553.c` (file 10 of this part) |
| Test that no gateway anomaly changes any mode or control output | T-07 | integration test, to design in Part 6 |
| Test that the gateway cannot reach control state (MPU map review) | T-05 | `software/config/memory_map/`, review |
| Boot decision tests: bad signature, old counter, wrong target, test key in production | T-08, T-09, T-13, T-24 | boot test with fake verifier (file 7 of this part) |
| Maintenance interlock test: no session without weight-on-wheels and armed switch | T-11, T-12 | `ICD_maintenance.md`, test later |
| Authenticated CCDL frame rejection tests | T-15, T-16 | `ICD_ccdl.md`, later |
| Reproducible build check: two builds identical | T-21, T-22 | `ci/gates.yaml` |
| Review of hardware debug fuse and key handling | T-14, T-23 | `HW_PHAC`, process review |

## 7. Residual risk and open items

| ID | Item | Why it remains | Decision |
| :-: | :--- | :--- | :--- |
| RR-01 | T-17 (glitching against the boot) | Hardware Root of Trust internals and side channels are a supplier and DO-254 matter | Open, carried to the supplier requirements |
| RR-02 | T-19 (two sensors spoofed) | Three sensors and a vote cannot mask two wrong ones | Accepted as a known limit; physical segregation and plausibility checks reduce but do not remove |
| RR-03 | T-08, T-23 (signing facility) | Every guarantee of the boot chain depends on the private key staying secret | Accepted for a learning project; a real programme needs a controlled signing facility and key ceremony |
| RR-04 | T-21 (toolchain) | Trust in compiler, libraries and silicon cannot be removed | Reduced by SM-11, accepted |
| RR-05 | Severity links | `FC-xx` references are placeholders | Close when `FHA.md` is linked |

## 8. What this document does not cover

1. **The real assurance-level mapping.** DO-356A / ED-203A associate risk with a security assurance level. The numeric levels and the objectives per level are not reproduced here, because inventing them would be worse than leaving them out. The risk matrix of section 1.3 is a project convention, not the standard's table.
2. **Quantitative likelihood.** Likelihood levels are judgements with one-line reasons, not measured data.
3. **Side channels and fault injection.** See RR-01.
4. **AFDX.** Only the 1553B path is analysed in detail.
5. **Other aircraft systems.** The compromise of another system on the mission bus is assumed (AT-1), not analysed.
6. **Continued airworthiness.** Handling of vulnerabilities after delivery is out of scope.
7. **Penetration testing.** None has been done.

## 9. Requirements (placeholders, to add to `docs/03_requirements/SEC/`)

| ID | Statement |
| :--- | :--- |
| SECR-TARA-0001 | Every security measure shall be traceable to at least one threat scenario of this document. |
| SECR-TARA-0002 | Every scenario with a risk of Medium or above before measures shall have at least one measure and one verification. |
| SECR-TARA-0003 | A boot image signed with a test key shall be refused by a production-configured boot. |
| SECR-TARA-0004 | No anomaly detected by the mission gateway shall change a mode, a latch or a control output. |
| SECR-TARA-0005 | This document shall be reviewed whenever a measure, an entry point or a failure condition in `FHA.md` changes. |