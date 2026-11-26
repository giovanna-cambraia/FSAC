# FSAC: Mission Bus Interface Control Document (ICD)

| Item | Value |
| :--- | :--- |
| File | `docs/04_interface/ICD_mission_bus.md` |
| Interface | Mission bus, MIL-STD-1553B, FSAC acting as a **Remote Terminal (RT)** |
| Zone and flow | Z4 to Z2 through flow F1 (`security_architecture.md`, section 2) |
| Consumer | P6 MISSION_GATEWAY |
| Implemented by | `software/hal_c/include/fsac_gw_1553.h` and `software/hal_c/src/mission_gateway/fsac_gw_1553.c` |
| Tested by | `software/hal_c/tests/test_gw_1553.c` |
| Requirements | `SECR-GW-0001`, `SECR-GW-0002`, `SECR-ARC-0001`, `SECR-ARC-0002`, `SECR-TARA-0004`. Further gateway rules proposed in `requirements_index.md`, section 5.1, are not adopted yet. |
| Threats covered | T-01 to T-07 (`TARA.md`) |
| Status | **Illustrative placeholder table.** The message set in section 4 is invented to exercise the parser. It is to be replaced by the real message set when the `mil1553` project is linked. The *rules* (sections 1 to 3 and 5 to 7) do not depend on the table contents. The gateway is implemented and the owner reports its tests passing; the number of checks is not yet recorded here (open item OI-6). |

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
| P-2 | **Exact shape.** | Word count must equal the row's count. Not "at most", not "at least". The byte length must equal the length the command word implies. |
| P-3 | **No repair.** | A malformed message is dropped as a whole. The parser never trims, pads, reorders or guesses. |
| P-4 | **Mission data is advisory only.** | Nothing accepted here is an input of any flight-critical function. Z0 never reads this data (`security_architecture.md`, section 2.1, flows F4). |
| P-5 | **Drop, count, log. Never react.** | A rejected message increments a counter and may produce a rate-limited log record. It never changes a mode, a latch or a control output (SECR-ARC-0002, SECR-TARA-0004). The gateway interface has no callback and no mode, so a rejection can only move a counter. |
| P-6 | **Bounded everything.** | Fixed maximum frame size, fixed output record size, fixed rate limit per message ID, fixed output ring. |
| P-7 | **The bus is hostile.** | Even a valid RT address and a valid sync pattern are not trusted. A compromised bus controller is assumed possible (attacker AT-1). |

## 3. Bus parameters

| Parameter | Value | Note |
| :--- | :--- | :--- |
| Standard | MIL-STD-1553B | |
| Role of the FSAC | Remote Terminal | It answers the bus controller; it does not control the bus. |
| RT address | `5` | **Placeholder.** Real value from the aircraft integration. |
| Broadcast address | `31` | **Not accepted** in this design (section 6, R-3). |
| Data word | 16 bits | |
| Maximum words per message in the standard | 32 | The gateway accepts at most 8 (section 7). |
| Bus loss behaviour | none | No flight-critical function depends on the bus (P-4). |

### 3.1 Frame format

This describes what the bus driver hands to the gateway. It is a **placeholder**: it must be matched to the real bus driver when the `mil1553` project is linked.

| Item | Rule |
| :--- | :--- |
| Representation | A byte buffer of 16-bit words, little-endian |
| Receive frame (the bus controller sends data to the FSAC) | The command word, then N data words. Length = 2 + 2N bytes |
| Transmit request (the bus controller asks the FSAC for data) | The command word alone. Length = 2 bytes |
| Command word, bits 15 to 11 | RT address |
| Command word, bit 10 | T/R: 1 = the FSAC transmits, 0 = the FSAC receives |
| Command word, bits 9 to 5 | Subaddress |
| Command word, bits 4 to 0 | Word count |
| Word count 0 | Means **32 words** in MIL-STD-1553B. A transmit request with count 0 is not listed and ends as `rej_not_listed`. A receive frame with count 0 implies 66 bytes: it ends as `rej_length` if it is that long (more than 18 bytes), otherwise as `rej_framing`. |
| Subaddresses 0 and 31 | Mode codes in the standard. No mode code is listed, so they end as `rej_not_listed` |

## 4. Message whitelist (illustrative)

**This table is a placeholder.** After the RT address check, a frame matches a row only if its **(T/R, subaddress, word count)** are all equal to the row's. The RT address is checked before (section 6, checks 3 and 4).

T/R means: `R` = bus controller sends to the FSAC (receive), `T` = FSAC sends to the bus controller (transmit).

