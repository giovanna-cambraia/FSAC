# FSAC: Mission Bus Interface Control Document (ICD)

| Item | Value |
| :--- | :--- |
| File | `docs/04_interface/ICD_mission_bus.md` |
| Interface | Mission bus, MIL-STD-1553B, FSAC acting as a **Remote Terminal (RT)** |
| Zone and flow | Z4 to Z2 through flow F1 (`security_architecture.md`, section 2) |
| Consumer | P6 MISSION_GATEWAY (C, DAL C), implemented by `fsac_gw_1553` |
| Requirements | `SECR-GW-0001`, `SECR-GW-0002`, `SECR-ARC-0001`, `SECR-ARC-0002` |
| Threats covered | T-01 to T-07 (`TARA.md`) |
| Status | **Illustrative placeholder table.** The message set in section 4 is invented to exercise the parser. It is to be replaced by the real message set when the `mil1553` project is linked. The *rules* (sections 1 to 3, 5 to 7) do not depend on the table contents. |

## 1. Purpose

This document is the single list of what the mission bus may send to the FSAC. Everything not listed here is dropped.

It exists for three reasons:

1. **Security.** A whitelist is the smallest attack surface the interface can have (`security_architecture.md`, section 5.1).
2. **Traceability.** Each accepted message has an ID, a requirement link, and a test link.
3. **Single source of truth.** The parser's table is generated from, or checked against, section 4. If the code and this table disagree, one of them is a defect.

## 2. Principles

| # | Principle | Consequence |
| :-: | :--- | :--- |
| P-1 | **Default deny.** | A message is accepted only if it matches a row of section 4 exactly. |
| P-2 | **Exact shape.** | Word count must equal the row's count. Not "at most", not "at least". |
| P-3 | **No repair.** | A malformed message is dropped as a whole. The parser never trims, pads, reorders or guesses. |
| P-4 | **Mission data is advisory only.** | Nothing accepted here is an input of any flight-critical function. Z0 never reads this data (`security_architecture.md`, section 2.1, flows F4). |
| P-5 | **Drop, count, log. Never react.** | A rejected message increments a counter and may produce a rate-limited log record. It never changes a mode, a latch or a control output (SECR-ARC-0002, SECR-TARA-0004). |
| P-6 | **Bounded everything.** | Fixed maximum message size, fixed output record size, fixed rate limit per message ID, fixed output buffer. |
| P-7 | **The bus is hostile.** | Even a valid RT address and a valid sync pattern are not trusted. A compromised bus controller is assumed possible (attacker AT-1). |

## 3. Bus parameters

| Parameter | Value | Note |
| :--- | :--- | :--- |
| Standard | MIL-STD-1553B | |
| Role of the FSAC | Remote Terminal | It answers the bus controller; it does not control the bus. |
| RT address | `5` | **Placeholder.** Real value from the aircraft integration. |
| Broadcast address | `31` | **Not accepted** in this design (section 6, R-3). |
| Data word | 16 bits | |
| Maximum words per message | 32 | Standard maximum. The table below uses far smaller counts. |
| Bus loss behaviour | none | No flight-critical function depends on the bus (P-4). |

## 4. Message whitelist (illustrative)

**This table is a placeholder.** The key of a row is **(RT address, T/R, subaddress, word count)**. A frame matches a row only if all four fields are equal.

T/R means: `R` = bus controller sends to the FSAC (receive), `T` = FSAC sends to the bus controller (transmit).

| Msg ID | RT | T/R | Subaddr | Words | Name | Direction | Meaning |
| :-: | :-: | :-: | :-: | :-: | :--- | :--- | :--- |
| `MB-R-01` | 5 | R | 1 | 4 | `NAV_HINT` | bus to FSAC | Navigation hint: position estimate for display and logging |
| `MB-R-02` | 5 | R | 2 | 2 | `TIME_SYNC` | bus to FSAC | Coarse time reference, advisory |
| `MB-R-03` | 5 | R | 3 | 8 | `MISSION_MODE` | bus to FSAC | Mission phase indication, advisory |
| `MB-T-01` | 5 | T | 1 | 6 | `FSAC_STATUS` | FSAC to bus | Health summary read by the bus controller |
| `MB-T-02` | 5 | T | 2 | 4 | `FSAC_SNAPSHOT` | FSAC to bus | Whitelisted snapshot copied by P3 for P6 to publish |

Rows `MB-T-xx` are *transmit* messages. The FSAC answers them from a dedicated buffer filled by a one-way copy (flow Z0 to P6). Their content is limited to what section 5 lists.

### 4.1 Field layout of the accepted messages (illustrative)

Field ranges are the second gate. A message that matches section 4 but has a field outside its range is dropped (threat T-03).

| Msg ID | Word | Field | Type | Range | Note |
| :-: | :-: | :--- | :--- | :--- | :--- |
| `MB-R-01` | 0 | `latitude_hi` | signed 16 | -16384 to 16384 | Scaled units, placeholder scale |
| | 1 | `latitude_lo` | unsigned 16 | 0 to 65535 | Any value |
| | 2 | `longitude_hi` | signed 16 | -32768 to 32767 | Any value |
| | 3 | `longitude_lo` | unsigned 16 | 0 to 65535 | Any value |
| `MB-R-02` | 0 | `time_hi` | unsigned 16 | 0 to 65535 | Any value |
| | 1 | `time_lo` | unsigned 16 | 0 to 65535 | Any value |
| `MB-R-03` | 0 | `phase` | unsigned 16 | 0 to 7 | Eight phases, placeholder |
| | 1 to 7 | `reserved` | unsigned 16 | exactly 0 | A non-zero reserved word is a drop (P-2) |

