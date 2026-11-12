# ADR-008: Pointer validation at the public boundary only

| Item | Value |
| :--- | :--- |
| Status | Accepted |
| Date | 2026-11-11 |
| Affects | `fsac_sensor_ingest.c` (config_ok), misra/README.md (DJ-001 closed) |
| Requirement | HLR-HSI-0012 (NULL arguments are reported and never dereferenced) |

## Context
The branch `cfg == NULL` inside the static helper config_ok could not be reached: both callers reject a NULL cfg first. Structural coverage showed 73 of 74 branch outcomes, and DO-178C 6.4.4.3 requires unreachable code to be justified or removed.

## Decision
Pointers are validated once, in the public functions. Internal static helpers state a precondition in a comment and do not repeat the check. The redundant branch in config_ok was removed.

## Reasons
1. Every check that remains is reachable and has a test. 100% branch coverage with no justification register entry.
2. A single place validates input, so there is one place to review (and one set of tests: I-01, I-02, N-01 .. N-05).
3. Static helpers cannot be called from outside the file, so the precondition is enforceable by review of two call sites.

## Consequences
- A new caller of config_ok inside the file must check cfg first. The comment above the function says so, and the MISRA review (Rule 2.1, 9.1) covers it.
- Public functions keep their defensive NULL checks and tests.

## Verification
gcov: 100% lines, 72 of 72 branch outcomes; tests I-01, I-02, N-01 .. N-07 unchanged.