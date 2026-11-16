#!/usr/bin/env python3
"""Verify the packaged IPA without rewriting the Mach-O or Info.plist."""
import hashlib
import json
import pathlib
import plistlib
import struct
import subprocess
import sys
import tempfile
import zipfile

ipa = pathlib.Path(sys.argv[1]).resolve()
EXPECTED_BUNDLE_ID = "local.xchat.transfer"
EXPECTED_GROUP = "group.local.xchat.transfer"


def macho_build(data):
    magic, cpu, _subtype, _filetype, commands, _size, _flags, _reserved = struct.unpack_from("<8I", data)
    assert magic == 0xFEEDFACF and cpu == 0x100000C, "Expected arm64 Mach-O"
    offset = 32
    for _ in range(commands):
        cmd, length = struct.unpack_from("<2I", data, offset)
        assert length >= 8
        if cmd == 0x32:  # LC_BUILD_VERSION
            platform, minimum, sdk, _ntools = struct.unpack_from("<4I", data, offset + 8)
            decode = lambda v: f"{v >> 16}.{(v >> 8) & 255}" + (f".{v & 255}" if v & 255 else "")
            return {"platform": platform, "minimumOS": decode(minimum), "sdk": decode(sdk), "architecture": "arm64"}
        offset += length
    raise AssertionError("LC_BUILD_VERSION absent")


with zipfile.ZipFile(ipa) as z:
    assert z.testzip() is None, "ZIP integrity failed"
    assert all(not pathlib.PurePosixPath(n).is_absolute() and ".." not in pathlib.PurePosixPath(n).parts
               for n in z.namelist()), "Unsafe ZIP entry"
    root = "Payload/WQtool.app/"
    info = plistlib.loads(z.read(root + "Info.plist"))
    binary = z.read(root + info["CFBundleExecutable"])
    build = macho_build(binary)
    assert build["platform"] == 2, build
    assert info["CFBundleIdentifier"] == EXPECTED_BUNDLE_ID, info["CFBundleIdentifier"]
    assert info["CFBundleDisplayName"] == "WQtool", info.get("CFBundleDisplayName")
    assert info["MinimumOSVersion"] == build["minimumOS"], (info.get("MinimumOSVersion"), build)
    assert not [n for n in z.namelist() if n.endswith(".appex/Info.plist")], "Unexpected app extension"

    with tempfile.TemporaryDirectory(prefix="wqtool-ipa-verify-") as tmp:
        z.extractall(tmp)
        app = pathlib.Path(tmp) / "Payload/WQtool.app"
        signature = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                                   capture_output=True, text=True)
        assert signature.returncode == 0, signature.stderr
        entdata = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)],
                                 capture_output=True, check=True).stdout
        entitlements = plistlib.loads(entdata)
        assert entitlements.get("com.apple.security.application-groups") == [EXPECTED_GROUP], entitlements
        has_profile = (app / "embedded.mobileprovision").exists()

digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
report = {
    "ipa": str(ipa),
    "sha256": digest,
    "bytes": ipa.stat().st_size,
    "mainExecutable": build,
    "bundleID": info["CFBundleIdentifier"],
    "displayName": info["CFBundleDisplayName"],
    "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"],
    "entitlements": entitlements,
    "zipIntegrity": "passed",
    "signature": "adhoc: verification passed",
    "embeddedProvisioningProfile": has_profile,
    "installation": "not tested; adhoc IPA is a re-signing input",
    "note": "Keep the App Group entitlement when re-signing, otherwise container access returns nothing.",
}
print(json.dumps(report, ensure_ascii=False, indent=2))
