#!/usr/bin/env python3
"""Print the signing certificate size and SHA-256 of one or more APKs.

Reads the APK Signature Scheme v2/v3/v3.1 blocks and prints, for every unique
DER certificate found, one line in the format KernelSU-style Kbuild files
expect for KSU_EXPECTED_SIZE*/KSU_EXPECTED_HASH*:

    0x<size as 4 hex digits> <lowercase sha256 of the DER certificate>

Used to trust the FinaSU release manager through the kernel's second
signature slot (KSU_EXPECTED_SIZE2/KSU_EXPECTED_HASH2).

Based on scripts/finasu_compat/extract_manager_cert.py from
https://github.com/muling0721/GKI_FinaSU (GPL-3.0).

Usage:
    extract-manager-cert.py <apk> [<apk> ...]

Exit status is 0 when at least one certificate was found, 1 otherwise.
"""

import hashlib
import struct
import sys

EOCD_MAGIC = b"PK\x05\x06"
SIG_BLOCK_MAGIC = b"APK Sig Block 42"
V2_BLOCK_ID = 0x7109871A
V3_BLOCK_ID = 0xF05368C0
V31_BLOCK_ID = 0x1B93AD61
SIGNER_BLOCK_IDS = (V2_BLOCK_ID, V3_BLOCK_ID, V31_BLOCK_ID)


def u32(buf, off):
	return struct.unpack_from("<I", buf, off)[0]


def u64(buf, off):
	return struct.unpack_from("<Q", buf, off)[0]


def length_prefixed(buf, off):
	"""Return (payload, next_offset) for a uint32 length-prefixed field."""
	size = u32(buf, off)
	start = off + 4
	end = start + size
	if end > len(buf):
		raise ValueError("length-prefixed field runs past its container")
	return buf[start:end], end


def signer_certs(signer):
	"""Yield DER certificates from one v2/v3 signer's signed data."""
	signed_data, _ = length_prefixed(signer, 0)
	_digests, off = length_prefixed(signed_data, 0)
	certs, _ = length_prefixed(signed_data, off)
	pos = 0
	while pos < len(certs):
		der, pos = length_prefixed(certs, pos)
		yield der


def central_directory_offset(data):
	"""Return the ZIP central directory offset from the EOCD record."""
	# EOCD is 22 bytes plus an optional comment of up to 65535 bytes.
	eocd = data.rfind(EOCD_MAGIC, max(0, len(data) - 22 - 0xFFFF))
	if eocd < 0 or eocd + 22 > len(data):
		raise ValueError("ZIP end of central directory record not found")
	return u32(data, eocd + 16)


def extract_certs(data):
	"""Yield DER certificates from the APK signing block, if present."""
	# The signing block sits immediately before the central directory and
	# ends with its 16-byte magic.
	magic_off = central_directory_offset(data) - len(SIG_BLOCK_MAGIC)
	if magic_off < 8 or data[magic_off : magic_off + len(SIG_BLOCK_MAGIC)] != SIG_BLOCK_MAGIC:
		return
	block_end = magic_off + len(SIG_BLOCK_MAGIC)
	block_size = u64(data, magic_off - 8)
	block_start = block_end - block_size - 8
	if block_start < 0 or u64(data, block_start) != block_size:
		raise ValueError("APK signing block size fields disagree")

	# ID-value pairs use uint64 length prefixes; everything inside the
	# v2/v3 blocks uses uint32.
	pairs = data[block_start + 8 : magic_off - 8]
	off = 0
	while off + 12 <= len(pairs):
		pair_len = u64(pairs, off)
		value_start = off + 8
		pair_id = u32(pairs, value_start)
		value = pairs[value_start + 4 : value_start + pair_len]
		off = value_start + pair_len
		if pair_id not in SIGNER_BLOCK_IDS:
			continue
		signers, _ = length_prefixed(value, 0)
		pos = 0
		while pos < len(signers):
			signer, pos = length_prefixed(signers, pos)
			yield from signer_certs(signer)


def main(argv):
	if len(argv) < 2:
		print("usage: extract-manager-cert.py <apk> [<apk> ...]", file=sys.stderr)
		return 2

	seen = set()
	for path in argv[1:]:
		with open(path, "rb") as f:
			data = f.read()
		try:
			certs = list(extract_certs(data))
		except (ValueError, struct.error) as e:
			print(f"{path}: malformed APK signing block: {e}", file=sys.stderr)
			continue
		if not certs:
			print(f"{path}: no v2/v3 signing certificate found", file=sys.stderr)
		for der in certs:
			digest = hashlib.sha256(der).hexdigest()
			if digest in seen:
				continue
			seen.add(digest)
			print("0x%04x %s" % (len(der), digest))

	return 0 if seen else 1


if __name__ == "__main__":
	sys.exit(main(sys.argv))
