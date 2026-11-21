#!/usr/bin/env python3
"""End-to-end checks for tool/sessions-hook. Uses only the Python standard library and local listeners.

    python3 -I tests/run_tests.py            (OMNIACRYPT=/path/to/omniacrypt to use another opener)

Covers: sealing against mac/omniacrypt both ways, pairing against an independent X25519 + HKDF written here,
the hook events and the requests they cause, the reply and its note, many long replies within the relay's limit,
"not paired means nothing happens", the 3 s network limit, the Keychain store, unpairing, unpairing itself when
the phone disconnected (410), and how long a hook takes.
"""
import base64, hashlib, hmac, json, os, secrets, shutil, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tool", "sessions-hook")
OMNIACRYPT = os.environ.get("OMNIACRYPT") or os.path.join(ROOT, "..", "mac", "omniacrypt")
if not os.path.isfile(OMNIACRYPT):
    # Outside the Sessions source tree there is no mac/omniacrypt: open with sessions-hook itself
    # (same interface). The sealing checks then test the tool against itself only.
    print("note: %s not found, using tool/sessions-hook as the opener" % os.path.normpath(OMNIACRYPT))
    OMNIACRYPT = TOOL
sys.path.insert(0, HERE)
from fake_relay import Relay, Silent  # noqa: E402

FAILED = []


def check(ok, what, detail=""):
    print(("PASS " if ok else "FAIL ") + what + (("  [" + detail + "]") if detail and not ok else ""))
    if not ok:
        FAILED.append(what)


# ------------------------------------------------------------ independent X25519 (RFC 7748) and HKDF (RFC 5869)

P = 2 ** 255 - 19


def x25519(k, u):
    k = bytearray(k)
    k[0] &= 248; k[31] &= 127; k[31] |= 64
    k = int.from_bytes(k, "little")
    u = bytearray(u); u[31] &= 127
    x1 = int.from_bytes(u, "little") % P
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        kt = (k >> t) & 1
        swap ^= kt
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = kt
        a, b, c, d = x2 + z2, x2 - z2, x3 + z3, x3 - z3
        aa, bb, da, cb = a * a, b * b, d * a, c * b
        e = aa - bb
        x3, z3 = (da + cb) ** 2 % P, x1 * (da - cb) ** 2 % P
        x2, z2 = aa * bb % P, e * (aa + 121665 * e) % P
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


BASE = (9).to_bytes(32, "little")


