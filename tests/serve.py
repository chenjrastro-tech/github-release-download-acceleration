#!/usr/bin/env python3
"""Deterministic Range-capable test server for the POSIX runner (tests/run-tests-sh.sh).

Usage:  python3 tests/serve.py [port]
Endpoints:
  /ok.bin       3 MB, supports Range
  /big.bin      64 MB, supports Range
  /norange.bin  1 MB, ignores Range (always 200 + full body)
  /short.bin    declares 2 MB, sends only 700 KB then closes
Everything else -> 404.  Body is a repeating pattern: byte[i] = (i * 7 + 3) & 0xFF
so any client can verify contents without a fixture file.
"""
import socket, socketserver, sys, threading

PATTERN = bytes(((i * 7 + 3) & 0xFF) for i in range(1024 * 1024))
SIZES = {"/ok.bin": 3 * 1024 * 1024, "/big.bin": 64 * 1024 * 1024, "/norange.bin": 1024 * 1024}

def body(start, end):
    n = end - start + 1
    base = PATTERN[start % len(PATTERN):] + PATTERN * (n // len(PATTERN) + 2)
    return base[:n]

class Handler(socketserver.BaseRequestHandler):
    def recv_head(self):
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.request.recv(4096)
            if not chunk:
                return None
            buf += chunk
        return buf.decode("latin1")

    def handle(self):
        head = self.recv_head()
        if not head:
            return
        lines = head.split("\r\n")
        method, path = lines[0].split()[0], lines[0].split()[1]
        rng = None
        for ln in lines[1:]:
            if ln.lower().startswith("range:"):
                a, _, b = ln.split("=", 1)[1].partition("-")
                rng = (int(a), int(b) if b else None)
        if path == "/short.bin":
            self.request.sendall(b"HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length: 2097152\r\nConnection: close\r\n\r\n")
            self.request.sendall(body(0, 716799))
            return
        if path not in SIZES:
            self.request.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        size = SIZES[path]
        if rng and path != "/norange.bin":
            start = rng[0]
            end = size - 1 if rng[1] is None else min(rng[1], size - 1)
            if start >= size:
                self.request.sendall(b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%d\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" % size)
                return
            data = body(start, end)
            self.request.sendall(("HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Range: bytes %d-%d/%d\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % (start, end, size, len(data))).encode())
        else:
            data = body(0, size - 1)
            self.request.sendall(("HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % size).encode())
        if method != "HEAD":
            self.request.sendall(data)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18795
    print("serve.py listening on 127.0.0.1:%d" % port, flush=True)
    Server(("127.0.0.1", port), Handler).serve_forever()