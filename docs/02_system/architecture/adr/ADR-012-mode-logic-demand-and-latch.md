# ADR-012: Mode logic, demand then latch

| Item | Value |
| :--- | :--- |
| Status | Accepted (limits and scales are placeholders) |
| Date | 2026-11-13 |
| Affects | `fsac-modes.ads/.adb` |
| Requirements | HLR-MOD-0001 .. HLR-MOD-0016 |

## Decision
1. A pure Demand function names the mode the conditions call for; the mode becomes max (current, demand), so it never improves in flight. Only Reset (ground) returns to Normal.
2. Triggers are confirmed failures or conditions persisting for a number of frames (4, 10, 12).
3. Scaled_Params has the precondition P.Active.

## Reasons
1. A mode that moved up and down would change the gains many times a second on an unstable airframe.
2. A single bad frame must not degrade the aircraft for the rest of the flight.
3. Integration test IT-04 showed that applying the Fail_Passive profile to the damper collapses the held command to zero.

## Consequences
- Reduced-gain modes are valid only above the lower gain margin of the loop (analysis 8.3): an input that does not exist yet.
- Healthy_Lrus and Actuator_Degraded have no producer yet.

## Verification
Proofs D1 .. D4; tests MD-01 .. MD-12, IT-01 .. IT-04.