"""Optional real-SSH regression: the producer stays open until replies arrive.

Uses only fixed diagnostic data. --audio-probe plays silence to the receiver's
configured virtual output and never posts the voice key.
"""
import argparse
import base64
import os
import re
import select
import struct
import subprocess
import time


def run(host, audio):
    mode = "--relay" if audio else "--stdio-self-test"
    script = "& (Join-Path $env:LOCALAPPDATA 'SayAllRemoteVoice\\SayAllRemoteVoice.exe') " + mode
    command = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
               host, "powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand",
               base64.b64encode(script.encode("utf-16le")).decode()]
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, bufsize=0)
    buffer = bytearray()

    def read():
        deadline = time.monotonic() + 8
        while b"\n" not in buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([child.stdout], [], [], remaining)[0]:
                raise TimeoutError("No reply while producer remained open")
            chunk = os.read(child.stdout.fileno(), 4096)
            if not chunk:
                raise EOFError("Receiver closed")
            buffer.extend(chunk)
            if len(buffer) > 90000:
                raise ValueError("Response bound exceeded")
        index = buffer.index(10)
        raw = bytes(buffer[:index]).strip()
        del buffer[:index + 1]
        return base64.b64decode(raw, validate=True)

    try:
        assert read() == struct.pack("<I", 2) + bytes([128, 1])
        for _ in range(2 if audio else 1):
            body = bytes([6]) if audio else bytes([85, 0, 10, 13, 255, 128])
            frame = struct.pack("<I", len(body)) + body
            child.stdin.write(base64.b64encode(frame) + b"\n")
            child.stdin.flush()
            result = read()  # Deliberately before closing stdin.
            if audio:
                assert len(result) == 13 and result[4] == 134
                assert struct.unpack("<q", result[5:])[0] == 32000
            else:
                assert result == frame
        print("PASS continuous SSH replies before EOF; fixed diagnostic data; no voice key posted")
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=3)
        child.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--audio-probe", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", args.host):
        parser.error("Use a configured SSH host alias")
    run(args.host, args.audio_probe)
