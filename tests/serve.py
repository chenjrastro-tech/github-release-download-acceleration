#!/usr/bin/env python3
"""Deterministic Range-capable test server for the POSIX runner (tests/run-tests-sh.sh).

Usage:  python3 tests/serve.py [port]
Endpoints:
  /ok.bin        3 MB, supports Range
  /big.bin       64 MB, supports Range
  /norange.bin   1 MB, ignores Range (always 200 + full body)
  /short.bin     declares 2 MB, sends only 700 KB then closes
  /e403.bin      always 403 (token/权限/限流的典型脸）
  /flaky.bin     1 MB, first 2 requests get 503 + Retry-After: 1, then normal
  /flaky429.bin  same but 429 (Secondary Rate Limit 的脸）
  /lies416.bin   claims 2 MB but answers every Range with 416
  /redirect404.bin  302 -> /missing.bin (CDN 把资产指到错误路径的典型脸）
Everything else -> 404.  Body is a repeating pattern: byte[i] = (i * 7 + 3) & 0xFF
so any client can verify contents without a fixture file.  The flaky counters are
per-process and only count the first N requests, so the assertion is "eventually
succeeds with correct bytes", never "the Nth request failed" - that keeps the
suite deterministic no matter how many probe requests the runner makes first.
"""
import socket, socketserver, sys, threading

PATTERN = bytes(((i * 7 + 3) & 0xFF) for i in range(1024 * 1024))
SIZES = {"/ok.bin": 3 * 1024 * 1024, "/big.bin": 64 * 1024 * 1024, "/norange.bin": 1024 * 1024,
         "/flaky.bin": 1024 * 1024, "/flaky429.bin": 1024 * 1024}
FLAKY_LEFT = {"/flaky.bin": 2, "/flaky429.bin": 2}
FLAKY_CODE = {"/flaky.bin": 503, "/flaky429.bin": 429}
LOCK = threading.Lock()


def take_flaky(path):
    """返回 (是否还要装失败, 失败码)；每个路径只失败前 2 次。"""
    with LOCK:
        left = FLAKY_LEFT.get(path, 0)
        if left > 0:
            FLAKY_LEFT[path] = left - 1
            return 1, FLAKY_CODE[path]
    return 0, 0

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
        if path == "/e403.bin":
            msg = b"403 Forbidden: rate limit exceeded"
            self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(msg))
            if method != "HEAD":
                self.request.sendall(msg)
            return
        if path == "/redirect404.bin":
            self.request.sendall(b"HTTP/1.1 302 Found\r\nLocation: /missing.bin\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        if path == "/lies416.bin":
            # 声称有 2 MB，但任何 Range 都回 416：用来验证「服务器不老实」时不会把 0 字节当成功
            self.request.sendall(b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */2097152\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        failed, code = take_flaky(path)
        if failed:
            reason = "Service Unavailable" if code == 503 else "Too Many Requests"
            msg = b"retry later"
            self.request.sendall(("HTTP/1.1 %d %s\r\nRetry-After: 1\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % (code, reason, len(msg))).encode())
            if method != "HEAD":
                self.request.sendall(msg)
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