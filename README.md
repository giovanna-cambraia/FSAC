# FSAC SPARK Core: Proof Strategy and Results Log

| Item | Value |
| :--- | :--- |
| File | `software/core_spark/proof/README.md` |
| Purpose | Record what is proved, how, what the proof assumes, and the result of every run |
| Standard context | DO-178C Level A, DO-333 (formal methods supplement) |
| Tool | GNATprove (SPARK 2014) |
| Scope now | Parts 2, 3 (bridge) and 4: core arithmetic, controller, `Platform_Ports`, `Signal_Mgmt` (voting, FDIR, observer, voter), `Modes` |
| Rule of this log | A result is written down only when a run produced it, with WHERE it was produced. Nothing is claimed that was not run. |

## 1. What the proof is meant to establish

For every unit in `software/core_spark/src/` and `software/platform_bridge/`:

1. **Absence of run-time errors.** No overflow, range violation, division by zero, bad index, or uninitialized read. Claimed by no unproved run-time check in the report.
2. **Contract satisfaction.** Every `Post`, `Pre`, `Depends`, `Global` and predicate holds. Claimed by no unproved assertion or postcondition.
3. **Flow correctness.** No uninitialized reads, no unused assignments, no hidden state (`Global => null`). Claimed by a clean flow report.

These support DO-333 objectives. They do not replace testing and do not show closed-loop stability (section 4).

## 2. Proof architecture: the dependency layers

Each layer assumes only the CONTRACTS of the layer below, never its code.

```
Fsac (constants, compile-time checks)
  └─ Fsac.Types                      ranges, Q16 representation
       └─ Fsac.Fixed_Math            overflow proved once, here
            ├─ Fsac.Control.Params           predicates on parameter sets
            │    └─ Fsac.Control.Gain_Schedule     P1 no overshoot, P2, P3
            │         └─ Fsac.Control.Pitch_Rate_Damper    C1..C8
            ├─ Fsac.Platform_Ports           classification of C samples
            ├─ Fsac.Signal_Mgmt              vocabulary (Reading, Health, Level)
            │    ├─ Mid_Value_Select         M1..M5 (fault masking)
            │    ├─ Cross_Check              X1..X7 (FDIR)
            │    ├─ Observer                 O1..O3 (analytical channel)
            │    └─ Voter                    V1..V5 (joins the three above)
            └─ Fsac.Modes                    D1..D4 (demand, then latch)
```

Consequence for review: a change to `Fixed_Math` or `Types` invalidates every proof. A change to the `Voter` body does not touch anything below it.

## 3. How to run the proof

From `software/core_spark/`:

```bash
gnatprove -P fsac_core.gpr                                  # everything
gnatprove -P fsac_core.gpr -u fsac-signal_mgmt-voter.adb    # one unit
gnatprove -P fsac_core.gpr -u fsac-fixed_math.adb --level=3 # more effort
```

The summary is written to the object directory, `.../build/core_spark/obj/<profile>/gnatprove/gnatprove.out`.

### Archiving a run

```bash
RUN=proof/results/$(date +%Y-%m-%d)_$(git rev-parse --short HEAD)
mkdir -p "$RUN"
cp ../../build/core_spark/obj/debug/gnatprove/gnatprove.out "$RUN/"
gnatprove --version > "$RUN/toolchain.txt"
git rev-parse HEAD   >> "$RUN/toolchain.txt"
```

A result without commit hash and tool version does not count as evidence.

## 4. What the proof does NOT show

