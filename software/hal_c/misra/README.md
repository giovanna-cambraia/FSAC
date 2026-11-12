# MISRA C:2012 Compliance Record: `hal_c`

| Item | Value |
| :--- | :--- |
| File | `software/hal_c/misra/README.md` |
| Scope | `software/hal_c/include/*.h`, `software/hal_c/src/**/*.c` (flight code) |
| Out of scope | `software/hal_c/tests/` (host test code, see section 2), BSP startup and register access (own record, later) |
| Standard | MISRA C:2012 with Amendments 2, 3 and Technical Corrigendum 2, on C11 |
| Assurance context | DO-178C Level A coding standard (SDP section "Code standards") |
| Status | **Self-review done. Compiler warnings clean. No MISRA checker has been run yet.** Section 4 lists exactly what was and was not verified. |

## 1. Why this document exists

DO-178C asks for a coding standard, evidence that the code follows it, and a controlled list of every place it does not. This file is those three things for the C side of FSAC. It is also the place where the project states which rule it considers a firm gate and which is a judgement call.

## 2. Scope and what is not covered

- **In scope:** `fsac_hsi_sensor.h` and `fsac_sensor_ingest.c`, and every later flight C file (CCDL, gateway parsers, loader).
- **Test code is not under MISRA.** `test_sensor_ingest.c` uses `printf` (Rule 21.6) and similar on purpose. It is held to a compiler-warning gate only.
- **The BSP is separate.** It contains the one place that converts an address to a pointer. That deviation is planned here (DEV-001) and will be confirmed when the BSP is written.

## 3. Compliance policy

| MISRA category | Project policy |
| :--- | :--- |
| **Mandatory** | No deviation allowed. Any finding blocks the merge. |
| **Required** | Compliant, or a **formal deviation** (section 6): written reason, risk analysis, independent reviewer signature. |
| **Advisory** | Compliant, or a **recorded justification** (a line in section 6 is enough). |
| **Directive** | Same category rules as above; the project defines the part the directive leaves open. |

A deviation covers one rule in one place. A blanket suppression of a rule for the whole project is not allowed.

## 4. Verification status (what has really been done)

