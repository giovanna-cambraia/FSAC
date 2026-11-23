# FSAC: FDIR Timing and Parameter Analysis (Part 4)

| Item | Value |
| :--- | :--- |
| File | `docs/02_system/FDIR_timing_analysis.md` |
| Covers | `Cross_Check`, `Observer`, `Voter`, `Modes` (Part 4) and the C driver policies OD-02, OD-03 (Part 3) |
| Purpose | Say WHERE each number comes from, which constraints bind it, and what is still unknown |
| Decisions recorded in | ADR-009, ADR-010, ADR-011, ADR-012 (`docs/02_system/architecture/adr/`) |
| Status | **Every numeric value in this document is a placeholder** derived from the assumptions in section 1. The structure of the argument is the deliverable; the numbers are to be replaced by sensor, plant and safety-assessment data. |

## 0. How to read this document

Part 4 contains a handful of numbers that look arbitrary in the code: 0.10 rad/s, 8 frames, 4, 10, 12, 0.70, 0.50. This document does three things for each of them:

1. states the **constraint** that bounds it from below and from above,
2. shows the **arithmetic** that picks a value inside those bounds,
3. names the **test** that pins the value, so a change cannot go unnoticed.

Where an argument depends on data that does not exist yet, that dependency is listed in section 9 instead of being hidden in a number.

## 1. Assumptions (all to be replaced by real data)

| ID | Assumption | Value used | Source to replace it with |
| :--- | :--- | :--- | :--- |
| A1 | Frame period | 5 ms (200 Hz) | fixed by the architecture |
| A2 | Time to structural breakup after loss of control | 120 ms = 24 frames | system requirement SYS-SAF-0001 |
| A3 | Failure rate of one rate sensor (illustrative) | 1e-4 per flight hour | sensor FMEA / supplier data |
| A4 | Sensor noise, 1 sigma | 0.0017 rad/s (about 0.1 deg/s) | sensor data sheet |
| A5 | Scale-factor mismatch between two sensors | 0.5 percent of full range (8 rad/s) | calibration and drift data |
| A6 | Skew between the three sample instants | 1 ms | FPGA latch design (HSI spec) |
| A7 | Maximum pitch acceleration | 5 rad/s^2 | plant model, 6-DOF |
| A8 | Structural-flex contribution to a rate sensor | 0.02 rad/s | structural analysis |
| A9 | Proportional gain scheduled range | 0.5 .. 3.0 | control-law design |
| A10 | Airframe free response over one frame (observer A) | 1.01 | plant identification |
| A11 | Actuator reversion to hold, after a hardware disable | at most 30 ms | actuator specification |

## 2. The timing fact that shapes everything: detection speed does not save the first fault

With three usable sensors the median masks one fault from the first frame (property M1, proved in `Mid_Value_Select`). Therefore:

- **The speed of detection is not what protects the airframe from a first fault.** The vote already does.
- **What detection speed controls is the latent window**: the time during which a known-bad sensor still votes. A second fault inside that window defeats the median.

So the persistence time P (frames) is not a response-time requirement. It is a trade between:

- **P too small:** a transient or noise burst blames a good sensor and spends redundancy for the rest of the flight (the exclusion is latched).
- **P too large:** a longer latent window.

### 2.1 Size of the latent window

Probability that one of the two remaining sensors also fails during the window, given a first fault (illustrative, A3):

```
P(second | first) = 2 * lambda * (P * 5 ms)
```

| Persistence P | Window | P(second fault in window | first fault) | Rate of losing the masking [per flight hour] |
| :-: | :-: | :-: | :-: |
| 4 | 20 ms | 1.1e-9 | 3.3e-13 |
| **8** | **40 ms** | **2.2e-9** | **6.7e-13** |
| 12 | 60 ms | 3.3e-9 | 1.0e-12 |
| 24 | 120 ms | 6.7e-9 | 2.0e-12 |

The last column is `3 * lambda * P(second | first)`: the first fault can be any of the three sensors.

**Reading.** The window contributes between 3e-13 and 2e-12 per flight hour for lambda = 1e-4. That is three orders of magnitude below a typical catastrophic target of 1e-9, and it grows only linearly with P. **The window is not what limits P.** The false-trip side (section 4) is.

**Limit of this calculation.** It assumes independent failures. A common cause (a shared supply, a shared connector, lightning) can fail two sensors together, and no window length helps against it. That is handled by physical segregation (Part 1, section 5), not by this parameter.

## 3. The comparison threshold T (`Cross_Check`, default 0.10 rad/s = 6554 raw)

Two readings "agree" when they differ by at most T.

### 3.1 Lower bound: what a healthy pair can differ by

