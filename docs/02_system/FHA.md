# FSAC: Functional Hazard Assessment (preliminary)

| Item | Value |
| :--- | :--- |
| File | `docs/02_system/FHA.md` |
| Standards vocabulary | SAE ARP4761A (FHA), ARP4754B (development assurance levels) |
| Scope | The FSAC function set and the failure conditions of one aircraft with three FSAC LRUs |
| Consumers | `TARA.md` (severity of security threats), `FDIR_timing_analysis.md`, ADR-009 to ADR-012, the compliance matrix (Part 6) |
| Status | **Preliminary FHA of a learning and portfolio project. It is not a certified safety assessment.** The aircraft-level hazards come from this document's own reasoning, not from a platform programme. Section 9 lists what it does not cover. |
| Placeholders | The probability budgets in section 3 are a civil-style framing. Every `FC-xx` ID is stable from now on; the classifications may change on review. |

## 1. Purpose

This is the document that gives each failure condition a severity. Severity drives three things:

1. the **development assurance level** of the software and hardware that can cause the condition,
2. the **probability budget** that the architecture must meet,
3. the **severity of a security threat** that can cause the same effect (`TARA.md`, section 1.1).

`TARA.md` currently uses placeholder references `FC-xx`. This file defines them.

## 2. Aircraft context

| Fact | Value | Source |
| :--- | :--- | :--- |
| Airframe | Aerodynamically unstable, long-range, bomber-class | Part 1 |
| Control rate | 200 Hz, minor frame 5 ms, major frame 20 ms | `fsac.ads` |
| Time to structural breakup after loss of stability | under 120 ms (24 frames) | `fsac.ads` |
| Architecture | Three LRUs, each a command lane and a monitor lane (ADR-001) | Part 1 |
| Degraded modes, one-way within a flight | Normal, Degraded_1, Degraded_2, Direct, Fail_Passive | ADR-012 |
| Loops built so far | Pitch rate only | Part 2 |

The last row matters: this FHA covers the whole **FSAC function**, but only the pitch-rate loop exists in software. Roll and yaw are covered by failure conditions written at function level, with no implementation evidence yet.

## 3. Severity classes and the probability budget used for framing

| Class | Short | Effect (summary) | Budget per flight hour (framing) | Assurance level |
| :--- | :-: | :--- | :-: | :-: |
| Catastrophic | CAT | Loss of the aircraft, or conditions preventing continued safe flight and landing | 1e-9 or lower | A |
| Hazardous | HAZ | Large reduction in safety margins or capability; serious or fatal injury to a small number of occupants | 1e-7 or lower | B |
| Major | MAJ | Significant reduction in safety margins or capability; crew workload increase | 1e-5 or lower | C |
| Minor | MIN | Slight reduction in safety margins or capability | not budgeted | D |
| No Safety Effect | NSE | No effect on safety | none | E |

These budgets are the commonly cited civil framing. A bomber-class military aircraft is governed by other requirements, so **the numbers are placeholders** and only the ordering of the classes is relied on by other documents. `DAL-A` for the control function matches the project target (DO-178C Level A).

## 4. Functions

| ID | Function | Implemented by |
| :-: | :--- | :--- |
| F-1 | Sense body rates, load factor, angle of attack and dynamic pressure | P1, driver (`fsac_sensor_ingest`) |
| F-2 | Validate and select sensor values (voting, fault detection) | P2, `signal_mgmt` |
| F-3 | Compute the control laws (pitch rate damper and later loops) | P3, `control` |
| F-4 | Command the actuators | P4, I/O FPGA |
| F-5 | Agree between the three LRUs and exchange state | P5, CCDL (not built) |
| F-6 | Select and latch the operating mode | `modes` |
| F-7 | Detect, annunciate and log faults (built-in test) | P8 |
| F-8 | Exchange advisory data with mission systems | P6 gateway |
| F-9 | Accept ground maintenance, software and parameter loading | P7 |
| F-10 | Protect the unit from unauthorised software and data (security) | secure boot, partition isolation |

