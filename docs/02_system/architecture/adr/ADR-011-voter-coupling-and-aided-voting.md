# ADR-011: Voter coupling rule and reference-aided voting

| Item | Value |
| :--- | :--- |
| Status | Accepted |
| Date | 2026-11-13 |
| Affects | `fsac-signal_mgmt-voter.ads/.adb` |
| Requirements | HLR-SIG-0035 .. HLR-SIG-0048 |

## Decision
1. Persistence - 1 <= Max_Age is a Dynamic_Predicate of Voter_Params.
2. With two usable sensors and a located outlier, the voter publishes the other sensor's reading immediately and reports the level as Simplex.
3. A reference-aided frame is never trusted for the observer.

## Reasons
1. Untrusted frames age the observer; if its reference expired before the outlier's counter filled, the outlier would never be excluded.
2. Waiting P frames would run the control law on a midpoint wrong by half the gap.
3. A trusted aided frame would let the model confirm itself.

## Consequences
- An incoherent parameter set cannot be built (test VT-13).
- The published level counts effective independent sources, not sensors that are merely not Failed.
- Duplex with an unresolved disagreement still publishes the midpoint; the mode logic handles it.

## Verification
Proofs V1 .. V5; tests VT-05, VT-09, VT-11, VT-12, VT-13. Analysis sections 5 and 6.