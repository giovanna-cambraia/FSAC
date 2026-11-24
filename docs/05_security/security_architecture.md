# FSAC: Airworthiness Security Architecture

| Item | Value |
| :--- | :--- |
| File | `docs/05_security/security_architecture.md` |
| Standards vocabulary | RTCA DO-326A / EUROCAE ED-202A (process), DO-356A / ED-203A (methods) |
| Scope | One FSAC LRU and its interfaces: mission bus, maintenance and data loader, debug, CCDL, sensor buses, supply chain |
| Partners | `TARA.md` (risk assessment), `ICD_mission_bus.md`, `secure_boot.md`, `software/hal_c/` (gateway and boot logic) |
| Status | Design document of a learning and portfolio project. It uses the vocabulary and the structure of the standard. **It is not a certified security case**, and section 9 lists what it does not cover. |

## 1. Purpose and the one principle that governs the design

The FSAC keeps an aerodynamically unstable aircraft flyable. For such a computer, security has to answer one question: *can an adversary, or an accident that looks like one, make the flight-critical function fail or misbehave?*

**The governing principle: security may never reduce the availability of the flight-critical function in flight.**

This is the opposite of the usual reflex ("when in doubt, shut down"). A security reaction that stops the control law in flight is itself a safety hazard, and an attacker who can trigger it has won. So the rules are:

| Situation | Allowed reaction | Forbidden reaction |
| :--- | :--- | :--- |
| Untrusted input arrives in flight (a malformed bus message, a failed authentication) | **Drop it**, count it, log it | stop, reset, degrade the mode |
| An update or a boot image fails verification **on the ground** | Refuse to start or to install | start anyway |
| A security anomaly is seen in flight | Log it, rate-limited | change any control behaviour |

The only way a security event may touch the flight function is **before flight, on the ground**, where refusing is safe.

## 2. Trust zones and the allowed flows

```
 +------------------------------------------------------------------------------+
 |  Z4  UNTRUSTED WORLD: everything outside the LRU                             |
 |      mission systems, other aircraft systems, ground equipment, the supply   |
 |      chain, anyone with physical access                                      |
 +-----+------------------------+------------------------+----------------------+
       | F1 mission bus         | F2 maintenance /       | F3 debug (JTAG, UART)
       | (1553B RT / AFDX)      |    data loader         |    DISABLED in production
 +-----v------------+     +-----v--------------+         X
 | Z2  MISSION      |     | Z3  MAINTENANCE    |
 |  INTERFACE       |     |  P7 MAINT_SECURITY |
 |  P6 gateway      |     |  authenticated,    |
 |  DAL C           |     |  interlocked       |
 +-----+------------+     +-----+--------------+
       | F4 one-way,        | F5 verified OFP,
       |  sanitized,        |  verified parameters
       |  fixed-size        |  (ground only)
 +-----v--------------------v---------------------------------------------------+
 |  Z1  SECURITY SERVICES: hardware Root of Trust (keys, counters, secure boot) |
 +-----+------------------------------------------------------------------------+
       | F6 boot measurements, accept / refuse
 +-----v------------------------------------------------------------------------+
 |  Z0  FLIGHT-CRITICAL: P1 sensor ingest, P2 signal mgmt, P3 control laws,     |
 |      P4 actuator cmd, P5 CCDL; I/O FPGA; actuators                           |
 +------------------------------------------------------------------------------+
       ^ F7 CCDL between the three LRUs        ^ F8 sensors and actuators (wired)
```

### 2.1 The rules of the flows

| Flow | Direction | Rule |
| :--- | :--- | :--- |
| F1 mission bus to P6 | into Z2 only | Every message passes the whitelist parser (`fsac_gw_1553`). Anything not on the list is dropped. |
| F4 P6 to Z0 | one-way, narrow | Only a small, fixed-size, range-checked record, copied into a buffer. Z0 never reads the bus and never calls into P6. Z0 does not depend on P6 being alive. |
| Z0 to P6 | one-way, narrow | P3 copies a whitelisted snapshot into a dedicated buffer that P6 reads. P6 has no access to control state (MPU-enforced). |
| F2 maintenance to P7 | into Z3 only | Authenticated session, and only while the aircraft is on the ground with the maintenance switch armed (section 5, SM-05). |
| F5 P7 to storage | ground only | An OFP or parameter file is installed only after its signature and its anti-rollback counter verify. |
| F3 debug | none | Disabled by hardware fuse in production units. |
| F7 CCDL | between LRUs | Physically internal. Frames carry an authentication code (SM-07) so a corrupted or injected frame is rejected. |
| F8 sensors, actuators | wired | Protected by physical segregation and by the safety design (voting, FDIR), not by cryptography. |