## 5. Failure conditions

Phases used: **G** ground, **T** takeoff and landing, **C** cruise and manoeuvre. Effect text is the effect on the aircraft if no mitigation acts.

### 5.1 Loss and error of the control function

| ID | Failure condition | Function | Phase | Effect | Class | Mitigation (design) |
| :-: | :--- | :-: | :-: | :--- | :-: | :--- |
| FC-01 | **Loss of the stabilisation function on all axes, all three LRUs** (total and annunciated or not) | F-3, F-4 | T, C | Unstable airframe diverges; structural breakup in under 120 ms | CAT | Three independent LRUs; Direct and Fail_Passive modes; dissimilar monitor lane; independent power and hardware segregation |
| FC-02 | **Erroneous stabilisation command, not detected, on any axis** (wrong sign, wrong gain, saturated output) | F-3, F-4 | T, C | Wrong control surface motion on an unstable airframe; loss of control | CAT | Command and monitor lane comparison in the I/O FPGA; output limits and rate limits (proved, `Pitch_Rate_Damper`); fail-silent hardware (ADR-002) |
| FC-03 | **Loss of the stabilisation function on all axes of ONE LRU, annunciated** | F-3, F-4 | T, C | One of three channels lost; the other two continue | MIN | Fail-silent LRU; `Healthy_Lrus = 2` gives Degraded_1 (ADR-012, ADR-001) |
| FC-04 | **Loss of two of the three LRUs** | F-3, F-4, F-5 | T, C | One channel remains; no redundancy | HAZ | Direct or Fail_Passive mode as designed; crew workload increases; a further failure becomes FC-01 |
| FC-05 | **Erroneous output of ONE LRU that is not detected and not masked** | F-3, F-4, F-5 | T, C | One channel drives a wrong surface command | CAT | Command and monitor comparison, cross-LRU comparison (CCDL, not built), authenticated frames (ADR-002) |
| FC-06 | **Control law run with a wrong parameter set** (gains, limits, schedule) | F-3 | T, C | Correct code, wrong behaviour; for an unstable airframe as dangerous as wrong code | CAT | Signed parameters (SM-08), range predicates (`Pitch_Rate_Params`, `Voter_Params`), ground-only loading |
| FC-07 | **Control law timing violated** (a frame overrun or excessive jitter) | F-3 | T, C | Phase lag in the loop; reduced stability margin, possible divergence | HAZ | Cyclic schedule and budgets (Part 1, section 4), WCET analysis (not yet done) |

### 5.2 Sensing and signal management

| ID | Failure condition | Function | Phase | Effect | Class | Mitigation (design) |
| :-: | :--- | :-: | :-: | :--- | :-: | :--- |
| FC-08 | **One sensor of a triplex measurement fails** (hard failure or drift) | F-1, F-2 | T, C | Masked by the median; one fault cannot drag the output (proof M1) | MIN | Mid-value select, cross-check, leaky-bucket exclusion (ADR-009) |
| FC-09 | **Two sensors of one measurement fail**, or give wrong values together | F-1, F-2 | T, C | The majority is wrong; the control law may act on false data | CAT | Analytical redundancy (ADR-003, ADR-010), segregation, Direct mode on two lost sensors (ADR-009). **Not fully mitigated.** See section 7, item 2 |
| FC-10 | **Undetected error within the comparison threshold** | F-2 | T, C | Error up to T reaches the law as `Kq * T`, 20 to 30 percent of travel | MAJ | Threshold sized above healthy spread (ADR-009); accepted in Triplex and Duplex |
| FC-11 | **A failed sensor is re-admitted** | F-2 | C | A known-bad sensor feeds the vote again | HAZ | Failed is latched; reset on the ground only (ADR-012) |
| FC-12 | **Observer reference wrong or stale and used to exclude a healthy sensor** | F-2 | T, C | A healthy sensor wrongly excluded; redundancy lost | HAZ | Observer corrected only by trusted data, age limit, reference-aided frames never trusted (ADR-010, ADR-011) |
| FC-13 | **Invalid sensor sample accepted by the driver** (torn read, bad CRC, hardware flag) | F-1 | T, C | A bad sample enters the vote as if valid | HAZ | Eight ordered checks, value 0 when invalid, fail-closed flags (ADR-007) |