| Msg ID | RT | T/R | Subaddr | Words | Name | Direction | Meaning |
| :-: | :-: | :-: | :-: | :-: | :--- | :--- | :--- |
| `MB-R-01` | 5 | R | 1 | 4 | `NAV_HINT` | bus to FSAC | Navigation hint: position estimate for display and logging |
| `MB-R-02` | 5 | R | 2 | 2 | `TIME_SYNC` | bus to FSAC | Coarse time reference, advisory |
| `MB-R-03` | 5 | R | 3 | 8 | `MISSION_MODE` | bus to FSAC | Mission phase indication, advisory |
| `MB-T-01` | 5 | T | 1 | 6 | `FSAC_STATUS` | FSAC to bus | Health summary read by the bus controller |
| `MB-T-02` | 5 | T | 2 | 4 | `FSAC_SNAPSHOT` | FSAC to bus | Whitelisted snapshot copied by P3 for P6 to publish |

Rows `MB-T-xx` are *transmit* messages. The FSAC answers them from a dedicated buffer filled by a one-way copy from Z0 (section 5). Their content is limited to what section 5 lists.

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
| TX-5 | A transmit request is the command word alone. Any extra byte is a framing error (`rej_framing`). |
| TX-6 | The answer always has the word count of the row, so the bus controller always gets a response of the right length. When there is no valid data, every word is the "no data" pattern `0xFFFF` and the response is marked not fresh. |
| TX-7 | Transmit data is **fresh** only if it was loaded no more than 5 major frames before the request (a placeholder, 100 ms). Data that was never loaded, is older than that, or carries a load time in the future is **stale** and is answered as in TX-6. |
| TX-8 | A load for transmission is accepted only for a transmit row and only with exactly that row's word count. Anything else is refused as a caller error, and nothing is written. Unused words of the buffer are stored as zero. |

TX-3 matters even though confidentiality is low overall (`security_architecture.md`, section 3): knowing the gains of an unstable airframe helps an attacker craft a worse input, so they stay inside Z0.

## 6. Rejection rules

Every bus event moves exactly one counter. The reasons are mutually exclusive and are checked in this order (the first failure wins).

| Order | Reason | Counter | Typical cause |
| :-: | :--- | :--- | :--- |
| 1 | Length is 0 or above 18 bytes (the longest accepted frame) | `rej_length` | Empty, truncated-to-nothing or oversized frame |
| 2 | Not whole 16-bit words, or the length differs from the length the command word implies (2 bytes for a transmit request, 2 + 2N for a receive frame) | `rej_framing` | Truncation, concatenation, garbage after the frame |
| 3 | RT address is the broadcast address (31) | `rej_broadcast` | See R-3 |
| 4 | RT address is not the FSAC address | `rej_address` | Misrouted or probing traffic |
| 5 | No row matches (T/R, subaddress, word count) | `rej_not_listed` | Unknown message, or wrong word count |
| 6 | A data word is outside its range, or a reserved word is not zero (receive only) | `rej_range` | Out-of-range value |
| 7 | Rate limit for this message ID exceeded | `rej_rate` | Flooding |
| 8 | Output ring full (receive only) | `rej_overrun` | Consumer slow or stalled |

Broadcast is checked before "not the FSAC address" because address 31 is also not 5; the other order would make `rej_broadcast` impossible to reach.

The order is part of the interface: a test can assert which counter moves for each kind of bad input.

Two counters count accepted traffic: `accepted_rx` (one record queued) and `accepted_tx` (one response produced).

### 6.1 Rules around the rejection list

| Rule | Statement |
| :-: | :--- |
| R-1 | A rejected message produces no output record and changes no output ring. It produces no response: the response is empty. |
| R-2 | Counters saturate at their maximum. They never wrap to zero, so a flood cannot reset the evidence. The record sequence number is not a counter: it only orders records and wraps modulo 2^32. |
| R-3 | Broadcast is rejected. A broadcast message cannot be answered, and it reaches every terminal at once, which makes it attractive to an attacker. If the real integration needs it, it is added as an explicit row, not as a mode of the parser. |
| R-4 | Rate limits are per message ID, counted per major frame (20 ms, four minor frames of 5 ms), and apply to receive and transmit messages alike. The limit values are placeholders in section 7. A message that passes check 6 uses one rate slot **before** the ring is checked, so a message dropped for a full ring still counts against its rate limit. |
| R-5 | Log records for rejections are rate limited separately from the counters (SM-09). The counters always count; the log may skip. |
| R-6 | Caller errors are not bus events. A NULL pointer, or an invalid load for transmission, is reported to the caller and moves no counter. |

## 7. Limits (all placeholders)

| Limit | Value | Reason |
| :--- | :--- | :--- |
| Longest accepted frame | 18 bytes (command word plus 8 data words) | The largest listed receive row is 8 words |
| Maximum accepted words per message | 8 | The parser rejects larger counts even if the bus standard allows 32 |
| Maximum messages accepted per major frame, per ID | 2 | Placeholder. Real value from the bus schedule |
| Major frame | 4 minor frames of 5 ms | Part 1, section 4 |
| Output record size | fixed, 32 bytes | One fixed-size record per accepted message, so there is no variable copy |
| Output ring depth | 4 records | Fixed, no allocation (SM-10) |
| Transmit data maximum age | 5 major frames | Placeholder. Older data is answered as "no data" (TX-7) |
| "No data" pattern | `0xFFFF` in every word | TX-4, TX-6 |