| Contribution | Value [rad/s] | From |
| :--- | :-: | :--- |
| Noise, 6 sigma | 0.0102 | A4 |
| Scale-factor mismatch | 0.0400 | A5 (0.5 % of 8 rad/s) |
| Sample skew, 1 ms at 5 rad/s^2 | 0.0050 | A6, A7 |
| Structural flex | 0.0200 | A8 |
| **Linear sum (worst case)** | **0.0752** | |

T below 0.0752 would blame healthy sensors during a hard manoeuvre. T = 0.10 leaves **25 percent margin** over the worst-case sum. (A root-sum-square would give a smaller floor, but the contributions are not independent at the extremes, so the linear sum is the conservative choice.)

### 3.2 Upper bound: what an undetected error costs

A sensor error smaller than T is never flagged. It reaches the control law, and the command error is the gain times the rate error.

| T [rad/s] | Command error, Kq = 2.0 | Command error, Kq = 3.0 (A9, top of the schedule) | Duplex midpoint error, T/2, Kq = 2.0 |
| :-: | :-: | :-: | :-: |
| 0.050 | 0.10 | 0.15 | 0.05 |
| 0.075 | 0.15 | 0.22 | 0.07 |
| **0.100** | **0.20** | **0.30** | **0.10** |
| 0.150 | 0.30 | 0.45 | 0.15 |

**Reading.** T = 0.10 accepts that an undetected error can move the command by 20 to 30 percent of full travel. That is large. It is acceptable only because:

- in Triplex the median masks the error whenever it is not shared by two sensors (M1), so the worst-case column applies to the Simplex and Duplex levels;
- in Duplex the midpoint halves the error.

**Consequence for the design.** The region of real exposure is Simplex. That is why the mode logic treats two failed sensors as `Direct` (low gain, low authority) and not as a mild degradation.

### 3.3 Decision

T = 0.10 rad/s, with a 25 percent margin over the worst-case healthy difference (ADR-009). Pinned by test **XC-03** (a difference of exactly 6554 agrees; 6555 does not).

## 4. The persistence P (default 8 frames = 40 ms)

### 4.1 Lower bound: transients that must not blame a good sensor

The counter is a leaky bucket: it rises by 1 on each frame where the sensor is the located outlier and falls by 1 on each agreeing frame. A good sensor that deviates by more than T for D frames during a transient fills the bucket to D and then drains it. It is never blamed if

```
P > D
```

A structural-flex or gust transient of 4 frames (20 ms) is plausible (A8). P = 8 gives a factor of two over it.

### 4.2 Upper bound: the latent window

Section 2.1: nothing forces P below about 12 frames. The other upper bound is the coupling with the observer (section 6).

### 4.3 A property worth stating: the 50 percent hole

A leaky bucket fills at a net rate of (bad frames minus good frames). A sensor wrong **exactly half of the time** stays level and is never excluded. This is a known limit of the design, pinned by test **XC-09b**. A sensor wrong more than half the time (3 frames out of 4, test XC-09a) is caught. Closing the hole needs a different counter (for example a sliding window); it is recorded as an open item (section 9).

### 4.4 Decision

P = 8 (ADR-009). Pinned by tests **XC-04a/b** (suspect for 7 frames, failed on the 8th) and **XC-10** (limits 1 and 24).

## 5. Reference-aided voting (`Voter`)

With two usable sensors that disagree, the midpoint is wrong by half the gap, and `Cross_Check` needs P frames before it can exclude the bad one. The `Voter` therefore publishes the **other** sensor's reading as soon as the reference locates the outlier, and reports the level as Simplex (one effective source).

Two rules keep this from making things worse:

1. **A reference-aided frame is never trusted for the observer.** The reference chose the sensor; letting that sensor correct the reference would be positive feedback.
2. **The reference only breaks a tie when exactly one sensor is within T of it.** A wrong observer cannot exclude a sensor on its own.

Pinned by tests **VT-05, VT-09, VT-11**.

## 6. The coupling that the type enforces: `Persistence - 1 <= Max_Age`

### 6.1 The argument

Reference-aided frames are untrusted, so the observer ages by one frame per frame while it is waiting for the outlier's counter to fill. Its reference is valid while `Age <= Max_Age`. The outlier needs P located frames. At the start of located frame k (k = 0 .. P-1) the age is k. For every one of those frames to have a valid reference:

```
P - 1  <=  Max_Age
```

If this is violated, the reference expires before the outlier is excluded; the decision becomes Unresolved; the counter stops; **the sensor is never excluded** and the output returns to the contaminated midpoint. The two parameters look independent and are not.

### 6.2 Enforcement

This is a `Dynamic_Predicate` of `Voter_Params` (ADR-011): an incoherent set cannot be constructed. Pinned by tests **VT-12** (tightest legal pair, 8 and 7, still excludes) and **VT-13** (six accept/reject cases, including 8 and 6, which is rejected).

