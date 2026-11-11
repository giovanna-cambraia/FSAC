# FSAC SPARK Core: Proof Strategy and Results Log

| Item | Value |
| :--- | :--- |
| File | `software/core_spark/proof/README.md` |
| Purpose | Record what is proved, how it is proved, what the proof assumes, and the result of every proof run |
| Standard context | DO-178C Level A, DO-333 (formal methods supplement) |
| Tool | GNATprove (SPARK 2014) |
| Status of results | **No proof run recorded yet.** The tables in section 5 are empty on purpose. Nothing here claims a result that has not been produced and archived. |

## 1. What the proof is meant to establish

For every unit in `software/core_spark/src/`, three things:

1. **Absence of run-time errors (AoRTE).** No overflow, no range violation, no division by zero, no index out of bounds, no use of an uninitialized variable. Claimed by the absence of unproved *run-time checks* in the report.
2. **Contract satisfaction.** Every `Post`, `Pre`, `Depends`, `Global` and predicate declared in the specifications holds for the implementation. Claimed by the absence of unproved *assertions and postconditions*.
3. **Flow correctness.** No uninitialized reads, no unused assignments, no hidden state (`Global => null`). Claimed by a clean *flow analysis* report.

Together these support DO-333 objectives on the formal verification of the stabilization kernel. They do not replace testing (see `tests/test_core.adb`) and they do not show closed-loop stability (see section 4).

## 2. Proof architecture: how the units depend on each other

The proofs are built in layers so that each layer assumes only the contracts of the layer below it, never its code.

```
Fsac (constants, compile-time checks)
  └─ Fsac.Types            ranges, Q16 representation (no proofs, declarations only)
       └─ Fsac.Fixed_Math  overflow proved once here; every caller inherits it
            ├─ Fsac.Control.Params            predicates (validity of parameter sets)
            │    └─ Fsac.Control.Gain_Schedule   P1 no overshoot, P2 continuity, P3 clamped ends
            │         └─ Fsac.Control.Pitch_Rate_Damper   C1..C8 (position, rate, integrator, hold)
            └─ (later) Fsac.Signal_Mgmt, Fsac.Allocation, Fsac.Modes
```

Consequence for review: if `Fixed_Math` is changed, everything above it must be re-proved. If only the damper body changes, nothing below it is affected.

## 3. How to run the proof

From `software/core_spark/`:

```bash
# Everything (flow analysis + proof), settings come from fsac_core.gpr
gnatprove -P fsac_core.gpr

# One unit while you work on it
gnatprove -P fsac_core.gpr -u fsac-control-pitch_rate_damper.adb

# More effort for a stubborn check
gnatprove -P fsac_core.gpr -u fsac-fixed_math.adb --level=3

# Show the failing check with a counterexample, one line, one unit
gnatprove -P fsac_core.gpr -u fsac-fixed_math.adb --limit-line=fsac-fixed_math.adb:75 --report=all
```

Output lands in the object directory of the project, in a `gnatprove/` subfolder (`../../build/core_spark/obj/<profile>/gnatprove/`). The file `gnatprove.out` is the summary to archive.

### Archiving a run

```bash
RUN=proof/results/$(date +%Y-%m-%d)_$(git rev-parse --short HEAD)
mkdir -p "$RUN"
cp ../../build/core_spark/obj/debug/gnatprove/gnatprove.out "$RUN/"
gnatprove --version > "$RUN/toolchain.txt"
git rev-parse HEAD   >> "$RUN/toolchain.txt"
```

A result that was not archived with the commit hash and the tool version does not count as evidence.

## 4. What the proof does NOT show (keep this section in the safety case)

| Not shown | Where the evidence comes from instead |
| :--- | :--- |
| That the control law **stabilizes the airframe** | Analysis and simulation of the plant: gain and phase margins, nonlinear MIL runs (`models/`, `verification/mil/`) |
| That the **requirements are correct and complete** | Requirements reviews, FHA/PSSA, validation (ARP4754B) |
| That the **compiler** translated the code correctly | Object-code verification, structural coverage on the target binary, compiler qualification or diversity (DO-178C 6.4.4.2) |
| That the **hardware** behaves as modelled (bit flips, timing) | DO-254 evidence, fault injection (`verification/fault_injection/`), run-time checks left enabled, lockstep cores |
| That the **WCET** fits the budget | Static WCET analysis and on-target measurement (`verification/wcet/`) |
| That the code agrees with an **independent reading** of the requirement | Requirements-based tests against the Python reference model |

## 5. Results log

