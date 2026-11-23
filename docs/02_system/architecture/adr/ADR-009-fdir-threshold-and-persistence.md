# ADR-009: FDIR comparison threshold and persistence

| Item | Value |
| :--- | :--- |
| Status | Accepted (values are placeholders pending section 9 of the analysis) |
| Date | 2026-11-13 |
| Affects | `fsac-signal_mgmt-cross_check.ads` (Default_Threshold, Default_Persistence) |
| Requirements | HLR-SIG-0013 .. HLR-SIG-0024 |

## Context
Cross_Check needs a comparison threshold T and a persistence P. With three usable sensors the median already masks a first fault, so detection speed does not decide survival of the first fault.

## Decision
T = 0.10 rad/s (6554 raw) and P = 8 frames (40 ms), with a leaky-bucket counter.

## Reasons
1. T exceeds the worst-case difference between two healthy sensors (0.075 rad/s) by 25 percent.
2. P is twice the longest plausible transient (4 frames).
3. The latent window of 40 ms contributes about 7e-13 per flight hour of lost masking for an illustrative sensor failure rate of 1e-4 per hour.

## Consequences
- An undetected error up to T reaches the control law as Kq * T (20 to 30 percent of travel); this is acceptable in Triplex and Duplex, and is why two failed sensors demand Direct mode.
- A sensor wrong exactly half of the time is not excluded (test XC-09b).

## Verification
Tests XC-03, XC-04, XC-09, XC-10. Full derivation: FDIR_timing_analysis.md, sections 2 to 4.