**There is no path from Z2, Z3 or Z4 into Z0 that is not either a sanitized one-way copy or a verified ground-only installation.** That statement is the security architecture in one sentence; every measure below supports it.

## 3. Assets

Priority is given as the order in which the properties matter. For this system, **integrity and availability dominate; confidentiality is low** (there are no secrets in flight except the keys, and those never leave the Root of Trust).

| ID | Asset | Where | What matters | Why |
| :-: | :--- | :--- | :--- | :--- |
| A1 | Operational Flight Program (OFP) image | non-volatile storage, partitions | Integrity, then availability | A modified OFP is a modified control law |
| A2 | Keys: signing public keys, device keys | Root of Trust | Integrity (public), confidentiality (private, never on the LRU) | Root of every other guarantee |
| A3 | Control parameters (gains, limits, schedule) | parameter file | Integrity | A wrong gain on an unstable airframe is as dangerous as wrong code |
| A4 | Sensor data and actuator commands | I/O FPGA, P1 to P4 | Integrity, availability | The control loop itself |
| A5 | Mode and health state | P2, Modes, P8 | Integrity | An attacker who resets a latch re-enables a failed sensor |
| A6 | Audit and fault log | P8 | Integrity (tamper evidence) | Evidence after an incident |
| A7 | Mission data (inbound) | P6 | Integrity of what is accepted | Its only legitimate use is advisory |
| A8 | Time and sequence counters | FPGA, RoT | Integrity | Replay protection depends on them |

## 4. Entry points

| ID | Entry point | Reaches | Exposure |
| :-: | :--- | :--- | :--- |
| E1 | Mission bus (1553B RT, AFDX) | P6 | In flight, a shared bus, other systems on it can be compromised |
| E2 | Maintenance and data-loader port | P7 | On the ground, physical access to a connector |
| E3 | Debug ports (JTAG, UART) | everything | Physical, if left enabled |
| E4 | CCDL between LRUs | P5 | Internal, a fault or a compromised sibling LRU |
| E5 | Sensor buses (A429, serial) | P1, FPGA | Wired, from the sensor units |
| E6 | Supply chain: toolchain, libraries, hardware | the OFP, the FPGA bitstream | Before the aircraft exists |
| E7 | Removable media and ground tools | E2 | The laptop that carries the update |
| E8 | Physical and electromagnetic (power, EMI, lightning) | hardware | Covered by DO-160G, listed here only to be explicit |

## 5. Security measures

Each measure names the part of the repository that implements or will implement it.

| ID | Measure | Counters | Implemented by |
| :-: | :--- | :--- | :--- |
| SM-01 | **Secure boot chain**: ROM Root of Trust verifies the loader, which verifies the hypervisor, which verifies each partition image. The chain stops on the first failure. | modified OFP (A1), E2, E6 | `secure_boot.md`, `fsac_secure_boot` |
| SM-02 | **Signed OFP and parameter updates with a monotonic anti-rollback counter**: ECC signature (NIST P-384 or Ed25519) over a manifest; an older version is refused even if its signature is valid. | downgrade to a known-vulnerable OFP | same |
| SM-03 | **Partition isolation**: MPU-enforced regions between P6, P7 and Z0 (access matrix in Part 1, section 3). | compromise of P6 or P7 spreading to the control laws | `software/config/memory_map/` |
| SM-04 | **One-way mission gateway with a whitelist parser**: strict frame boundaries, a table of permitted messages, field range checks, rate limits, fixed output buffer. | malformed or hostile bus traffic (E1) | `ICD_mission_bus.md`, `fsac_gw_1553` |
| SM-05 | **Maintenance interlock**: session allowed only with weight-on-wheels and an armed maintenance switch; challenge-response authentication; session time-out; no session in flight. | E2, E7, A1, A3 | `P7`, `ICD_maintenance.md` |
| SM-06 | **Debug lock**: debug interfaces fused off in production. | E3 | hardware, `HW_PHAC` |
| SM-07 | **Authenticated CCDL frames**: a message authentication code (CMAC or HMAC with a per-LRU key) plus a sequence number. A CRC detects corruption; it does not stop injection. | E4 | `ICD_ccdl.md` (later) |
| SM-08 | **Parameter integrity**: parameter files are signed, and the predicates of `Control.Params` and `Voter_Params` are the last gate. | A3 | `tools/codegen/`, Part 2 |
| SM-09 | **Tamper-evident log**: each record carries a hash of the previous record; security events are rate limited so the log cannot be flooded. | A6 | `P8` |
| SM-10 | **Resource discipline**: no dynamic allocation, bounded loops, bounded interrupt time, no recursion, restricted language subset. | denial of service by resource exhaustion | `fsac.adc`, MISRA record |
| SM-11 | **Reproducible builds and a pinned toolchain**: two builds of one commit give identical images; the toolchain containers are pinned by hash; a software bill of materials is kept. | E6 | `ci/gates.yaml`, `ci/docker/` |
| SM-12 | **Key management**: private keys exist only in a secure signing facility, never in the repository; the device holds public keys; revocation is by counter; the test keys are separate and labelled. | A2 | `secure_boot.md` |