### 5.1 Run history

One row per archived run. Leave empty until a run exists.

| Date | Commit | GNATprove version | Level | Total checks | Proved | Unproved | Archive folder |
| :--- | :--- | :--- | :-: | :-: | :-: | :-: | :--- |
| | | | | | | | |

### 5.2 Status per unit (fill from the latest run)

Expected difficulty is my estimate before any run; the last column is for the real result.

| Unit | Main obligations | Expected difficulty | Result |
| :--- | :--- | :--- | :--- |
| `fsac.ads` | compile-time consistency of timing constants | none | |
| `fsac-types.ads` | compile-time overflow margins | none | |
| `fsac-fixed_math` | no overflow in `Add_Sat`, `Sub_Sat`, `Neg`, `Abs_Q`; all `Post` | low | |
| `fsac-fixed_math` / `Mul_Q` | overflow of the 64-bit product (nonlinear) | **medium**: may need `--level=3` or the 16-bit split | |
| `fsac-control-params` | predicates well-formed | low | |
| `fsac-control-gain_schedule` / `Find_Segment` | loop invariant, both halves of `Post` | low to medium | |
| `fsac-control-gain_schedule` / `Schedule_Gain` | `Pre` of `Blend_Factor`, P1, P3 (quantifier instantiation) | **medium** | |
| `fsac-control-pitch_rate_damper` / `Step` | C1..C7 | **medium**: rate-limit argument, relies on the HINT assertions | |
| `fsac-control-pitch_rate_damper` / `Rebase`, `Make_Params` | `Post`, predicate on the result | low | |

### 5.3 Register of unproved checks and how each was closed

Every check that did not prove automatically gets one entry. "Closed" means proved after a code or hint change, or justified (section 5.4).

| ID | Unit and line | Check | First seen | Cause | How closed | Reviewed by |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| | | | | | | |

### 5.4 Register of justified assumptions (`pragma Assume`, `Annotate`)

The rule is **none**. A `pragma Assume` in DAL-A code is an unproved claim and needs an independent review and a written argument here. Add a row only after that.

| ID | Location | Statement assumed | Why it holds | Evidence that supports it | Reviewer |
| :--- | :--- | :--- | :--- | :--- | :--- |
| | | | | | |

## 6. Trust base: what the proof rests on

A proof is only as strong as what it assumes. For this project the assumptions are:

1. **The SMT provers are sound** (CVC5, Z3, Alt-Ergo, through Why3). Mitigation: proofs are replayed with more than one prover where possible; the unproved list is reviewed.
2. **The contracts say what the requirements say.** A correct proof of the wrong contract is still wrong. Mitigation: review of every `Pre` and `Post` against the requirement text; requirements-based tests.
3. **The `Fsac.Types` ranges describe real signals.** For example `Body_Rate` is +-8 rad/s. If a sensor can deliver more, the value must be rejected *before* it enters the core (the `Sensor_Ingest` driver, written in Part 3), not after. This is an input boundary assumption.
4. **Parameters are valid.** Predicates in `Fsac.Control.Params` are the only gate. The loader consistency check (HLR-CTL-0012) must enforce them on the real parameter file.
5. **Arithmetic is two's complement 32 and 64 bit** on the target, with no trap or flag state that the proof ignores. No floating point exists in the core (`No_Floating_Point` in `fsac.adc`).
6. **No concurrency inside the core.** Interleaving is provided by the partitioned kernel, whose own evidence is separate.

## 7. Proof review checklist (run before baselining a release)

- [ ] `gnatprove` reports zero unproved checks in `src/`.
- [ ] No `pragma Assume`, `Annotate (GNATprove, False_Positive)` or `SPARK_Mode => Off` in `src/`, other than a justified row in 5.4.
- [ ] No proof is weakened between runs (timeouts, `--level`, prover list unchanged, or the change is recorded).
- [ ] Every `HINT` assertion in the bodies is still needed or has been removed on purpose.
- [ ] The run is archived with commit hash and tool version.
- [ ] Every specification changed since the last baseline has been re-reviewed against its requirement.
- [ ] Section 4 has been reread: no claim in the safety case relies on the proof for something it does not show.

## 8. Regression policy

- A change to `fsac-types.ads` or `fsac-fixed_math.ads` invalidates every proof. Re-run the whole core.
- A change to a body only invalidates that unit and the units whose proofs use its postconditions (anything above it in the section 2 diagram).
- CI (`ci/gates.yaml`) fails the merge if the unproved count is above zero or if the number of `Assume` or `Annotate` entries increased.