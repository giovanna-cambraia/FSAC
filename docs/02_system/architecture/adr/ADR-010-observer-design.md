# ADR-010: Observer design (analytical redundancy)

| Item | Value |
| :--- | :--- |
| Status | Accepted (A, B, L are placeholders) |
| Date | 2026-11-13 |
| Affects | `fsac-signal_mgmt-observer.ads/.adb` |
| Requirements | HLR-SIG-0025 .. HLR-SIG-0034 |

## Decision
A first-order observer, estimate' = A*estimate + B*command + L*(measurement - prediction), corrected only by trusted measurements, valid only while its age is at most Max_Age, clamped to the Body_Rate range, with the correction clamped between prediction and measurement.

## Reasons
1. With A above 1 the model's own error grows, so an age limit is mandatory.
2. Correcting from an untrusted measurement (for example a duplex midpoint) would pull the reference toward the bad sensor.
3. The clamps make the contract properties true by construction.

## Consequences
- Steady-state bias: the prediction is A*g*m with g = L/(1-(1-L)A), 3.4 percent too high with the placeholders. The reference locates an outlier only up to about 2.9 rad/s; raising L to 0.5 gives about 5 rad/s.
- A, B, L must come from plant identification before any claim of accuracy.

## Verification
Tests OB-01 .. OB-12 and VT-02b. Proposed test OB-13 pins the prediction error. Analysis section 7.