### 5.1 What the parser does NOT do, on purpose

SM-04 is not a firewall that tries to understand and repair traffic. It accepts a very small set of exactly-shaped messages and drops everything else. A parser that tries to be tolerant is a parser with a larger attack surface.

## 6. The interface between security and safety

| Question | Answer |
| :--- | :--- |
| Can a security measure make the aircraft less safe? | Only if it reacts in flight by stopping or degrading. The rules of section 1 forbid that. |
| What does a dropped message cost? | Nothing in Z0: the control laws never depend on mission data. |
| What if the secure boot refuses to start one LRU? | That LRU is lost, like any fail-silent LRU (ADR-001). The other two continue; the mode logic sees `Healthy_Lrus = 2` and goes to Degraded_1. |
| What is the severity scale used to rate a threat? | The failure-condition classes of the Functional Hazard Assessment (`FHA.md`). A security threat inherits the severity of the safety effect it can cause. |
| Who decides how much assurance a measure needs? | The security risk assessment (`TARA.md`), through the security assurance level that DO-356A / ED-203A associate with the risk. |

## 7. Mapping to the DO-326A process

| Step of the process | Artifact in this repository | State |
| :--- | :--- | :-: |
| Plan for security aspects of certification | `docs/05_security/PSecAC.md` | to write (Part 6) |
| Security scope definition | sections 2 to 4 of this document | done |
| Preliminary security risk assessment | `TARA.md` | next file |
| Security measures | section 5 of this document | done (design) |
| Security effectiveness: verification | tests of `fsac_gw_1553`, `fsac_secure_boot`; fuzzing; later a penetration test plan | in progress |
| Vulnerability and continued airworthiness | out of scope for a learning project | not covered |

## 8. Requirements (placeholders to link in `docs/03_requirements/SEC/`)

| ID | Statement |
| :--- | :--- |
| SECR-ARC-0001 | No untrusted input shall reach Z0 other than through a sanitized one-way copy or a verified ground-only installation. |
| SECR-ARC-0002 | A security reaction in flight shall never stop or degrade the flight-critical function. |
| SECR-BOOT-0001 | Every executable image shall be verified against a signed manifest before it runs. |
| SECR-BOOT-0002 | An image whose version counter is below the stored counter shall be refused. |
| SECR-GW-0001 | The mission gateway shall accept only messages listed in the mission-bus ICD, with the exact word count and field ranges listed there. |
| SECR-GW-0002 | The mission gateway shall never write outside its output buffer, for any input. |
| SECR-MNT-0001 | Maintenance sessions shall exist only on the ground with the maintenance switch armed. |
| SECR-DBG-0001 | Debug interfaces shall be disabled in production hardware. |
| SECR-LOG-0001 | Security events shall be logged with a hash chain and a rate limit. |

## 9. What this document does not cover (residual risk)

1. **The cryptographic primitives.** The design uses a vetted library or hardware block. No algorithm is written in this repository, and none should be.
2. **The hardware Root of Trust.** It is specified by its interface and behaviour; its internal design, fuses and side-channel resistance are DO-254 and supplier matters.
3. **Side channels and fault injection** (timing, power, voltage glitching against the boot). Not analysed.
4. **AFDX.** Only the 1553B path is designed in detail; an AFDX gateway would need its own table and its own parser.
5. **Supply chain depth.** SM-11 reduces the risk; it does not remove the trust in compiler, libraries and silicon.
6. **No penetration test has been done.** Section 7 lists it as future work.
7. **Continued airworthiness** (handling vulnerabilities after delivery) is out of scope.