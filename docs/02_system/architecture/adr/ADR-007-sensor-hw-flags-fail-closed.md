# ADR-007: Sensor hardware flags are fail-closed

| Item | Value |
| :--- | :--- |
| Status | Accepted |
| Date | 2026-11-11 |
| Affects | `fsac_hsi_sensor.h`, `fsac_sensor_ingest.c`, tests R-20 .. R-24 |
| Requirement | HLR-HSI-0013 (new): a sensor sample shall be rejected when any bit of the FPGA hw_flags word is set |

## Context
The I/O FPGA reports sensor condition in a 16-bit hw_flags word. Four bits are defined today (over-range, ADC fault, link fault, BIT fail). The driver first accepted a sample when no *defined* bit was set and ignored the others.

## Decision
A sample is valid only when hw_flags is exactly zero. Any set bit, defined or not, gives FSAC_SENSOR_ERR_HW. The named bits are kept for diagnostics only (FSAC_HWFLAG_DEFINED_MASK).

## Reasons
1. An unknown bit with a valid CRC means the FPGA reported something this software does not understand. Treating that as healthy accepts data the hardware flagged as suspect.
2. The usual cause is a version mismatch between FPGA bitstream and software. Failing closed makes the mismatch visible at integration instead of silent in flight.
3. The cost is bounded: a mismatched pair invalidates sensors, and the architecture already handles invalid sensors (voter, FDIR).

## Consequences
- A new informational (non-fault) flag cannot be added without a software change. This is intended: it forces a reviewed update of the mask and the interface description.
- Configuration management must record the FPGA bitstream version together with the software baseline (SCI/HCI cross-reference).

## Alternatives rejected
- Ignore unknown bits (original behaviour): silent acceptance of unexplained hardware reports.
- Fault only on a per-version list of bits: more complex, same failure mode when the list is out of date.

## Verification
Tests R-20 (each defined bit), R-21 and R-22 (unknown bits), R-23 (all bits), R-24 (zero accepted).