def hkdf(ikm, salt, info, n=32):
    prk = hmac.new(salt or b"\0" * 32, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out, i = out + t, i + 1
    return out[:n]


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


# ------------------------------------------------------------ helpers

def tool(args, env, stdin=b"", timeout=30):
    t0 = time.perf_counter()
    p = subprocess.run([TOOL] + args, input=stdin, capture_output=True, env=env, timeout=timeout)
    return p, (time.perf_counter() - t0) * 1000


def tool_spawn_ms(path):
    t0 = time.perf_counter()
    subprocess.run([path], capture_output=True)
    return (time.perf_counter() - t0) * 1000


def omnia(mode, k, data):
    p = subprocess.run([OMNIACRYPT, mode], input=data, capture_output=True, env=dict(os.environ, OMNIA_KEY=k))
    return p.returncode, p.stdout


def base_env(home, relay_url, send="inline", store="file"):
    env = {k: v for k, v in os.environ.items() if not k.startswith("SESSIONS_")}
    env.update(SESSIONS_HOME=home, SESSIONS_RELAY=relay_url, SESSIONS_SEND=send, SESSIONS_KEY_STORE=store)
    return env


def ev(name, sid, **fields):
    d = {"session_id": sid, "transcript_path": "/Users/x/.claude/projects/p/%s.jsonl" % sid,
         "cwd": "/Users/x/projects/omnia-site", "hook_event_name": name}
    d.update(fields)
    return json.dumps(d).encode()


def phone_pair(relay, env, code, extra=()):
    """Plays the phone: start, let the plugin join, read the computer's key, derive K independently."""
    priv = secrets.token_bytes(32)
    pub = x25519(priv, BASE)
    import urllib.request
    req = urllib.request.Request(relay.url + "/v1/pair/start", method="POST",
                                 data=json.dumps({"code": code, "pub": base64.b64encode(pub).decode()}).encode())
    urllib.request.urlopen(req).read()
    p, _ = tool(["pair", code] + list(extra), env)
    got = json.loads(urllib.request.urlopen(relay.url + "/v1/pair/" + code).read() or b"{}")
    k_phone = None
    if "pub" in got:
        shared = x25519(priv, base64.b64decode(got["pub"]))
        k_phone = b64url(hkdf(shared, code.encode(), b"omnia-pair-v1"))
    return p, got, k_phone


def phone_delete(relay, k):
    """Plays the phone's "Disconnect": DELETE /v1/box with the box headers of K."""
    import urllib.request
    headers = {"x-box": hashlib.sha256(("box|" + k).encode()).hexdigest(),
               "x-auth": hashlib.sha256(("auth|" + k).encode()).hexdigest()}
    return urllib.request.urlopen(urllib.request.Request(relay.url + "/v1/box", method="DELETE", headers=headers)).status


def opened_states(reqs, k):
    out = []
    for r in reqs:
        if r["method"] == "PUT" and r["path"] == "/v1/state":
            code, plain = omnia("open", k, r["body"].encode())
            out.append(json.loads(plain) if code == 0 else None)
    return out


def notifies(reqs):
    return [json.loads(r["body"]) for r in reqs if r["path"] == "/v1/push/notify"]


def main():
    tmp = tempfile.mkdtemp(prefix="sessions-plugin-test-")
    relay = Relay()
    print("tool:", TOOL)
    print("opener:", os.path.normpath(OMNIACRYPT))
    print("fake relay:", relay.url)

    # -------------------------------------------------- 1. sealing interop with mac/omniacrypt
    print("\n== sealing against mac/omniacrypt ==")
    k = b64url(secrets.token_bytes(32))
    plain = json.dumps({"snapshot": {"updated": 1, "mac": "Test Mac é", "counts": {"need": 1, "working": 0, "finished": 0},
                                     "sessions": []}, "jobs": [], "promptsOn": False}).encode()
    p, _ = tool(["seal"], dict(os.environ, OMNIA_KEY=k), plain)
    code, back = omnia("open", k, p.stdout)
    check(p.returncode == 0 and code == 0 and back == plain, "sessions-hook seal -> omniacrypt open gives the plaintext")
    code, sealed = omnia("seal", k, plain)
    p, _ = tool(["open"], dict(os.environ, OMNIA_KEY=k), sealed)
    check(code == 0 and p.returncode == 0 and p.stdout == plain, "omniacrypt seal -> sessions-hook open gives the plaintext")
    raw = bytearray(base64.b64decode(sealed)); raw[20] ^= 1
    p, _ = tool(["open"], dict(os.environ, OMNIA_KEY=k), base64.b64encode(bytes(raw)))
    check(p.returncode != 0 and not p.stdout, "a tampered box does not open")
    check(len(base64.b64decode(sealed)) == 12 + len(plain) + 16, "layout is 12-byte nonce + ciphertext + 16-byte tag")

    # -------------------------------------------------- 2. independent X25519 check (RFC 7748 section 6.1)
    print("\n== independent X25519 (RFC 7748 vectors) ==")
    a = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    b = bytes.fromhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    check(x25519(a, BASE).hex() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", "RFC 7748 Alice public key")
    check(x25519(b, BASE).hex() == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", "RFC 7748 Bob public key")
    check(x25519(a, x25519(b, BASE)).hex() == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", "RFC 7748 shared secret")

    # -------------------------------------------------- 3. pairing end to end (file store)
    print("\n== pairing through the fake relay ==")
    home = os.path.join(tmp, "home")
    env = base_env(home, relay.url)
    p, got, k_phone = phone_pair(relay, env, "482913", ["--session=sess-pair"])
    out = p.stdout.decode().strip()
    print("  pair printed:", out)
    check(out == "Connected to your iPhone.", "pair prints the confirmation")
    k_plugin = open(os.path.join(home, "pair-key")).read().strip()
    check(k_phone is not None and k_phone == k_plugin, "phone (independent Python X25519+HKDF) and plugin hold the same K",
          "%s vs %s" % (k_phone, k_plugin))
    check(oct(os.stat(os.path.join(home, "pair-key")).st_mode & 0o777) == "0o600", "pair key file is 0600")
    check(oct(os.stat(home).st_mode & 0o777) == "0o700", "state folder is 0700")
    check(bool(got.get("name")), "the phone learns the computer name", str(got))
    reqs = relay.take()
    join = [json.loads(r["body"]) for r in reqs if r["path"] == "/v1/pair/join"]
    check(len(join) == 1 and set(join[0]) == {"code", "pub", "name"} and len(base64.b64decode(join[0]["pub"])) == 32,
          "join sends code, 32-byte public key and name")
    states = opened_states(reqs, k_plugin)
    check(len(states) == 1 and states[0] and states[0]["snapshot"]["sessions"][0]["id"] == "sess-pair",
          "the first sealed PUT creates the box and shows the session the command ran in")
    put = [r for r in reqs if r["method"] == "PUT"][0]
    check(put["headers"]["x-box"] == hashlib.sha256(("box|" + k_plugin).encode()).hexdigest()
          and put["headers"]["x-auth"] == hashlib.sha256(("auth|" + k_plugin).encode()).hexdigest(),
          "x-box and x-auth are the hashes of K")
    relay.pairs.clear()
    p, _ = tool(["pair", "999999"], base_env(os.path.join(tmp, "nohome"), relay.url))
    check("not found or has expired" in p.stdout.decode() and p.returncode == 0, "unknown code gives a plain message")
    p, _ = tool(["pair", "12ab56"], base_env(os.path.join(tmp, "nohome"), relay.url))
    check("six-digit code" in p.stdout.decode(), "a malformed code asks for the six digits")
    relay.take()

    # -------------------------------------------------- 4. hook events (sends inline so the requests can be read)
    print("\n== hook events ==")
    hook_out, all_notifies = [], []

    def step(payload):
        p, ms = tool(["hook"], env, payload)
        hook_out.append((p.returncode, p.stdout, p.stderr))
        store = json.load(open(os.path.join(home, "sessions.json")))
        reqs = relay.take()
        all_notifies.extend(notifies(reqs))
        return store, opened_states(reqs, k_plugin), notifies(reqs), reqs

    s, st, nt, _ = step(ev("SessionEnd", "sess-pair", reason="other"))
    check("sess-pair" not in s["sessions"], "SessionEnd removes the session the pair command ran in")
    s, st, nt, _ = step(ev("SessionStart", "S1", source="startup", model="claude-opus-5"))
    r = s["sessions"]["S1"]
    check(r["state"] == "done" and r["title"] == "omnia-site" and r["visible"] is False and not nt,
          "SessionStart: stored with the folder as title, hidden until a prompt, no push", json.dumps(r))

    s, st, nt, _ = step(ev("UserPromptSubmit", "S1", permission_mode="default",
                           prompt="Fix the login page so the button works on small phones and tablets too please\nand more"))
    r = s["sessions"]["S1"]
    snap = st[-1]["snapshot"] if st else {}
    check(r["state"] == "work" and r["turns"] == 1 and r["title"].startswith("Fix the login page"), "UserPromptSubmit: working, turn 1, title from the prompt")
    check(snap.get("counts") == {"need": 0, "working": 1, "finished": 0} and st[-1]["jobs"] == [] and st[-1]["promptsOn"] is False,
          "sealed state: counts, jobs [], promptsOn false", json.dumps(st[-1] if st else None))
    check(len(nt) == 1 and nt[0]["event"] == "start" and nt[0]["alert"] is None and nt[0]["contentState"]["working"] == 1,
          "notify start when a session starts working, no alert", json.dumps(nt))
    item = nt[0]["contentState"]["items"][0] if nt else {}
    check(len(item.get("title", "")) <= 40 and item.get("note") == "", "card title at most 40 characters, empty note", json.dumps(item))
    print("  card:", json.dumps(nt[0]["contentState"]) if nt else None)

    s, st, nt, _ = step(ev("Notification", "S1", message="Claude needs your permission to use Bash", title="Permission needed",
                           notification_type="permission_prompt"))
    check(s["sessions"]["S1"]["state"] == "need" and st and st[-1]["snapshot"]["sessions"][0]["needs"] == "Claude needs your permission to use Bash",
          "Notification permission_prompt: needs you, with the message in the sealed state")
    check(len(nt) == 1 and nt[0]["event"] == "update" and nt[0]["alert"] == {"title": "Sessions", "body": "A session needs you"},
          "notify update with the neutral alert 'A session needs you'", json.dumps(nt))

    s, st, nt, _ = step(ev("PostToolUse", "S1", tool_name="Bash", tool_input={"command": "ls"}, tool_response={}))
    check(s["sessions"]["S1"]["state"] == "work" and len(nt) == 1 and nt[0]["event"] == "update" and nt[0]["alert"] is None,
          "PostToolUse after the approval: working again, update without alert", json.dumps(nt))
    s, st, nt, reqs = step(ev("PostToolUse", "S1", tool_name="Read", tool_input={}, tool_response={}))
    check(not reqs, "a further PostToolUse within a minute changes nothing and sends nothing")

    def age(last_ago, notify_ago):
        """Pretend time passed: the session's last activity and the last notify were this many seconds ago."""
        now = int(time.time())
        sp, tp = os.path.join(home, "sessions.json"), os.path.join(home, "sent.json")
        s = json.load(open(sp)); s["sessions"]["S1"]["last"] = now - last_ago; json.dump(s, open(sp, "w"))
        t = json.load(open(tp)); t["notifyAt"] = now - notify_ago; t["putAt"] = now - last_ago; json.dump(t, open(tp, "w"))

    age(61, 100)
    s, st, nt, reqs = step(ev("PostToolUse", "S1", tool_name="Read", tool_input={}, tool_response={}))
    check(len(st) == 1 and not nt, "heartbeat: a minute later PostToolUse refreshes the sealed state, no push (last notify 100 s ago)")
    age(61, 301)
    s, st, nt, reqs = step(ev("PostToolUse", "S1", tool_name="Read", tool_input={}, tool_response={}))
    check(len(st) == 1 and len(nt) == 1 and nt[0]["event"] == "update" and nt[0]["alert"] is None,
          "heartbeat: with the last notify 5 minutes ago, a working session sends an 'update' to keep the card fresh", json.dumps(nt))

    reply = "I fixed the login button.\n\nThe layout now wraps on narrow screens.\n" + "It also keeps the logo in view. " * 70
    s, st, nt, _ = step(ev("Stop", "S1", stop_hook_active=False, last_assistant_message=reply, background_tasks=[], session_crons=[]))
    sess = st[-1]["snapshot"]["sessions"][0] if st else {}
    check(s["sessions"]["S1"]["state"] == "done" and len(sess.get("note", "")) == 300 and sess["note"].startswith("I fixed the login button. The layout")
          and "\n" not in sess["note"], "Stop: finished, note is the last reply as one line cut to 300 characters", str(len(sess.get("note", ""))))
    want = reply.strip()[:1999].rstrip() + "\u2026"
    check(sess.get("reply") == want and len(sess["reply"]) == 2000 and sess["reply"].startswith("I fixed the login button.\n\nThe layout"),
          "Stop: reply is the last reply in full, line breaks kept, cut to 2,000 characters (sealed state only)",
          "%d chars" % len(sess.get("reply") or ""))
    check(len(nt) == 1 and nt[0]["event"] == "end" and nt[0]["alert"] is None, "notify end when nothing works or waits", json.dumps(nt))
    check(all("fixed" not in json.dumps(n) and "logo in view" not in json.dumps(n) for n in nt), "no reply text in the push request")

    s, st, nt, _ = step(ev("Notification", "S1", message="Claude is waiting for your input", notification_type="idle_prompt"))
    check(len(nt) == 1 and nt[0]["event"] == "end" and nt[0]["alert"] == {"title": "Sessions", "body": "A session finished"},
          "Notification idle_prompt a minute later: alert 'A session finished'", json.dumps(nt))
    s, st, nt, reqs = step(ev("Notification", "S1", message="Claude is waiting for your input", notification_type="idle_prompt"))
    check(not reqs, "a second idle_prompt sends nothing")

    s, st, nt, _ = step(ev("UserPromptSubmit", "S2", prompt="/sessions:status", cwd="/Users/x/code/relay"))
    check(s["sessions"]["S2"]["title"] == "relay" and nt and nt[-1]["event"] == "start", "a slash command keeps the folder title; second session starts the card")
    s, st, nt, _ = step(ev("StopFailure", "S2", error="rate_limit", error_details="429", last_assistant_message="API Error: Rate limit reached"))
    check(s["sessions"]["S2"]["state"] == "need" and nt and nt[-1]["alert"]["body"] == "A session needs you"
          and "API Error" not in json.dumps(st[-1]), "StopFailure: needs you, alert, error text not used as the reply")
    snap = st[-1]["snapshot"]
    check([x["state"] for x in snap["sessions"]] == ["need", "done"] and snap["counts"] == {"need": 1, "working": 0, "finished": 1},
          "sessions ordered need, work, done with matching counts", json.dumps(snap["counts"]))
    print("  sealed state:", json.dumps(st[-1])[:400], "...")

    s, st, nt, _ = step(ev("SessionEnd", "S2", reason="prompt_input_exit"))
    check("S2" not in s["sessions"] and nt and nt[-1]["event"] == "end", "SessionEnd: removed, card ends")
    s, st, nt, _ = step(ev("SessionEnd", "S1", reason="other"))
    check(s["sessions"] == {} and st and st[-1]["snapshot"]["sessions"] == [], "after both end, the phone gets an empty list")
    check(all(c == 0 and out == b"" and err == b"" for c, out, err in hook_out), "every hook exited 0 and printed nothing")
    check(all_notifies and not any(w in json.dumps(n) for n in all_notifies for w in ("fixed", "logo in view", "wraps", "reply")),
          "no notify in this whole run carried reply text (%d notifies)" % len(all_notifies))

    # -------------------------------------------------- 4b. many long replies stay inside the relay's 256 KB
    print("\n== many long replies ==")
    bhome = os.path.join(tmp, "bhome")
    benv = base_env(bhome, relay.url)
    p, got, k_b = phone_pair(relay, benv, "551177")
    relay.take()
    quiet = dict(benv, SESSIONS_SEND="off")
    long_reply = "長い返事です。" * 400          # 2,800 characters, 3 bytes each
    for i in range(32):
        tool(["hook"], quiet, ev("UserPromptSubmit", "B%02d" % i, prompt="Task %d" % i))
        tool(["hook"], quiet, ev("Stop", "B%02d" % i, last_assistant_message=long_reply))
    p, _ = tool(["send"], benv)
    reqs = relay.take()
    put = [r for r in reqs if r["method"] == "PUT" and r["path"] == "/v1/state"]
    st = opened_states(reqs, k_b)
    shown = st[-1]["snapshot"]["sessions"] if st and st[-1] else []
    replies = [x["reply"] for x in shown if x.get("reply")]
    used = sum(len(x.encode()) for x in replies)
    print("  30 sessions shown, %d with the full reply (%d bytes of replies), sealed state %d bytes"
          % (len(replies), used, len(put[-1]["body"]) if put else 0))
    check(p.returncode == 0 and put and len(put[-1]["body"]) < 256 * 1024 and len(shown) == 30
          and all(len(x["note"]) == 300 for x in shown) and 0 < len(replies) < 30 and used <= 120000
          and all(len(x) == 2000 for x in replies),
          "30 sessions with 2,000-character replies: replies kept within 120 KB, every note kept, the sealed state under 256 KB")

    # -------------------------------------------------- 5. not paired: nothing happens
    print("\n== not paired ==")
    lone = os.path.join(tmp, "lone")
    p, ms = tool(["hook"], base_env(lone, relay.url), ev("UserPromptSubmit", "S9", prompt="hello"))
    check(p.returncode == 0 and p.stdout == b"" and not os.path.exists(lone) and not relay.take(),
          "with nothing paired a hook writes no file and sends nothing (%.1f ms)" % ms)

    # -------------------------------------------------- 6. timing (default detached sending)
    print("\n== timing ==")
    denv = base_env(home, relay.url, send="detached")
    times = []
    for i in range(30):
        name = "UserPromptSubmit" if i % 2 == 0 else "Stop"
        p, ms = tool(["hook"], denv, ev(name, "S3", prompt="Timing run %d" % i, last_assistant_message="ok %d" % i))
        times.append(ms)
    deadline, seen, quiet_since = time.time() + 20, -1, time.time()
    while time.time() < deadline and time.time() - quiet_since < 1.5:
        time.sleep(0.1)
        if len(relay.requests) != seen:
            seen, quiet_since = len(relay.requests), time.time()
    reqs = relay.take()
    med, p90 = statistics.median(times), sorted(times)[int(len(times) * 0.9)]
    base = statistics.median([tool_spawn_ms("/usr/bin/true") for _ in range(30)])
    print("  paired hook, wall time over 30 runs: median %.1f ms, p90 %.1f ms, max %.1f ms" % (med, p90, max(times)))
    print("  for scale, starting /usr/bin/true the same way: median %.1f ms" % base)
    check(med < 100, "hook returns in under 100 ms (median)")
    final = opened_states(reqs, k_plugin)
    check(any(r["path"] == "/v1/state" for r in reqs) and final and final[-1]["snapshot"]["sessions"][0]["state"] == "done",
          "detached senders delivered the final state (%d requests for 30 hooks)" % len(reqs))
    tool(["hook"], base_env(home, relay.url), ev("SessionEnd", "S3", reason="other"))
    relay.take()
    lone_times = [tool(["hook"], base_env(lone, relay.url), ev("Stop", "S9"))[1] for _ in range(10)]
    print("  unpaired hook: median %.1f ms" % statistics.median(lone_times))

    # -------------------------------------------------- 7. a relay that never answers
    print("\n== 3 second limit ==")
    silent = Silent()
    senv = base_env(home, silent.url, send="detached")
    p, ms = tool(["hook"], senv, ev("UserPromptSubmit", "S4", prompt="Slow relay"))
    check(ms < 100, "detached: the hook returns at once even when the relay hangs (%.1f ms)" % ms)
    time.sleep(4)   # let that detached sender give up first; it holds the send lock meanwhile
    t0 = time.perf_counter()
    p, ms = tool(["hook"], base_env(home, silent.url, send="inline"), ev("Stop", "S4", last_assistant_message="done"))
    print("  inline send against a silent relay took %.2f s" % (ms / 1000))
    log = open(os.path.join(home, "log.txt")).read()
    check(2.5 < ms / 1000 < 5 and "no answer in 3 s" in log, "the send gives up after 3 s and the failure is logged")
    print("  log tail:", log.strip().splitlines()[-1])
    tool(["hook"], base_env(home, relay.url), ev("SessionEnd", "S4", reason="other"))
    relay.take()

    # -------------------------------------------------- 8. unpair (file store)
    print("\n== unpair ==")
    p, _ = tool(["unpair"], base_env(home, relay.url))
    reqs = relay.take()
    check(p.stdout.decode().startswith("Disconnected.") and any(r["method"] == "DELETE" and r["path"] == "/v1/box" for r in reqs)
          and not os.path.exists(os.path.join(home, "pair-key")) and not os.path.exists(os.path.join(home, "paired.json")),
          "unpair deletes the box at the relay and the local key and state")
    p, _ = tool(["hook"], base_env(home, relay.url), ev("UserPromptSubmit", "S5", prompt="after"))
    check(not relay.take(), "after unpair, hooks send nothing")

    # -------------------------------------------------- 8b. the phone disconnected: the relay answers 410
    print("\n== the phone disconnected (410) ==")
    ghome = os.path.join(tmp, "ghome")
    genv = base_env(ghome, relay.url)
    p, got, k_g = phone_pair(relay, genv, "640031")
    relay.take()
    phone_delete(relay, k_g)
    relay.take()
    p, _ = tool(["hook"], genv, ev("UserPromptSubmit", "G1", prompt="After the phone disconnected"))
    reqs = relay.take()
    log = open(os.path.join(ghome, "log.txt")).read().strip().splitlines()
    print("  log:", log[-1] if log else None)
    check(p.returncode == 0 and p.stdout == b"" and p.stderr == b"", "the hook still exits 0 and prints nothing")
    check([(r["method"], r["path"]) for r in reqs] == [("PUT", "/v1/state")], "the sender stops at the 410: no notify after it",
          str([(r["method"], r["path"]) for r in reqs]))
    check(not any(os.path.exists(os.path.join(ghome, f)) for f in ("pair-key", "paired.json", "sessions.json", "sent.json")),
          "on 410 the plugin unpairs itself: pair key, pairing and session store removed", str(os.listdir(ghome)))
    check(len([l for l in log if "410" in l]) == 1 and len(log) == 1, "and logs one line", str(log))
    check(hashlib.sha256(("box|" + k_g).encode()).hexdigest() not in relay.boxes, "the relay's box was not recreated")
    p, _ = tool(["hook"], genv, ev("Stop", "G1", last_assistant_message="done"))
    check(not relay.take() and len(open(os.path.join(ghome, "log.txt")).read().strip().splitlines()) == 1,
          "later hooks send nothing and log nothing")
    p, _ = tool(["status"], genv)
    check(p.stdout.decode().startswith("Not connected to a phone."), "status says it is not connected")
    p, got, k_g2 = phone_pair(relay, genv, "640032")
    phone_delete(relay, k_g2)
    relay.take()
    p, _ = tool(["unpair"], genv)
    check(p.stdout.decode().strip() == "Disconnected. This computer no longer sends sessions to your phone."
          and not os.path.exists(os.path.join(ghome, "pair-key")),
          "unpair after the phone disconnected: a plain 'Disconnected.', no relay warning", p.stdout.decode().strip())
    relay.take()

    # -------------------------------------------------- 9. Keychain store (a throwaway service name, removed again)
    print("\n== Keychain ==")
    service = "sessions-plugin-selftest-" + secrets.token_hex(4)
    khome = os.path.join(tmp, "khome")
    kenv = base_env(khome, relay.url, store="keychain")
    kenv["SESSIONS_KEYCHAIN_SERVICE"] = service
    p, got, k_phone = phone_pair(relay, kenv, "730264")
    found = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service, "-a", "pair-key", "-w"], capture_output=True)
    check(p.stdout.decode().strip() == "Connected to your iPhone." and found.stdout.decode().strip() == k_phone
          and not os.path.exists(os.path.join(khome, "pair-key")), "K is stored in the Keychain (not in a file) and matches the phone's")
    relay.take()
    p, _ = tool(["hook"], kenv, ev("UserPromptSubmit", "K1", prompt="Keychain path"))
    check(len(opened_states(relay.take(), k_phone)) == 1, "a hook reads K from the Keychain and sends")
    p, _ = tool(["unpair"], kenv)
    gone = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service, "-a", "pair-key"], capture_output=True)
    check(gone.returncode != 0, "unpair removes the Keychain item")
    relay.take()
    service2 = service + "-b"
    kenv2 = dict(kenv, SESSIONS_KEYCHAIN_SERVICE=service2)
    p, got, k2 = phone_pair(relay, kenv2, "730265")
    had = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service2, "-a", "pair-key", "-w"], capture_output=True)
    phone_delete(relay, k2)
    relay.take()
    tool(["hook"], kenv2, ev("UserPromptSubmit", "K2", prompt="After the phone disconnected"))
    gone = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service2, "-a", "pair-key"], capture_output=True)
    check(had.stdout.decode().strip() == k2 and gone.returncode != 0 and not os.path.exists(os.path.join(khome, "paired.json")),
          "on 410 the pair key is removed from the Keychain too")
    relay.take()
    for svc in (service, service2):      # in case a check above failed half-way
        subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", svc, "-a", "pair-key"], capture_output=True)

    relay.stop()
    shutil.rmtree(tmp, ignore_errors=True)
    print("\n%s" % ("ALL PASSED" if not FAILED else "%d FAILED: %s" % (len(FAILED), "; ".join(FAILED))))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