### 6.3 Upper bound on Max_Age: how long the model may run uncorrected

The model has free response A (A10 = 1.01 per frame). Dead-reckoning error grows as:

```
1.01^8  = 1.083   (8 frames)
1.01^24 = 1.270   (24 frames, the type limit)
```

An initial reference error of e grows by 8 percent over the default window of 8 frames, 27 percent over 24. For a tie-break whose tolerance is T (0.10 rad/s) this is small as long as the initial error is small. Next section.

## 7. How accurate is the reference? (a NEW finding of this analysis)

Part 4's `Observer` documents a steady-state bias. This section turns it into a usable range.

### 7.1 The result

For a constant trusted measurement m, the estimate settles at `g * m` with

```
g = L / (1 - (1 - L) * A)
```

The reference the `Voter` uses is the PREDICTION for the current frame, `A * estimate`, so the prediction is `A * g * m`. Its relative error is `A*g - 1`, and it stays within the comparison threshold T only while

```
|m|  <=  T / (A*g - 1)
```

| Correction gain L | g | Prediction error | Largest rate with error <= T = 0.10 rad/s |
| :-: | :-: | :-: | :-: |
| **0.3 (default)** | 1.0239 | 3.41 % | **2.93 rad/s** |
| 0.5 | 1.0101 | 2.02 % | 4.95 rad/s |
| 0.7 | 1.0043 | 1.43 % | 6.97 rad/s |
| 0.9 | 1.0011 | 1.11 % | 8.99 rad/s |

(g for L = 0.3 is confirmed by the code: test OB-05 checks that the estimate settles near 1.024 times the measurement. The other rows, and the prediction column, are computed from the formula above.)

### 7.2 What it means

- With the placeholder values, the reference is accurate enough to locate an outlier only for pitch rates up to about **2.9 rad/s** (about 168 deg/s). Above that, a duplex disagreement tends to be reported as Unresolved (the safe outcome) instead of Located, and after 4 frames the mode logic goes to Degraded_2.
- **Raising L widens the range**, because the correction pulls the estimate back to the measurement. L = 0.5 gives about 5 rad/s. A larger L also makes the reference follow sensor noise more closely, which is the price.
- The error never falls below `A - 1` (1 percent here): the model always predicts the airframe's growth. This is a **pessimistic static bound**. In flight the controller opposes the growth and the model includes the command term `B * command`, so the real error is smaller when the model is well identified.

### 7.3 Actions

1. Identify A, B from the 6-DOF model and replace the placeholders (ADR-010).
2. Evaluate L in the range 0.4 to 0.6 in MIL against sensor noise.
3. **Add a test** (proposed as OB-13) that pins the prediction error at 3 rad/s for the chosen L, so a change of A or L that shrinks the range is noticed.

## 8. The mode logic (`Modes`)

### 8.1 Persistence limits

| Trigger | Limit | Time | Why this value |
| :--- | :-: | :-: | :--- |
| Unresolved disagreement | 4 frames | 20 ms | The only state where the published value is NOT protected by M1; the earliest reaction |
| Surface saturated | 10 frames | 50 ms | A hard manoeuvre can saturate briefly; 50 ms in a row means lost authority |
| No usable sensor | 12 frames | 60 ms | Half of the breakup time (compile-time checked) |

The ordering Unresolved <= Saturation <= Lost is enforced by a compile-time check: the soft triggers must act no later than the passive reversion.

### 8.2 The time chain for a total loss of sensors

| Step | Time | Note |
| :--- | :-: | :--- |
| Loss begins, damper holds the last command | 0 | the `Voter` reports Lost in the same frame |
| Counter reaches Lost_Limit (12 frames) | 60 ms | test IT-04: Fail_Passive on the 12th lost frame |
| Mode decision | 0 | same frame |
| Hardware output disable (FPGA) | at most 1 ms | assumption |
| Actuator reverts to hold | at most 30 ms | A11 |
| **Total** | **about 91 ms** | |
| Breakup bound | 120 ms | A2 |
| **Margin** | **about 29 ms (24 percent)** | |

### 8.3 The scale factors (0.70, 0.50) and a danger specific to unstable airframes

For a STABLE aircraft, reducing the gain only lowers performance. For an UNSTABLE aircraft it can destroy stability: there is a **minimum gain**, below which the loop no longer overcomes the unstable pole (the lower gain margin). So a reduced-gain mode is only valid if:

```
Gain_Scale  >  1 / GM_lower      (with margin)
```

where GM_lower is the lower gain margin of the loop at the corresponding flight conditions, from the linear analysis. For Direct (0.50) to be safe the lower gain margin must exceed 2, and with a 25 percent margin, 2.5. **This number does not exist yet.** It is the single most important input to confirm before the profile values can be called anything but placeholders (section 9, item 1).