### 5.3 Modes, actuators and consensus

| ID | Failure condition | Function | Phase | Effect | Class | Mitigation (design) |
| :-: | :--- | :-: | :-: | :--- | :-: | :--- |
| FC-14 | **Mode improves or changes during flight without cause** (a latch reset in flight) | F-6 | C | Gains change on an unstable airframe; a failed sensor or LRU is trusted again | HAZ | Mode is `max(current, demand)`, one-way; reset on the ground only (ADR-012) |
| FC-15 | **Mode degrades on a single bad frame** (nuisance degradation) | F-6 | C | Reduced performance for the rest of the flight | MAJ | Persistence counters 4, 10 and 12 frames (ADR-012) |
| FC-16 | **Reduced-gain mode below the lower gain margin of the pitch loop** | F-3, F-6 | C | Lower gain, less stability: a reduced-gain mode can itself destabilise an unstable airframe | CAT | **Open.** The lower gain margin has not been computed. See section 7, item 1 |
| FC-17 | **Loss of one hydraulic system or one actuator** | F-4 | T, C | Reduced control authority | MAJ | Control allocation and reconfiguration (ADR-006). **Allocation is not built** |
| FC-18 | **CCDL failure: loss, corruption or injection of frames between LRUs** | F-5 | T, C | LRUs disagree or are misled; consensus fails | HAZ | Authenticated frames and sequence numbers (SM-07), fail-silent hardware (ADR-002). **CCDL is not built** |

### 5.4 Fault management, maintenance, mission and security

| ID | Failure condition | Function | Phase | Effect | Class | Mitigation (design) |
| :-: | :--- | :-: | :-: | :--- | :-: | :--- |
| FC-19 | **Loss of built-in test or fault annunciation** | F-7 | T, C | A latent fault goes unseen | MAJ | Built-in test, monitor lane, log (SM-09) |
| FC-20 | **Erroneous fault annunciation** (a false alarm) | F-7 | T, C | Crew response to a fault that does not exist | MIN | Persistence on annunciation |
| FC-21 | **Corrupted or unauthorised software or parameters installed or run** | F-9, F-10 | G, T, C | Modified control law: becomes FC-02 or FC-06 | CAT | Secure boot, signed manifest, anti-rollback (SM-01, SM-02); maintenance interlock (SM-05) |
| FC-22 | **Maintenance session opened in flight** | F-9 | C | Any of FC-21 or latch reset (FC-14), live | CAT | Weight-on-wheels and armed switch required (SM-05) |
| FC-23 | **Mission gateway fails, floods or is compromised** | F-8 | T, C | Z0 does not depend on P6; no effect on the control function if isolation holds | NSE | Partition isolation (SM-03), one-way flows, drop-count-log rule (security architecture, section 1) |
| FC-24 | **Mission gateway or mission data causes the flight function to stop or degrade** (a security reaction used as a weapon) | F-8, F-10 | C | Self-inflicted loss of the flight function | CAT | In flight, an untrusted input is dropped, counted and logged; it never changes a mode (SECR-ARC-0002, SECR-TARA-0004) |
| FC-25 | **Wrong software loaded to the right hardware** (wrong aircraft, wrong LRU, wrong hardware revision) | F-9 | G | Control law not matched to the airframe | HAZ | Target identity and hardware revision in the manifest, refused on mismatch (`secure_boot.md`, check 6) |

## 6. What each class means for assurance