Rule on reserved words: **a reserved field that is not zero makes the message invalid.** Tolerating it would mean the parser accepts shapes the ICD does not define.

## 5. What the FSAC may transmit

| Rule | Statement |
| :-: | :--- |
| TX-1 | Transmit messages come only from the dedicated buffer filled by the one-way copy. P6 never reads control state to build a reply. |
| TX-2 | Transmitted values are limited to: health summary (coarse), a count of dropped messages, the mode as an enumeration. |
| TX-3 | No gain, no limit, no schedule value, no key, no log content, and no raw sensor value is ever transmitted. |
| TX-4 | If the buffer is empty or stale, the FSAC answers with a defined "no data" pattern. It never answers with whatever was in memory. |

TX-3 matters even though confidentiality is low overall (`security_architecture.md`, section 3): knowing the gains of an unstable airframe helps an attacker craft a worse input, so they stay inside Z0.

## 6. Rejection rules

Every rejection increments exactly one counter. The reasons are mutually exclusive and are checked in this order (the first failure wins).

| Order | Reason | Counter | Typical cause |
| :-: | :--- | :--- | :--- |
| 1 | Input length is zero or exceeds the maximum | `rej_length` | Truncated or oversized frame |
| 2 | Frame boundary is not exact (declared word count and bytes received disagree) | `rej_framing` | Truncation, concatenation, garbage after the frame |
| 3 | RT address not equal to the FSAC address | `rej_address` | Misrouted or probing traffic |
| 4 | Broadcast address used | `rej_broadcast` | See R-3 |
| 5 | No row matches (T/R, subaddress, word count) | `rej_not_listed` | Unknown message, or wrong word count |
| 6 | A field is outside its range, or a reserved word is not zero | `rej_range` | Out-of-range value |
| 7 | Rate limit for this message ID exceeded | `rej_rate` | Flooding |
| 8 | Output buffer slot not free (previous record not consumed) | `rej_overrun` | Consumer slow or stalled |

The order is part of the interface: a test can assert which counter moves for each kind of bad input.

### 6.1 Rules around the rejection list

| Rule | Statement |
| :-: | :--- |
| R-1 | A rejected message produces no output record and changes no output buffer. |
| R-2 | Counters saturate at their maximum. They never wrap to zero, so a flood cannot reset the evidence. |
| R-3 | Broadcast is rejected. A broadcast message cannot be answered, and it reaches every terminal at once, which makes it attractive to an attacker. If the real integration needs it, it is added as an explicit row, not as a mode of the parser. |
| R-4 | Rate limits are per message ID, counted per major frame (20 ms). The limit values are placeholders in section 7. |
| R-5 | Log records for rejections are rate limited separately from the counters (SM-09). The counters always count; the log may skip. |

## 7. Limits (all placeholders)

| Limit | Value | Reason |
| :--- | :--- | :--- |
| Maximum accepted words per message | 8 | The largest row of section 4 is 8 words. The parser rejects larger counts even if the bus standard allows 32. |
| Maximum messages accepted per major frame, per ID | 2 | Placeholder. Real value from the bus schedule. |
| Output record size | fixed, 32 bytes | One fixed-size record per accepted message, so there is no variable copy. |
| Output buffer depth | 4 records | Fixed, no allocation (SM-10). |

The output record is a fixed-size structure, copied by value. It contains the message ID, a sequence number assigned by the parser, and the decoded fields. It **does not** contain the raw frame.

## 8. Verification (feeds `test_gw_1553.c`)

| Check | Threat | Expected result |
| :--- | :-: | :--- |
| One accepted frame per row of section 4, with every field at its minimum and maximum | T-02, T-03 | Accepted, record matches |
| Every row with word count off by one (too few, too many) | T-01, T-02 | Dropped, `rej_not_listed` or `rej_framing` |
| Wrong RT address, broadcast address | T-02 | Dropped, `rej_address` or `rej_broadcast` |
| Unknown subaddress, wrong T/R | T-02 | Dropped, `rej_not_listed` |
| Out-of-range field, non-zero reserved word | T-03 | Dropped, `rej_range` |
| Truncated and over-long input of every length from 0 to a bound above the maximum | T-01 | Dropped, never reads beyond the input |
| Burst of valid frames over the rate limit | T-04 | Excess dropped, `rej_rate` |
| Output buffer full | T-04 | New record dropped, `rej_overrun`, old records intact |
| Deterministic pseudo-random inputs (fuzzing, fixed seed) | T-01 | No crash, no write outside the buffer, counters consistent |
| Counter saturation | T-04 | Counters stop at maximum |
| Anomaly burst followed by a check of mode and control outputs | T-07 | No change |

The last row cannot be fully tested inside the gateway alone, because the gateway has no access to the mode logic. It is an integration test for Part 6.

## 9. Open items

| ID | Item | Closed by |
| :-: | :--- | :--- |
| OI-1 | Replace section 4 and 4.1 with the real message set | linking the `mil1553` project |
| OI-2 | Real RT address, subaddress map, rate limits | bus integration data |
| OI-3 | Decide whether mode commands (broadcast) are needed | aircraft integration |
| OI-4 | AFDX gateway, if the mission network uses it | later, own table and own parser (`security_architecture.md`, section 9) |
| OI-5 | Link message IDs to real requirement IDs | `docs/03_requirements/SEC/` |