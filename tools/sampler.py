"""Poor man's sampling profiler for a Windows process (read-only apart from
briefly suspending the sampled thread for a few hundred microseconds).

usage: python sampler.py <pid> [--seconds 30] [--hz 200] [--top 3] [--out report.txt]

1. Measures per-thread CPU time for 2 s and picks the busiest `--top` threads.
2. Samples them: suspend, read RIP/RSP/RBP, walk the stack with dbghelp, resume.
3. Reports, per thread: CPU share, hottest functions by self time and by
   inclusive time (symbols from the exe's PDB next to it).
"""
import argparse, collections, ctypes, os, sys, time
from ctypes import wintypes as w

DBGHELP = r"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\dbghelp.dll"
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
dbg = ctypes.WinDLL(DBGHELP, use_last_error=True)

PROCESS_RIGHTS = 0x0010 | 0x0400 | 0x0008 | 0x1000  # VM_READ | QUERY_INFORMATION | VM_OPERATION | QUERY_LIMITED
THREAD_RIGHTS = 0x0002 | 0x0008 | 0x0040 | 0x0800   # SUSPEND_RESUME | GET_CONTEXT | QUERY_INFORMATION | QUERY_LIMITED
TH32CS_SNAPTHREAD = 0x4
CONTEXT_AMD64 = 0x100000
CONTEXT_CONTROL = CONTEXT_AMD64 | 0x1
CONTEXT_INTEGER = CONTEXT_AMD64 | 0x2

k32.OpenProcess.restype = w.HANDLE
k32.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
k32.OpenThread.restype = w.HANDLE
k32.OpenThread.argtypes = [w.DWORD, w.BOOL, w.DWORD]
k32.SuspendThread.argtypes = [w.HANDLE]
k32.SuspendThread.restype = w.DWORD
k32.ResumeThread.argtypes = [w.HANDLE]
k32.ResumeThread.restype = w.DWORD
k32.GetThreadContext.argtypes = [w.HANDLE, ctypes.c_void_p]
k32.CloseHandle.argtypes = [w.HANDLE]
k32.GetThreadTimes.argtypes = [w.HANDLE] + [ctypes.POINTER(w.FILETIME)] * 4
k32.GetThreadDescription.argtypes = [w.HANDLE, ctypes.POINTER(w.LPWSTR)]
k32.GetThreadDescription.restype = ctypes.c_long
k32.LocalFree.argtypes = [ctypes.c_void_p]
k32.CreateToolhelp32Snapshot.restype = w.HANDLE
k32.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]


class THREADENTRY32(ctypes.Structure):
    _fields_ = [("dwSize", w.DWORD), ("cntUsage", w.DWORD), ("th32ThreadID", w.DWORD),
                ("th32OwnerProcessID", w.DWORD), ("tpBasePri", w.LONG), ("tpDeltaPri", w.LONG),
                ("dwFlags", w.DWORD)]


class ADDRESS64(ctypes.Structure):
    _fields_ = [("Offset", ctypes.c_uint64), ("Segment", w.WORD), ("Mode", w.DWORD)]


class KDHELP64(ctypes.Structure):
    _fields_ = [("Thread", ctypes.c_uint64), ("ThCallbackStack", w.DWORD), ("ThCallbackBStore", w.DWORD),
                ("NextCallback", w.DWORD), ("FramePointer", w.DWORD), ("KiCallUserMode", ctypes.c_uint64),
                ("KeUserCallbackDispatcher", ctypes.c_uint64), ("SystemRangeStart", ctypes.c_uint64),
                ("KiUserExceptionDispatcher", ctypes.c_uint64), ("StackBase", ctypes.c_uint64),
                ("StackLimit", ctypes.c_uint64), ("BuildVersion", w.DWORD),
                ("RetpolineStubFunctionTableSize", w.DWORD), ("RetpolineStubFunctionTable", ctypes.c_uint64),
                ("RetpolineStubOffset", w.DWORD), ("RetpolineStubSize", w.DWORD),
                ("Reserved0", ctypes.c_uint64 * 2)]


