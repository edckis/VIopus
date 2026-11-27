"""Per-thread CPU split for a running process: user time vs kernel time.

usage: python threadtimes.py <pid> [--seconds 20] [--out file]

Groups threads by start address (the title's threads all start at the same
place in its image; ours carry names). Kernel time on the title's threads is
page faults (write watch, guards) and system calls: work the layer causes,
not the title's own code. Read-only.
"""
import argparse, collections, ctypes, sys, time
from ctypes import wintypes as w

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
nt = ctypes.WinDLL("ntdll")
k32.OpenThread.restype = w.HANDLE
k32.OpenThread.argtypes = [w.DWORD, w.BOOL, w.DWORD]
k32.CreateToolhelp32Snapshot.restype = w.HANDLE
k32.GetThreadTimes.argtypes = [w.HANDLE] + [ctypes.POINTER(w.FILETIME)] * 4
k32.GetThreadDescription.argtypes = [w.HANDLE, ctypes.POINTER(w.LPWSTR)]
k32.GetThreadDescription.restype = ctypes.c_long
k32.LocalFree.argtypes = [ctypes.c_void_p]
nt.NtQueryInformationThread.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.ULONG, ctypes.POINTER(w.ULONG)]


class THREADENTRY32(ctypes.Structure):
    _fields_ = [("dwSize", w.DWORD), ("cntUsage", w.DWORD), ("th32ThreadID", w.DWORD),
                ("th32OwnerProcessID", w.DWORD), ("tpBasePri", w.LONG), ("tpDeltaPri", w.LONG),
                ("dwFlags", w.DWORD)]


def tids(pid):
    snap = k32.CreateToolhelp32Snapshot(0x4, 0)
    e = THREADENTRY32(); e.dwSize = ctypes.sizeof(e)
    out, ok = [], k32.Thread32First(snap, ctypes.byref(e))
    while ok:
        if e.th32OwnerProcessID == pid:
            out.append(e.th32ThreadID)
        ok = k32.Thread32Next(snap, ctypes.byref(e))
    k32.CloseHandle(snap)
    return out


def times(h):
    c, x, k, u = (w.FILETIME() for _ in range(4))
    if not k32.GetThreadTimes(h, ctypes.byref(c), ctypes.byref(x), ctypes.byref(k), ctypes.byref(u)):
        return None
    f = lambda t: (t.dwHighDateTime << 32 | t.dwLowDateTime) / 1e4  # ms
    return f(k), f(u)


def name(h):
    p = w.LPWSTR()
    if k32.GetThreadDescription(h, ctypes.byref(p)) >= 0 and p.value:
        s = p.value; k32.LocalFree(p); return s
    return ""


def start(h):
    v = ctypes.c_uint64()
    nt.NtQueryInformationThread(h, 9, ctypes.byref(v), 8, None)
    return v.value


ap = argparse.ArgumentParser()
ap.add_argument("pid", type=int)
ap.add_argument("--seconds", type=float, default=20)
ap.add_argument("--out", default="")
a = ap.parse_args()
hs = {}
for t in tids(a.pid):
    h = k32.OpenThread(0x0040 | 0x0800, False, t)  # QUERY_INFORMATION | QUERY_LIMITED
    if h:
        hs[t] = h
t0 = {t: times(h) for t, h in hs.items()}
time.sleep(a.seconds)
t1 = {t: times(h) for t, h in hs.items()}
rows = []
for t, h in hs.items():
    if t0[t] and t1[t]:
        k, u = t1[t][0] - t0[t][0], t1[t][1] - t0[t][1]
        rows.append((t, name(h), start(h), k / a.seconds, u / a.seconds))
groups = collections.defaultdict(lambda: [0, 0.0, 0.0])
for t, nm, st, k, u in rows:
    key = nm.rstrip("0123456789").rstrip("-") if nm else "start 0x%x" % st
    g = groups[key]; g[0] += 1; g[1] += k; g[2] += u
lines = ["%.0f s; CPU ms per second (1000 = one core)" % a.seconds,
         "%-40s %4s %9s %9s %7s" % ("group", "thr", "kernel", "user", "kern%")]
for key, (n, k, u) in sorted(groups.items(), key=lambda kv: -(kv[1][1] + kv[1][2]))[:25]:
    lines.append("%-40s %4d %9.0f %9.0f %6.0f%%" % (key[:40], n, k, u, 100 * k / max(k + u, 1e-9)))
lines.append("busiest single threads:")
for t, nm, st, k, u in sorted(rows, key=lambda r: -(r[3] + r[4]))[:12]:
    lines.append("  tid %6d %-28s start 0x%x  kernel %5.0f user %5.0f" % (t, nm or "-", st, k, u))
text = "\n".join(lines)
print(text)
if a.out:
    open(a.out, "w", encoding="utf-8").write(text + "\n")