### 8.4 The finding of the integration test (IT-04)

The profile of Fail_Passive has the smallest scales ("no authority"). Applying them to the damper state collapsed the held command from 4161 to 1 in the frame where the mode changed. The cure is a contract, not a comment: `Scaled_Params` now has the precondition `P.Active` (ADR-012). Pinned by tests **IT-04** and **MD-10**.

## 9. Open items (what this analysis does NOT settle)

| # | Item | Needed from | Blocks |
| :-: | :--- | :--- | :--- |
| 1 | Lower gain margin of the pitch loop at each mode's gains | MIL, linear analysis (`models/control_laws/`) | validity of 0.70 and 0.50 |
| 2 | Real sensor noise, scale mismatch, skew, flex | sensor data, structural analysis | threshold T |
| 3 | Real failure rates and a common-cause analysis | FMEA, CCA | section 2.1 |
| 4 | Identification of A and B; choice of L | plant model | observer accuracy range |
| 5 | A counter that closes the 50 percent hole | design change | XC-09b limit |
| 6 | Producers for `Healthy_Lrus` and `Actuator_Degraded` | CCDL consensus, actuator monitor (later parts) | the LRU and actuator rows of the demand table |
| 7 | Independent reference model for the expected values in `test_signal_mgmt.adb` | verification plan | certification credit |
| 8 | Actuator reversion time A11 | actuator specification | the margin in 8.2 |

## 10. Closing OD-02 and OD-03 (the C driver policies from Part 3)

### OD-02: `FSAC_SENSOR_MAX_SEQ_JUMP` = 4 and `FSAC_SENSOR_REARM_FRAMES` = 8

**MAX_SEQ_JUMP = 4.** The driver tolerates up to 3 lost samples between two reads (a sequence delta up to 4) before rejecting a sample as `ERR_SEQ`.

- The FPGA publishes **one snapshot per frame**, latched at the start of the frame (Part 1, section 4, window W1), so the nominal delta is 1.
- **Assumption to confirm in the HSI spec:** the sequence number counts published snapshots, NOT raw sensor conversions. If the FPGA incremented it at the converter rate (say 1 kHz, 5 per frame), the nominal delta would be 5, above the limit, and every sample would be rejected. The limit must be at least the nominal delta plus the tolerated dropout.
- Four is smaller than the persistence P = 8, so a sensor with intermittent dropouts is treated as invalid (no vote) before the cross-check could blame it.

**REARM_FRAMES = 8.** After 8 consecutive invalid frames the step check is dropped so a sensor can rejoin.

- During an outage of N frames the true rate can change by `a_max * N * 5 ms` (A7): 0.025 rad/s per frame, so 0.20 rad/s after 8 frames. The single-frame step limit would reject a perfectly good return for N up to 7. Dropping the step check at 8 lets the sensor rejoin after at most 40 ms.
- **The range check is never dropped**, and a returning sensor is then judged by the cross-check, which has its own persistence.

**Decision:** keep (4, 8) with these constraints written down. Pinned by tests R-32, R-33, P3-01 .. P3-04 of the driver.

### OD-03: a sequence number that goes backwards

Treated as a large forward jump (modular arithmetic) and rejected as `ERR_SEQ`, then the baseline is resynchronized so the next sample rejoins (policy P2).

- A backward number means an FPGA reset or a replayed (stale) snapshot. In both cases the data of that frame is not trustworthy.
- The cost of a reset is one dropped frame.
- Accepting small backward steps would accept replayed data.

**Decision:** keep. Pinned by test R-36.

## 11. Parameter traceability (value, owner, test)

| Parameter | Value | File | Pinned by |
| :--- | :-: | :--- | :--- |
| Comparison threshold T | 6554 raw (0.10 rad/s) | `fsac-signal_mgmt-cross_check.ads` | XC-03 |
| Persistence P | 8 frames | same | XC-04, XC-10 |
| Observer A, B, L | 1.01, 0.10, 0.30 | `fsac-signal_mgmt-observer.ads` | OB-03, OB-04, OB-05 |
| Observer Max_Age | 8 frames | same | OB-06 |
| Coupling `P - 1 <= Max_Age` | predicate | `fsac-signal_mgmt-voter.ads` | VT-12, VT-13 |
| Unresolved / Saturation / Lost limits | 4 / 10 / 12 frames | `fsac-modes.ads` | MD-02, MD-04, MD-05, IT-04 |
| Profile scales | 0.70, 0.50 | same | MD-08, MD-09 |
| `Scaled_Params` precondition | `P.Active` | same | MD-10, IT-04 |
| Driver MAX_SEQ_JUMP / REARM_FRAMES | 4 / 8 | `fsac_hsi_sensor.h` | R-32, R-33, P3-xx |