class STACKFRAME64(ctypes.Structure):
    _fields_ = [("AddrPC", ADDRESS64), ("AddrReturn", ADDRESS64), ("AddrFrame", ADDRESS64),
                ("AddrStack", ADDRESS64), ("AddrBStore", ADDRESS64), ("FuncTableEntry", ctypes.c_void_p),
                ("Params", ctypes.c_uint64 * 4), ("Far", w.BOOL), ("Virtual", w.BOOL),
                ("Reserved", ctypes.c_uint64 * 3), ("KdHelp", KDHELP64)]


class SYMBOL_INFO(ctypes.Structure):
    _fields_ = [("SizeOfStruct", w.ULONG), ("TypeIndex", w.ULONG), ("Reserved", ctypes.c_uint64 * 2),
                ("Index", w.ULONG), ("Size", w.ULONG), ("ModBase", ctypes.c_uint64), ("Flags", w.ULONG),
                ("Value", ctypes.c_uint64), ("Address", ctypes.c_uint64), ("Register", w.ULONG),
                ("Scope", w.ULONG), ("Tag", w.ULONG), ("NameLen", w.ULONG), ("MaxNameLen", w.ULONG),
                ("Name", ctypes.c_char * 1024)]


dbg.SymSetOptions.argtypes = [w.DWORD]
dbg.SymInitialize.argtypes = [w.HANDLE, ctypes.c_char_p, w.BOOL]
dbg.SymFromAddr.argtypes = [w.HANDLE, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.c_void_p]
dbg.SymGetModuleBase64.argtypes = [w.HANDLE, ctypes.c_uint64]
dbg.SymGetModuleBase64.restype = ctypes.c_uint64
dbg.SymFunctionTableAccess64.argtypes = [w.HANDLE, ctypes.c_uint64]
dbg.SymFunctionTableAccess64.restype = ctypes.c_void_p
dbg.StackWalk64.argtypes = [w.DWORD, w.HANDLE, w.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
dbg.StackWalk64.restype = w.BOOL
FTA = ctypes.cast(dbg.SymFunctionTableAccess64, ctypes.c_void_p)
GMB = ctypes.cast(dbg.SymGetModuleBase64, ctypes.c_void_p)


def ft(f):
    return (f.dwHighDateTime << 32 | f.dwLowDateTime)


def thread_ids(pid):
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
    e = THREADENTRY32()
    e.dwSize = ctypes.sizeof(e)
    out = []
    ok = k32.Thread32First(snap, ctypes.byref(e))
    while ok:
        if e.th32OwnerProcessID == pid:
            out.append(e.th32ThreadID)
        ok = k32.Thread32Next(snap, ctypes.byref(e))
    k32.CloseHandle(snap)
    return out


def cpu_time(h):
    c, x, kern, user = (w.FILETIME() for _ in range(4))
    if not k32.GetThreadTimes(h, ctypes.byref(c), ctypes.byref(x), ctypes.byref(kern), ctypes.byref(user)):
        return 0
    return ft(kern) + ft(user)  # 100 ns units


def thread_name(h):
    p = w.LPWSTR()
    if k32.GetThreadDescription(h, ctypes.byref(p)) >= 0 and p.value:
        s = p.value
        k32.LocalFree(p)
        return s
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pid", type=int)
    ap.add_argument("--seconds", type=float, default=30)
    ap.add_argument("--hz", type=int, default=200)
    ap.add_argument("--top", type=int, default=3)
    ap.add_argument("--names", default="", help="comma list: sample threads whose name contains one of these (instead of the busiest)")
    ap.add_argument("--out", default="")
    ap.add_argument("--pdb-dir", default="", help="extra folder holding the exe's .pdb")
    ap.add_argument("--cpu-only", action="store_true", help="drop samples whose top frame is a wait")
    ap.add_argument("--focus", default="", help="comma list: print the caller chains above frames containing these")
    ap.add_argument("--merge", action="store_true", help="also print one profile over all sampled threads together")
    a = ap.parse_args()

    hp = k32.OpenProcess(PROCESS_RIGHTS, False, a.pid)
    if not hp:
        sys.exit("OpenProcess failed %d" % ctypes.get_last_error())
    dbg.SymSetOptions(0x2 | 0x10 | 0x80000 | 0x200)  # undecorate, load lines, no prompts, fail critical (NOT deferred: load the PDB now)
    buf = ctypes.create_unicode_buffer(1024)
    size = w.DWORD(1024)
    k32.QueryFullProcessImageNameW(hp, 0, buf, ctypes.byref(size))
    exe_path = buf.value
    sympath = (os.path.dirname(exe_path) + ";" + (a.pdb_dir or "")).encode()
    print("target exe:", exe_path, " symbol search path:", sympath.decode())
    if not dbg.SymInitialize(hp, sympath, True):
        sys.exit("SymInitialize failed %d" % ctypes.get_last_error())

    # 1. who is busy
    tids = thread_ids(a.pid)
    handles = {}
    for t in tids:
        h = k32.OpenThread(THREAD_RIGHTS, False, t)
        if h:
            handles[t] = h
    t0 = {t: cpu_time(h) for t, h in handles.items()}
    time.sleep(2.0)
    busy = sorted(((cpu_time(h) - t0[t], t) for t, h in handles.items()), reverse=True)
    names = {t: thread_name(h) for t, h in handles.items()}
    print("threads by CPU over 2 s (ms):")
    for d, t in busy[:12]:
        print("  tid %6d %-28s %7.0f ms" % (t, names[t] or "-", d / 1e4))
    if a.names:
        want = [n.strip() for n in a.names.split(",") if n.strip()]
        picked = [t for _, t in busy if any(n in names[t] for n in want)]
    else:
        picked = [t for d, t in busy[: a.top] if d > 0]
    if not picked:
        sys.exit("no thread to sample")
    print("sampling:", ", ".join("%d(%s)" % (t, names[t] or "-") for t in picked))

    # CONTEXT64 is 1232 bytes and 16-byte aligned.
    raw = ctypes.create_string_buffer(1232 + 32)
    base = (ctypes.addressof(raw) + 15) & ~15
    ctx_flags = ctypes.c_uint32.from_address(base + 0x30)
    rsp_ = ctypes.c_uint64.from_address(base + 0x98)
    rbp_ = ctypes.c_uint64.from_address(base + 0xA0)
    rip_ = ctypes.c_uint64.from_address(base + 0xF8)

    samples = {t: [] for t in picked}
    cpu0 = {t: cpu_time(handles[t]) for t in picked}
    period = 1.0 / a.hz
    end = time.time() + a.seconds
    n = 0
    while time.time() < end:
        tick = time.time()
        for t in picked:
            h = handles[t]
            if k32.SuspendThread(h) == 0xFFFFFFFF:
                continue
            try:
                ctypes.memset(base, 0, 1232)
                ctx_flags.value = CONTEXT_CONTROL | CONTEXT_INTEGER
                if not k32.GetThreadContext(h, ctypes.c_void_p(base)):
                    continue
                sf = STACKFRAME64()
                sf.AddrPC.Offset, sf.AddrPC.Mode = rip_.value, 3
                sf.AddrFrame.Offset, sf.AddrFrame.Mode = rbp_.value, 3
                sf.AddrStack.Offset, sf.AddrStack.Mode = rsp_.value, 3
                frames = [rip_.value]
                for _ in range(40):
                    if not dbg.StackWalk64(0x8664, hp, h, ctypes.byref(sf), ctypes.c_void_p(base),
                                           None, FTA, GMB, None):
                        break
                    pc = sf.AddrPC.Offset
                    if pc == 0:
                        break
                    if len(frames) == 1 and pc == frames[0]:
                        continue
                    frames.append(pc)
                samples[t].append(frames)
            finally:
                k32.ResumeThread(h)
        n += 1
        left = period - (time.time() - tick)
        if left > 0:
            time.sleep(left)
    cpu1 = {t: cpu_time(handles[t]) for t in picked}

    cache = {}

    def sym(addr):
        if addr in cache:
            return cache[addr]
        s = SYMBOL_INFO()
        s.SizeOfStruct = 88
        s.MaxNameLen = 1024
        disp = ctypes.c_uint64()
        if dbg.SymFromAddr(hp, addr, ctypes.byref(disp), ctypes.byref(s)):
            nm = s.Name.decode(errors="replace")
        else:
            nm = "?0x%x" % (addr >> 20)  # unresolved: bucket by 1 MB region
        cache[addr] = nm
        return nm

    def short(nm):
        return nm if len(nm) < 110 else nm[:107] + "..."

    lines = []
    out = lines.append
    out("seconds %.0f  rounds %d  hz %d" % (a.seconds, n, a.hz))
    WAITS = ("ZwWaitForAlertByThreadId", "NtWaitForSingleObject", "ZwWaitForSingleObject", "ZwDelayExecution",
             "NtWaitForMultipleObjects", "ZwWaitForMultipleObjects", "ZwRemoveIoCompletion", "NtRemoveIoCompletion",
             "NtGdiDdDDIWaitForSynchronizationObjectFromCpu", "ZwWaitForWorkViaWorkerFactory", "NtDelayExecution")
    focus = [f.strip() for f in a.focus.split(",") if f.strip()]
    if a.merge:
        merged = []
        for t in picked:
            merged.extend(samples[t])
        samples[0] = merged
        names[0] = "ALL SAMPLED THREADS TOGETHER"
        cpu0[0] = sum(cpu0[t] for t in picked)
        cpu1[0] = sum(cpu1[t] for t in picked)
        picked = [0] + list(picked)
    for t in picked:
        ss = samples[t]
        if not ss:
            continue
        if a.cpu_only:
            ss = [fr for fr in ss if sym(fr[0]) not in WAITS]
            if not ss:
                continue
        cpu_ms = (cpu1[t] - cpu0[t]) / 1e4
        out("")
        out("=== thread %d %s: %d samples%s, %.0f ms CPU in %.0f s = %.0f%% of one core" %
            (t, names[t] or "-", len(ss), " (busy only)" if a.cpu_only else "", cpu_ms, a.seconds, 100 * cpu_ms / (a.seconds * 1000)))
        if focus:
            chains = collections.Counter()
            hits = 0
            for fr in ss:
                syms = [sym(p) for p in fr]
                for i, s in enumerate(syms):
                    if any(f in s for f in focus):
                        hits += 1
                        chains[" < ".join(short(x)[:70] for x in syms[i:i + 6])] += 1
                        break
            out("-- callers above %s: in %.1f%% of samples" % (",".join(focus), 100 * hits / len(ss)))
            for ch, c in chains.most_common(12):
                out("  %5.1f%%  %s" % (100 * c / len(ss), ch))
        selfc, incl = collections.Counter(), collections.Counter()
        # "ours": first frame that has a source symbol in victory modules (skip system frames)
        for fr in ss:
            syms = [sym(p) for p in fr]
            selfc[syms[0]] += 1
            seen = set()
            for s in syms:
                if s not in seen:
                    incl[s] += 1
                    seen.add(s)
        out("-- hottest by SELF time (top frame)")
        for nm, c in selfc.most_common(18):
            out("  %5.1f%%  %s" % (100 * c / len(ss), short(nm)))
        out("-- hottest by INCLUSIVE time (anywhere in the stack)")
        for nm, c in incl.most_common(32):
            out("  %5.1f%%  %s" % (100 * c / len(ss), short(nm)))
    text = "\n".join(lines)
    print(text)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")


main()