| Check | Status | Evidence |
| :--- | :--- | :--- |
| Compiles with `-std=c11 -Wall -Wextra -Wpedantic -Wconversion -Wshadow` | **Done, zero warnings** (run on the author's MinGW and on Linux gcc 13) | build output of `tests/` |
| Additionally `-Wsign-conversion -Wstrict-prototypes -Wcast-qual` on the driver | **Done, zero warnings** (Linux gcc 13) | sandbox run |
| Behaviour tests: 148 checks pass, also with AddressSanitizer + UBSan and at `-O2` | **Done** (sanitizers on Linux only) | `tests/test_sensor_ingest.c` |
| Structural coverage of the driver: 100% lines, 73 of 74 branch outcomes | **Done** (gcov); the missing branch is DJ-001 | gcov report |
| Manual review against the rules in section 5 | **Done by the author** | section 5 |
| Automated MISRA check (cppcheck addon or commercial tool) | **Not run yet** | do it before the first baseline, see section 7 |
| Independent review by a second person | **Not done** | required before baseline |

Until the two "not done" rows are done, the honest statement is: *written to the rules and reviewed by the author; not machine-checked.*

## 5. Rule-by-rule status for the current files

"Complies (review)" means the author checked the code by reading it. "Confirm with tool" means a checker should be run because the rule is easy to get wrong by eye.

### 5.1 Mandatory rules that matter here

| Rule | Text (short) | Status | How |
| :--- | :--- | :--- | :--- |
| 9.1 | No read of an uninitialized automatic object | Complies (review), confirm with tool | Every local is initialized at its declaration or assigned on every path before use (`snap`, `delta`, `scaled`, `diff`) |
| 1.3 | No undefined behaviour | Complies (review) | Mailbox copied field by field, no `memcpy` on a `volatile` object; shifts only by constants below the type width; no signed overflow (signed arithmetic is done in `int64_t` with proven bounds, checked by `_Static_assert` in the driver) |

### 5.2 Required rules that matter here

| Rule | Text (short) | Status | How |
| :--- | :--- | :--- | :--- |
| 17.2 | No recursion | Complies (review) | No function calls itself, directly or indirectly (call graph is a tree: `read` → `evaluate` → `scale`, `crc16`, `config_ok`, `step_exceeded`) |
| 17.7 | Return values must be used | Complies (review), confirm with tool | Every call in the driver uses its result; callers in P1 must do the same (header USAGE note). Test code uses `(void)` where it ignores a result. |
| 21.3 | No `malloc`/`free` family | Complies | Not included, not used. Spec section 3. |
| 15.6 | Bodies of `if`/`else`/loops are compound statements | Complies (review) | Braces everywhere |
| 15.7 | `if ... else if` chains end with `else` | Complies (review) | `evaluate`, `fsac_sensor_scale`, `fsac_sensor_init` all end with an `else` (in `init` it holds a comment only, on purpose) |
| 10.3 | No assignment to a narrower or different essential type | Complies (review), confirm with tool | Explicit casts at every narrowing (`(uint8_t)`, `(uint16_t)`, `(fsac_q16_t)`), in range by construction |
| 10.4 | Both operands of an arithmetic or comparison operator have the same essential type | Complies (review), confirm with tool | Unsigned constants use `U`; signed comparisons use signed constants; mixed cases are cast explicitly |
| 10.8 | No cast of a composite expression to a wider type | Complies (review) | Widening is done on the operands first: `(int64_t)a - (int64_t)b`, never `(int64_t)(a - b)` |
| 11.8 | No removal of `const` or `volatile` | Complies (review) | The mailbox pointer keeps `const volatile` through the call; the snapshot copy is a plain local |
| 12.2 | Shift amount in range | Complies (review) | Only constant shifts of 8, 16, 24 on 32-bit unsigned values, and `<< 1`, `<< 8` on values already masked |
| 13.5 | No side effects in the right operand of `&&` / `||` | Complies (review) | Right operands are pure comparisons (`config_ok`) |
| 14.3 | No invariant controlling expressions | Complies (review) | None |
| 14.4 | Controlling expression is essentially Boolean | Complies (review) | `bool` values, or an explicit `!= 0U` |
| 8.4 | A compatible declaration is visible for every external function | Complies | All four public functions are declared in `fsac_hsi_sensor.h` and the `.c` includes it |
| 20.7 | Macro parameters are parenthesized | **Possible finding**, see DEV-002 | `FSAC_STATIC_ASSERT(cond, msg)`: `cond` is parenthesized, `msg` cannot be |
| 7.2 | `u`/`U` on unsigned constants | Complies (review) | `0U`, `8U`, `0xFFFFU`, ... |

### 5.3 Advisory rules and directives that matter here

| Rule | Text (short) | Status | How |
| :--- | :--- | :--- | :--- |
| Dir 4.6 | Fixed-width typedefs instead of basic types | Complies | `stdint.h` types only |
| Dir 4.9 | Prefer a function to a function-like macro | Justified, see DEV-002 | The only macro with parameters is `FSAC_STATIC_ASSERT` |
| 15.5 | Single point of exit | Complies (review) | One `return` per function |
| 8.7 | Functions used in one file are `static` | Complies | All helpers are `static` |
| 8.13 | Pointers to `const` where possible | Complies | Configuration and snapshot pointers are `const` |
| 12.1 | Explicit operator precedence | Complies (review) | Parentheses in every mixed expression |
| 17.8 | Parameters are not modified | Complies (review) | Helpers copy to a local first (`sat_inc`) |
| 11.4 | No conversion between pointer and integer | **Planned deviation** | DEV-001, in the BSP only |

### 5.4 Implementation assumptions the code relies on

These are not rule violations, but a reviewer must know them. Each has a guard.

| Assumption | Guard |
| :--- | :--- |
| `int` is at least 32 bits, two's complement | `_Static_assert` on the 64-bit scaling bound in the driver; `INT32_C` constants |
| `fsac_sensor_raw_t` has no padding (20 bytes) and `fsac_sensor_sample_t` is 12 bytes | `FSAC_STATIC_ASSERT(sizeof ...)` in the header, and `offsetof` checks in tests L-01 .. L-13 |
| Integer division truncates toward zero | Defined by C99 and later, relied on by `fsac_sensor_scale` to match Ada `Mul_Q` (tested in S-05 .. S-08) |
| Little-endian byte order of the mailbox | The CRC is computed byte by byte in a fixed order, so it does not depend on the host; the FPGA layout is little-endian by spec (HSI_spec) |
| The mailbox is not cached or reordered by the processor | BSP requirement HLR-HSI-0011 (device or non-cacheable mapping). **Not checkable in this file.** |

## 6. Registers

### 6.1 Deviation register (formal)

| ID | Rule | Category | Location | Status | Reason and risk |
| :--- | :--- | :--- | :--- | :--- | :--- |
| DEV-001 | 11.4 (pointer from integer) | Advisory | `software/os/bsp/` mailbox address table (future file) | **Planned** | The mailbox lives at a fixed hardware address. The only place that casts the address is the BSP. The driver receives a ready pointer and has no cast. Risk: a wrong address. Mitigated by a link-time check against the memory map in `software/config/memory_map/` and a power-on test that reads a known ID register. |
| DEV-002 | 20.7 (macro parameters in parentheses), and Dir 4.9 | Required / Advisory | `FSAC_STATIC_ASSERT` in `fsac_hsi_sensor.h` | **Only if the checker reports it** | `_Static_assert` needs a string literal as its second argument, and a literal cannot be parenthesized. Cleaner alternative: remove the macro and write `_Static_assert` directly (C11, allowed by Amendment 3). Decision: keep the macro until a checker reports it, then replace the macro instead of keeping a deviation. |

### 6.2 Coverage justification register (DO-178C 6.4.4.3, not a MISRA deviation)

| ID | Location | Description | Why it is not covered | Decision |
| :--- | :--- | :--- | :--- | :--- |
| DJ-001 | `config_ok`, the `cfg == NULL` branch of the first `if` | The branch that returns `false` for a NULL configuration | Unreachable: both callers (`fsac_sensor_init`, `fsac_sensor_read`) reject a NULL `cfg` before calling it. The check protects a future caller. | **Open. Default: keep and justify.** If a MISRA checker reports it as unreachable (Rule 2.1), remove the check instead, document the precondition in a comment and the coverage becomes 100% of branches. |

### 6.3 Open design decisions found while testing

| ID | Question | Current behaviour | Test that pins it |
| :--- | :--- | :--- | :--- |
| OD-01 | Should a hardware flag bit that the driver does not know (bit 4 .. 15) count as a fault? | No: only `0x000F` is a fault, unknown bits are ignored | R-21, R-22 |
| OD-02 | `FSAC_SENSOR_MAX_SEQ_JUMP` (4) and `FSAC_SENSOR_REARM_FRAMES` (8) | Starting values chosen by the author | R-32, R-33, P3-01 .. P3-04 |
| OD-03 | A sequence number that goes backwards | Treated as a large forward jump, so `ERR_SEQ` | R-36 |

Each decision needs a signature in the FDIR analysis (Part 4). If OD-01 changes to "any non-zero flag is a fault", tests R-21 and R-22 flip their expected result, which is the point of having them.

## 7. How to run an automated check

Use at least one tool in each level.

**Level 1, compiler (already clean):**

```bash
gcc -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow \
    -Wstrict-prototypes -Wcast-qual -Iinclude -fsyntax-only src/sensor_ingest/fsac_sensor_ingest.c
```

**Level 2, open-source MISRA addon (cppcheck).** The addon needs the rule texts from the MISRA document, which are copyrighted and must be supplied by whoever owns a licence. Do not commit that file. Option names can differ between cppcheck versions, so check `cppcheck --help` first.

```bash
# one-time: a file misra.json next to the addon, pointing to your licensed rule text
#   { "script": "misra.py", "args": ["--rule-texts=misra_rules.txt"] }
cppcheck --addon=misra.json --enable=all --std=c11 --inline-suppr \
         -Iinclude src/sensor_ingest/fsac_sensor_ingest.c
```

**Level 3, a qualified or commercial checker** (Polyspace, Helix QAC, Coverity, PC-lint Plus) for any claim of compliance in a real certification project. For this learning project, Level 1 plus Level 2 plus the independent review is a good, honest target.

Any finding goes into section 6 (deviation or justification) or is fixed. A suppression comment in the code (`// cppcheck-suppress ...`) must carry the register ID.

## 8. Gate before the first baseline

- [ ] Level 1 build clean (done).
- [ ] Level 2 run on every file in scope, findings resolved or registered.
- [ ] Section 5 reviewed by a person who did not write the code.
- [ ] DJ-001 and OD-01 .. OD-03 decided and signed.
- [ ] DEV-001 reviewed when the BSP exists.
- [ ] This file committed in the same commit as the code it describes.

## 9. Traceability

| Requirement | Satisfied by |
| :--- | :--- |
| HLR-HSI-0001 layout shared with Ada | `FSAC_STATIC_ASSERT(sizeof ...)`, tests L-01 .. L-14 |
| HLR-HSI-0003 scaling identical to `Mul_Q` | `fsac_sensor_scale`, tests S-01 .. S-11 |
| HLR-HSI-0004 CRC | `fsac_sensor_crc16`, tests CRC-1 .. CRC-5 |
| HLR-HSI-0005 .. 0010 checks and policies | `evaluate`, `update_state`, tests R, O, P groups |
| HLR-HSI-0011 mailbox mapping | BSP, DEV-001 (future) |
| HLR-HSI-0012 NULL arguments and output rule | `fsac_sensor_read`, tests N-01 .. N-07 |