| Class | Failure conditions | What follows |
| :--- | :--- | :--- |
| CAT | FC-01, FC-02, FC-05, FC-06, FC-09, FC-16, FC-21, FC-22, FC-24 | DAL A for the functions that can cause them; no single failure may cause the condition; the design must show independence |
| HAZ | FC-04, FC-07, FC-11, FC-12, FC-13, FC-14, FC-18, FC-25 | DAL B at least; the sensor driver and signal management are written to DAL A because they can contribute to a CAT condition |
| MAJ | FC-10, FC-15, FC-17, FC-19 | DAL C |
| MIN | FC-03, FC-08, FC-20 | DAL D |
| NSE | FC-23 | DAL E in principle. The gateway is kept at DAL C because it is the one place where hostile data enters (P6 is DAL C by design) |

## 7. Open items and honest limits

| ID | Item | Why it is open |
| :-: | :--- | :--- |
| FHA-OI-1 | **FC-16: the lower gain margin of the pitch loop is not computed.** The 0.70 and 0.50 mode scales in ADR-012 are valid only above that margin. Until it is known, FC-16 has no closed mitigation. | Needs a plant model and Monte Carlo or classical margin analysis (Part 6 and later, MIL work). |
| FHA-OI-2 | **FC-09: two wrong sensors beat a three-way vote.** Analytical redundancy and segregation reduce the chance; they do not remove it. | A known limit of triplex voting. The risk is accepted only if the common-cause analysis supports it. |
| FHA-OI-3 | **FC-17 and FC-18 have no implementation.** Control allocation and the CCDL are not built, so their mitigations are design intent. | Listed in the handoff as known gaps. |
| FHA-OI-4 | **FC-07: no WCET analysis.** The timing budget is a target, not a measurement. | Needs target hardware or a timing model. |
| FHA-OI-5 | **Roll and yaw loops do not exist.** FC-01, FC-02 and FC-05 are written for all axes. | Evidence covers pitch rate only. |
| FHA-OI-6 | **No common-cause analysis (CCA) or fault tree.** The independence claims (three LRUs, dissimilar lanes) are asserted, not analysed. | ARP4761A calls for CCA; it is the next safety document after this one. |
| FHA-OI-7 | **Probability budgets are civil framing.** | A military programme sets its own. |

## 8. Links to other documents

| Document | How it uses this file |
| :--- | :--- |
| `docs/05_security/TARA.md` | Replace each `FC-xx` placeholder with an ID from section 5. Suggested mapping in the table below. |
| `docs/02_system/FDIR_timing_analysis.md` | The latent-window argument supports FC-09 and FC-10. |
| ADR-007, ADR-009 to ADR-012 | Each ADR's mitigation row appears in section 5. |
| Compliance matrix (Part 6) | Each failure condition becomes a row with its evidence. |

### 8.1 Suggested mapping for the TARA placeholders

| TARA scenarios | Failure condition |
| :--- | :--- |
| T-01, T-04, T-05 (gateway compromise spreading into Z0) | FC-24, FC-23 |
| T-07 (security reaction used as a weapon) | FC-24 |
| T-08, T-09, T-10, T-14, T-21 to T-24 (modified software or parameters) | FC-21, FC-06 |
| T-11, T-12 (maintenance session in flight, latch reset) | FC-22, FC-14 |
| T-13 (wrong signed file loaded by mistake) | FC-25 |
| T-15, T-16 (CCDL injection or flooding) | FC-18, FC-05 |
| T-18, T-19 (sensor spoofing) | FC-08, FC-09 |
| T-20 (EMI corrupting a sensor bus) | FC-13 |
| T-25, T-26 (log flooding or tampering) | FC-19 |

## 9. What this document does not cover

1. **Aircraft-level hazards.** The classification here comes from the FSAC function, not from a platform hazard list. A real FHA is done at aircraft level first and flowed down.
2. **Other aircraft functions.** Nothing about engines, hydraulics, fuel or the crew interface other than their effect on the FSAC.
3. **Probability calculation.** No fault tree, no failure-rate data, no numeric result. The budgets in section 3 are framing only.
4. **Common-cause and zonal analysis** (FHA-OI-6).
5. **Pilot response.** Effects assume no crew recovery for CAT conditions; for HAZ and MAJ the crew-workload claims are not validated.
6. **Military airworthiness criteria.** The classification follows civil ARP4761A language.