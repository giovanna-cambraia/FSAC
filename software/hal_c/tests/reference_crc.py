"""Independent reference for the FSAC mailbox CRC (CRC-16/CCITT-FALSE).
Written from the header's layout note, not from the C code."""
import struct

def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

def mailbox_crc(seq, counts, ts, flags):
    return crc16_ccitt_false(struct.pack("<IiIH", seq, counts, ts, flags))

# standard check value for the algorithm itself
assert crc16_ccitt_false(b"123456789") == 0x29B1, "algorithm check failed"

vectors = [
    ("V1", 1, 0, 0, 0),
    ("V2", 0x102, 100000, 123456, 0),
    ("V3", 0xFFFFFFFF, -1, 0xFFFFFFFF, 0x000F),
    ("V4", 7, -32768, 1000, 0x0001),
]
for name, seq, counts, ts, flags in vectors:
    print(f"{name}: seq={seq:#010x} counts={counts} ts={ts:#010x} flags={flags:#06x} -> crc={mailbox_crc(seq,counts,ts,flags):#06x}")