| Not shown | Evidence that covers it instead |
| :--- | :--- |
| That the control law **stabilizes the airframe** | MIL: gain and phase margins, nonlinear runs (`models/`, `verification/mil/`) |
| That reduced-gain modes stay **above the lower gain margin** (an unstable airframe loses stability if the gain is cut too far) | MIL linear analysis; FDIR analysis 8.3 (open item 1) |
| That the **requirements** are correct and complete | Reviews, FHA/PSSA, validation (ARP4754B) |
| That the **compiler** translated the code correctly | Object-code verification, structural coverage on the target binary |
| That the **hardware** behaves as modelled (bit flips, timing) | DO-254 evidence, fault injection, checks left enabled, lockstep |
| That the **WCET** fits the budget | Static WCET analysis plus on-target measurement |
| That the code agrees with an **independent reading** of the requirement | Requirements-based tests against an independent model (open item) |
| **Properties about data dependence** (for example: the value of an unusable sensor has no influence on the vote) | Test MV-08 (leak test), MV-09 (exhaustive grid) |
| **Parameter coherence across units** (for example Persistence vs the observer's Max_Age) | Type predicate `Voter_Params` (proved to hold at construction), tests VT-12, VT-13 |
| **Errors that appear only when units are used together** | Integration campaign IT-01 .. IT-04. IT-04 found one that every proof and unit test had missed (section 5.5). |
| That the **parameter values** are right (threshold, persistence, limits, scales, A, B, L) | FDIR timing analysis; they are placeholders until section 9 of that document is closed |
| **Common-cause failure** of the redundant sensors | Physical segregation and CCA (Part 1, section 5) |
| The **50 percent hole** of the leaky bucket (a sensor wrong exactly half of the time is not excluded) | Documented limit, pinned by test XC-09b |

## 5. Results log

### 5.1 Run history

"Where" says who produced the run. Rows marked **to confirm** were produced in an independent environment and must be repeated on the author's machine and archived before they count as the author's evidence.

| Step | Date | Commit | Tool | Level | Checks | Unproved | Where | Status |
| :--- | :--- | :--- | :--- | :-: | :-: | :-: | :--- | :--- |
| Part 2: core | 2026-11-11 | `<hash>` | GNATprove (author's version) | 2 | 106 | 0 | author's machine | confirmed |
| Part 3: + `Platform_Ports` | `<date>` | `<hash>` | same | 2 | 112 | 0 | author's machine | confirmed (output pasted) |
| Part 4: + `Signal_Mgmt` vocabulary | `<date>` | `<hash>` | same | 2 | 116 | 0 | author's machine | confirmed (output pasted) |
| Part 4: + `Mid_Value_Select` | 2026-11-13 | none | FSF GNATprove 16.1.0 | 2 | 135 | 0 | independent sandbox | **to confirm** |
| Part 4: + `Cross_Check` | 2026-11-13 | none | same | 2 | 164 | 0 | independent sandbox | **to confirm** |
| Part 4: + `Observer` | 2026-11-13 | none | same | 2 | 176 | 0 | independent sandbox | **to confirm** |
| Part 4: + `Voter` | 2026-11-13 | none | same | 2 | 189 | 0 | independent sandbox | **to confirm** |
| Part 4: + `Modes` (and `Scaled_Params` precondition) | 2026-11-13 | none | same | 2 | **216** | 0 | independent sandbox | **to confirm** |

Fill `<date>` and `<hash>` from your own archive folders. The sandbox ran GNAT 16.1.0; the same core also proved with 106 checks there, identical to the author's own run, which is the evidence that the two environments agree.

Test runs, same period (see `tests/` of each part):

| Program | Checks | Where | Status |
| :--- | :-: | :--- | :--- |
| `test_core` | 127 | author's machine | confirmed |
| `test_sensor_ingest` (driver) | 148 (154 after ADR-007/008 edits) | author's machine (148); sandbox (154) | 148 confirmed |
| `test_bridge` (mixed Ada/C) | 39 | author's machine | confirmed |
| `test_signal_mgmt` (Part 4) | 201 | independent sandbox | **to confirm** |

### 5.2 Status per unit

"Expected" is the difficulty I predicted before the first run; "Actual" is what happened.

| Unit | Main obligations | Expected | Actual |
| :--- | :--- | :-: | :--- |
| `Fixed_Math` | no overflow, all `Post` | low | proved. The one expected hard item, `Mul_Q` (64-bit product), proved at level 2 with the two guiding assertions |
| `Control.Params` | predicates well-formed | low | proved |
| `Gain_Schedule` | loop invariant, P1, P3 | medium | proved with the seven ordering assertions and the assertion at the selected segment |
| `Pitch_Rate_Damper` | C1 .. C8 | medium | proved with the HINT assertions in `Step` |
| `Platform_Ports` | `Classify`, conversion | low | proved without hints |
| `Signal_Mgmt` (parent) | expression functions | none | proved |
| `Mid_Value_Select` | M1 (pairs of usable sensors), M2 .. M5 | medium | proved **with no hint at all**, including the doubly quantified M1 |
| `Cross_Check` | X1 .. X7, nested helper | high | proved after two corrections (section 5.3) |
| `Observer` | O1, O2 | medium | proved at the first run |
| `Voter` | V1 .. V5, `Other_Usable` | high | proved at the first run, after one visibility fix (`use type`) |
| `Modes` | D1 .. D4, `Scaled_Params` predicate | medium | proved at the first run, after two visibility fixes |

### 5.3 Register of obligations that did not prove at first, and how each was closed

Entries are things the prover or compiler flagged during development. "Closed" means fixed in the code or the contract, never suppressed.

| ID | Unit | What was flagged | Cause | How closed |
| :--- | :--- | :--- | :--- | :--- |
| PR-001 | `Cross_Check.Decide_Pair` | Postcondition not proved; counterexample `Id_A = 1, Id_B = 1` | The helper had no precondition saying the two sensor indices differ, so "the outlier is A or B" did not imply "A and B are different sensors" | Added `Pre => Id_A /= Id_B` (all three callers already satisfied it) |
| PR-002 | `Cross_Check.Decide_Pair` | `Dec` declared `In_Out` in `Global`; "unused initial value" warning, an error under `--warnings=error` | The procedure assigns `Dec` on every path, so it is an output | `Global` changed to `Output => Dec`; removed the useless initial value |
| PR-003 | `Mid_Value_Select` | "use clause is redundant" warning (an error under `-gnatwe`) | A child unit already sees its parent's context | Removed the duplicate context clause |
| PR-004 | `Voter` | `=` on `Cross_Check.Decision` not directly visible | Operator visibility across packages | Added `use type Cross_Check.Decision` in the specification |
| PR-005 | `Modes` | Operators and names not visible (`Fsac.Types`, `Sensor_Health`) | Same | Added `with Fsac.Types` and the `use type` clauses |

### 5.4 Register of justified assumptions (`pragma Assume`, `Annotate`)

The rule is **none**, and there are none. A `pragma Assume` in DAL-A code is an unproved claim and needs an independent review and a written argument here.

| ID | Location | Statement assumed | Why it holds | Evidence | Reviewer |
| :--- | :--- | :--- | :--- | :--- | :--- |
| (none) | | | | | |

### 5.5 Findings that the proof could not make, found by testing

These are the reason section 4 lists integration testing as separate evidence.

| ID | Found by | What | Why proof and unit tests missed it | Closed by |
| :--- | :--- | :--- | :--- | :--- |
| TF-001 | Integration test IT-04 | When the mode became `Fail_Passive`, the held surface command dropped from 4161 to 1 | Every unit was correct on its own. The mistake was in how the pieces were combined: the profile of `Fail_Passive` ("no authority") was applied to the damper state, collapsing the command that was supposed to be held | `Scaled_Params` now has `Pre => P.Active` (ADR-012). Tests IT-04, MD-10 |
| TF-002 | Own test expectation, observer | A test expected the estimate to converge to the measurement; it settled 2.4 percent above | The code was right. A model with free response above 1 has a steady-state bias | Documented in `Observer` (specification) and FDIR analysis section 7; test OB-05 pins it |
| TF-003 | Own test expectation, voter | A test expected the old value in the frame where a sensor is excluded | The code was right: the exclusion takes effect in the same frame | Test VT-03 states the correct behaviour |

## 6. Trust base: what the proof rests on

1. **The SMT provers are sound** (CVC5, Z3, Alt-Ergo through Why3). Mitigation: more than one prover; the unproved list is reviewed.
2. **The contracts say what the requirements say.** A correct proof of the wrong contract is still wrong. Mitigation: review of every `Pre` and `Post` against the requirement text; requirements-based tests.
3. **The `Fsac.Types` ranges describe real signals.** For example `Body_Rate` is +-8 rad/s. A value outside that is rejected BEFORE it enters the core: by the C driver and again by `Platform_Ports` (test B-04d shows the second line of defence catching a value the driver accepted).
4. **Parameters are valid.** Predicates in `Control.Params` and `Voter_Params` are the only gate. The loader consistency check (HLR-CTL-0012) must enforce them on the real parameter file.
5. **Arithmetic is two's complement 32 and 64 bit,** with no trap or flag state the proof ignores. No floating point exists in the core (`No_Floating_Point`).
6. **No concurrency inside the core.** Interleaving belongs to the partitioned kernel, whose evidence is separate.
7. **The three sensors fail independently.** Fault masking (M1) and the latent-window estimate assume it. Common cause is not covered by any proof (section 4).
8. **The sequence number of the FPGA counts published snapshots,** one per frame. If it counted raw conversions the driver's sequence check would reject every sample. To be confirmed in the HSI specification.
9. **The observer's parameters (A, B, L) describe the airframe well enough** for the reference to be within the threshold of a healthy sensor. Placeholders today; the accuracy range is stated in FDIR analysis section 7.
10. **The producers of `Healthy_Lrus` and `Actuator_Degraded` exist and are correct.** They do not exist yet; until then these inputs are constants.

## 7. Properties catalog

What each proof guarantees, and which test covers what the proof cannot express.

| ID | Unit | Statement | Proved | Also tested by |
| :--- | :--- | :--- | :-: | :--- |
| C1 .. C8 | `Pitch_Rate_Damper` | position limit, rate limit, integrator bound, hold on invalid input, hold counter, status truth, closed state, no hidden state | yes | D-01 .. D-05 |
| P1 .. P3 | `Gain_Schedule` | no overshoot, continuity, clamped ends | yes | G-01 .. G-05 |
| (Classify) | `Platform_Ports` | the decision table; a rejected sample carries value 0 | yes | B-03, B-04 |
| M1 | `Mid_Value_Select` | for every pair of usable sensors the result lies between them (a single fault cannot drag the output) | yes | MV-09 (exhaustive grid) |
| M2 | same | with three usable the result is one of the readings | yes | MV-09 |
| M3, M4, M5 | same | one usable gives its reading; none gives 0 and Lost; count and level agree | yes | MV-05 |
| M6 | same | an unusable sensor has no influence | **no** (data dependence) | MV-08 (leak test) |
| X1 | `Cross_Check` | the state stays consistent (Healthy means count 0, Suspect means 0 < count < Persistence) | yes | XC-13a (3000 random frames) |
| X2 | same | Failed is latched | yes | XC-11, XC-13b |
| X3 | same | a sensor fails only as the located outlier at the persistence limit | yes | XC-04 |
| X4 | same | a located outlier differs by more than the threshold from every other usable sensor | yes | XC-03, XC-05 |
| X5, X6, X7 | same | no evidence means no change; Insufficient exactly when fewer than two usable; Newly_Failed is truthful | yes | XC-06, XC-08, XC-04 |
| O1, O2, O3 | `Observer` | a trusted correction stays between prediction and measurement; untrusted means dead reckoning and age grows; the estimate stays in range | yes | OB-12a/b, OB-06 |
| V1 .. V5 | `Voter` | validity, equals the vote unless aided, aided means one source and a located outlier, the trust rule, consistency and latch | yes | VT-01 .. VT-11 |
| (coupling) | `Voter_Params` | `Persistence - 1 <= Max_Age` | predicate | VT-12, VT-13 |
| D1 .. D4 | `Modes` | the mode never improves; it is max (old, demand); counters count consecutive frames and saturate; long loss ends in Fail_Passive | yes | MD-03 .. MD-05, MD-12 |
| (profiles) | `Modes` | a worse mode never has more gain or authority | no | MD-08 |
| (end to end) | all | a sensor hard-over changes the command by at most 50 raw; the same fault with a plain average moves it by over 10000 | no | IT-02, IT-03 |

## 8. Proof review checklist (before baselining a release)

- [ ] `gnatprove` reports zero unproved checks in `src/` and `platform_bridge/`.
- [ ] No `pragma Assume`, `Annotate (GNATprove, False_Positive)` or `SPARK_Mode => Off` outside `platform_bridge` bodies that are justified in 5.4.
- [ ] No proof is weakened between runs (timeouts, `--level`, prover list unchanged, or the change is recorded).
- [ ] Every `HINT` assertion in the bodies is still needed or was removed on purpose.
- [ ] The run is archived with commit hash and tool version, **on the author's machine**.
- [ ] Every specification changed since the last baseline was re-reviewed against its requirement.
- [ ] Section 4 was reread: no claim in the safety case relies on the proof for something it does not show.
- [ ] The parameter placeholders listed in the FDIR analysis (section 9) are either replaced or still declared as placeholders in the release notes.
- [ ] The integration campaign (IT-01 .. IT-04) passes.

## 9. Regression policy

- A change to `fsac-types.ads` or `fsac-fixed_math.ads` invalidates every proof. Re-run the whole core.
- A change to a body invalidates that unit and the units above it in the section 2 diagram. Examples: a change to `Cross_Check` bodies requires re-proving `Voter` only if a contract it relies on changed.
- A change to ANY parameter default or limit (threshold, persistence, A, B, L, mode limits, scales) requires: the unit tests, `test_signal_mgmt`, the integration campaign, and an update of the FDIR analysis. The coupling predicate and the compile-time checks will refuse some changes outright; that is intended.
- CI (`ci/gates.yaml`) fails the merge if the unproved count is above zero, if the number of `Assume` or `Annotate` entries grew, or if any test program reports a failure.