The output record is a fixed-size structure, copied by value. It holds the message ID, the number of valid words, a sequence number assigned by the parser, the minor-frame number when the message was accepted, a reserved field that is always 0, and the **validated data words** (unused words are 0). It contains **neither the command word nor the raw frame bytes.**

## 8. Verification

Each row names the group of `software/hal_c/tests/test_gw_1553.c` that checks it. The owner reports that the test passes; the number of checks is not recorded here yet (OI-6).

| Check | Threat | Expected result | Test group |
| :--- | :-: | :--- | :-: |
| One accepted frame per receive row, with every field at its limits | T-02, T-03 | Accepted, record matches | G-02, G-03 |
| Every row with word count off by one (too few, too many) | T-01, T-02 | Dropped, `rej_not_listed` or `rej_framing` | G-04 |
| Wrong RT address, every address from 0 to 31, broadcast | T-02 | Dropped, `rej_address` or `rej_broadcast` | G-04, G-06 |
| Unknown subaddress, wrong T/R, every subaddress by every word count field of a transmit request | T-02 | Dropped, `rej_not_listed`; exactly two transmit rows accepted | G-04 |
| Transmit request with extra bytes | T-01 | Dropped, `rej_framing` | G-04 |
| Out-of-range field, non-zero reserved word | T-03 | Dropped, `rej_range` | G-03 |
| Truncated and over-long input of every length from 0 to 40, allocated at exactly that length | T-01 | Dropped, never reads beyond the input | G-05 |
| Burst of valid frames over the rate limit, and renewal in the next major frame | T-04 | Excess dropped, `rej_rate` | G-07 |
| Output ring full | T-04 | New record dropped, `rej_overrun`, old records intact, no sequence number used | G-07 |
| Transmit with no data, fresh data, stale data, data from the future | T-06 | "No data" or fresh answer as in TX-6 and TX-7; no record queued | G-08 |
| Invalid loads for transmission | T-01 | Refused, nothing written, no counter moved | G-09 |
| Counter saturation | T-04 | Counters stop at maximum | G-10 |
| NULL arguments | | Caller error, no counter moves | G-11 |
| Ring order and wrap | | Records come out in order with consecutive sequence numbers | G-12 |
| Every call moves exactly one counter, and a rejection changes nothing else | T-07 | One counter by one; ring and response unchanged | G-06, and the per-call check in G-13 |
| Deterministic pseudo-random inputs (fuzzing, 200000 frames, fixed seed) | T-01 | No crash, counters consistent, every outcome reached | G-13 |
| Anomaly burst followed by a check of mode and control outputs | T-07 | No change | not testable inside the gateway |

The last row cannot be tested inside the gateway, because the gateway has no access to the mode logic. It is an integration test for Part 6. What the gateway tests do show is that a rejection moves exactly one counter and nothing else (the call-by-call check of group G-13 and G-06), which is the half of the claim that lives here.

## 9. Open items

| ID | Item | Closed by |
| :-: | :--- | :--- |
| OI-1 | Replace sections 4 and 4.1 with the real message set | linking the `mil1553` project |
| OI-2 | Real RT address, subaddress map, rate limits, transmit age | bus integration data |
| OI-3 | Decide whether mode commands (broadcast) are needed | aircraft integration |
| OI-4 | AFDX gateway, if the mission network uses it | later, own table and own parser (`security_architecture.md`, section 9) |
| OI-5 | Link message IDs and the proposed gateway rules to real requirement IDs | `docs/03_requirements/` |
| OI-6 | Record the number of checks of `test_gw_1553` and the compiler version | the owner's next run |
| OI-7 | The claim "never writes outside the output buffer" (`SECR-GW-0002`) needs a run of groups G-05 and G-13 under a memory sanitizer (`-fsanitize=address,undefined`); a normal run does not show it | a Linux or WSL run |
| OI-8 | Match the frame format of section 3.1 to the real bus driver | linking the `mil1553` project |

## 10. Revision history

| Revision | Change |
| :-: | :--- |
| 1 | First version: design only. |
| 2 | Corrections found while implementing and testing the gateway. **Section 6**: broadcast is now checked before "not the FSAC address" (rows 3 and 4 were swapped, which made the broadcast counter unreachable). **Section 7**: the output record is described as holding the validated data words, the number of words, a sequence number, the minor-frame number and a reserved field, and neither the command word nor the raw bytes. **Section 3.1** added: the frame format, including word count 0. **Section 5** gained rules TX-5 to TX-8 for the transmit path (command word alone, answer length, staleness, loading). **Section 6** now gives the exact length rules (18 bytes, whole words, implied length), the two accepted-traffic counters, and rule R-6 (caller errors move no counter); R-4 now says a rate slot is used before the ring check. **Section 7** lists the transmit age, the ring depth and the "no data" pattern. **Section 8** names the test group of each row, adds the transmit and load rows, and records what the gateway tests cannot show. **Section 9** gained OI-6 to OI-8. |