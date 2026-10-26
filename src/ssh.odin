package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// --ssh: SSH (the Kestrel design's SSH window, Super+Shift+S). 980×600, three pages (Tab, Alt
// 1–3). Connect: hosts from ~/.ssh/config, known_hosts, the shell's history and Tailscale beside
// the picked one's settings (as ssh -G resolves them) and actions; typing filters or takes
// user@host. ↵ connects step by step (resolving, TCP, key exchange, logging in) and opens a
// terminal; a host seen for the first time shows its fingerprint (y trusts), a changed key
// blocks (R replaces), a key with a passphrase asks for it here. ^O files (SFTP), ^Y copies the
// command, ^F forwards a port, ^M mounts, ^K sends my key, ^E edits the config, ^P pins.
// Host: this machine's sshd (on, at boot, port, password and root login, home network only),
// who is connected (Del ends), the keys allowed in (Del removes, a adds the clipboard's), and
// failed logins (b blocks the address for 24 h). Keys: mine, the agent, the public key (↵
// copies, a agent, n new, q QR). The data comes from k4-ssh: A V H X K F M lines, and
//   R <command>: "VERB ARGS" (last line: the footer; k4:close closes; k4:passphrase KEY asks)
//   L <command>: the data again          C <command>: "HOST" checks it step by step

SSH_W, SSH_H :: 980, 600

Ssh_Host :: struct {
	id, name, user, host, port, key, jump, src, group, last, tag, ms: string,
	fwd: [dynamic][3]string,
	newhost, open: bool,
}
Ssh_Sess :: struct { tty, who, ip, since, what: string }
Ssh_Auth :: struct { line, comment, info: string }
Ssh_Key :: struct { name, kind, comment, fp, used, pub: string, agent, locked: bool }

Ssh_Async :: struct {
	proc_: os.Process,
	out: string,
	running: bool,
	started: time.Tick,
}

Ssh :: struct {
	tab: int,
	hosts: [dynamic]Ssh_Host,
	sess: [dynamic]Ssh_Sess,
	auth: [dynamic]Ssh_Auth,
	keys: [dynamic]Ssh_Key,
	agent: int,
	run, boot, pass, root, inst, lan: bool,
	sport, nsess: int,
	failed: int,
	failed_ip: string,
	runner, loader, checker: string,
	// connect
	cur, top: int, // the picked host, the first one shown
	sel: string,
	band: string, // "" step newhost changed pass forward fail
	band_a, band_b: string, // fingerprint(s), key, message
	step: int,
	check: Ssh_Async,
	input: [dynamic]u8, // passphrase or forward spec
	// host page
	hi: int,
	hask: string, // "pass", "sess:TTY", "auth:LINE"
	// keys page
	ki: int,
	pass_key: string, // asking a key's passphrase on the Keys page
	// data in the background
	reload: Ssh_Async,
	reload_at: time.Tick,
	toast: string,
	toast_hot: bool,
	f9b, f10, f10b, f11, f11b, f12, f12b, f13b, f14, f18b: ^Font,
}

ssh_setup :: proc(a: ^App, data: string) {
	s := new(Ssh)
	a.ssh = s
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	s.f10, s.f11, s.f12, s.f14 = reg(a, 10), reg(a, 11), reg(a, 12), reg(a, 14)
	s.f9b, s.f10b, s.f11b, s.f12b, s.f13b, s.f18b = bld(a, 9), bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 13), bld(a, 18)
	switch a.opts.open { case "host", "2": s.tab = 1; case "keys", "3": s.tab = 2 }
	ssh_parse(s, data)
	s.reload_at = time.tick_now()
}

@(private = "file")
ssh_parse :: proc(s: ^Ssh, data: string) {
	clear(&s.hosts); clear(&s.sess); clear(&s.auth); clear(&s.keys)
	s.failed, s.failed_ip = 0, ""
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		get :: proc(f: []string, i: int) -> string { return i < len(f) ? strings.clone(f[i]) : "" }
		is1 :: proc(f: []string, i: int) -> bool { return i < len(f) && f[i] == "1" }
		switch f[0] {
		case "A": s.agent, _ = strconv.parse_int(get(f, 1))
		case "V":
			s.run, s.boot, s.pass, s.root, s.inst, s.lan = is1(f, 1), is1(f, 4), is1(f, 5), is1(f, 6), is1(f, 7), is1(f, 8)
			s.sport, _ = strconv.parse_int(get(f, 2)); s.nsess, _ = strconv.parse_int(get(f, 3))
		case "X": append(&s.sess, Ssh_Sess{get(f, 1), get(f, 2), get(f, 3), get(f, 4), get(f, 5)})
		case "K": append(&s.auth, Ssh_Auth{get(f, 1), get(f, 2), get(f, 3)})
		case "F": s.failed, _ = strconv.parse_int(get(f, 1)); s.failed_ip = get(f, 2)
		case "M":
			kind := get(f, 2)
			switch {
			case strings.has_prefix(kind, "sk-"): kind = "FIDO2 SK"
			case strings.contains(kind, "ed25519"): kind = "ED25519"
			case strings.contains(kind, "rsa"): kind = "RSA"
			case strings.contains(kind, "ecdsa"): kind = "ECDSA"
			}
			append(&s.keys, Ssh_Key{name = get(f, 1), kind = kind, comment = get(f, 3), fp = get(f, 4), agent = is1(f, 5), locked = is1(f, 6), used = get(f, 7), pub = get(f, 8)})
		case "H":
			h := Ssh_Host{id = get(f, 1), name = get(f, 2), user = get(f, 3), host = get(f, 4), port = get(f, 5), key = get(f, 6), jump = get(f, 7), src = get(f, 8), group = get(f, 9), last = get(f, 10), tag = get(f, 11), newhost = is1(f, 12), ms = get(f, 13), open = is1(f, 15)}
			for fw in strings.split(len(f) > 14 ? f[14] : "", ";", context.temp_allocator) {
				p := strings.split(fw, ":", context.temp_allocator)
				if len(p) >= 2 do append(&h.fwd, [3]string{strings.clone(p[0]), strings.clone(strings.join(p[1:], ":", context.temp_allocator)), ""})
			}
			append(&s.hosts, h)
		case "R": s.runner = get(f, 1)
		case "L": s.loader = get(f, 1)
		case "C": s.checker = get(f, 1)
		}
	}
	// pinned first, then config, nearby, recent (each group as the script gave it)
	order := [4]string{"PINNED", "CONFIG", "NEARBY", "RECENT"}
	sorted := make([dynamic]Ssh_Host, 0, len(s.hosts))
	for g in order do for h in s.hosts do if h.group == g do append(&sorted, h)
	clear(&s.hosts)
	for h in sorted do append(&s.hosts, h)
	delete(sorted)
}

// ---------- the list ----------

@(private = "file")
ssh_query :: proc(a: ^App) -> string { return strings.trim_space(string(a.query[:])) }

@(private = "file")
ssh_typed :: proc(q: string) -> bool { // user@host[:port]
	at := strings.index_byte(q, '@')
	if at <= 0 || at == len(q) - 1 do return false
	for r in q do if !(r == '@' || r == '.' || r == '-' || r == '_' || r == ':' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')) do return false
	return true
}

@(private = "file")
ssh_list :: proc(a: ^App) -> []Ssh_Host {
	s := a.ssh
	q := strings.to_lower(ssh_query(a), context.temp_allocator)
	out := make([dynamic]Ssh_Host, 0, len(s.hosts) + 1, context.temp_allocator)
	if ssh_typed(q) {
		raw := ssh_query(a)
		at := strings.index_byte(raw, '@')
		host, port := raw[at + 1:], "22"
		if i := strings.index_byte(host, ':'); i >= 0 { port = host[i + 1:]; host = host[:i] }
		append(&out, Ssh_Host{id = raw, name = raw, user = raw[:at], host = host, port = port, key = "id_ed25519 (default)", src = "typed", group = "TYPED", last = "never", newhost = true})
		for h in s.hosts do if strings.has_prefix(strings.to_lower(fmt.tprintf("%s@%s", h.user, h.host), context.temp_allocator), q) do append(&out, h)
		return out[:]
	}
	for h in s.hosts {
		if q != "" && !strings.contains(strings.to_lower(fmt.tprintf("%s %s@%s", h.name, h.user, h.host), context.temp_allocator), q) do continue
		append(&out, h)
	}
	return out[:]
}

@(private = "file")
ssh_sel :: proc(a: ^App) -> (Ssh_Host, bool) {
	s := a.ssh
	l := ssh_list(a)
	for h, i in l do if h.id == s.sel { s.cur = i; return h, true }
	if len(l) > 0 { s.cur = clamp(s.cur, 0, len(l) - 1); return l[s.cur], true }
	return {}, false
}

@(private = "file")
ssh_cmd :: proc(h: Ssh_Host) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "ssh ")
	if h.jump != "" do fmt.sbprintf(&sb, "-J %s ", h.jump)
	if h.port != "22" && h.port != "" && h.src != "~/.ssh/config" do fmt.sbprintf(&sb, "-p %s ", h.port)
	if h.src == "~/.ssh/config" || strings.contains(h.name, "@") do strings.write_string(&sb, h.name)
	else do fmt.sbprintf(&sb, "%s@%s", h.user, h.host)
	return strings.to_string(sb)
}

// ---------- running the script ----------

@(private = "file")
ssh_run :: proc(a: ^App, args: ..string) -> string {
	s := a.ssh
	if s.runner == "" { s.toast = fmt.aprintf("(%s)", strings.join(args, " ", context.temp_allocator)); return "" } // tests
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, s.runner)
	for x in args { strings.write_byte(&sb, ' '); strings.write_string(&sb, sh_quote(x)) }
	env: [dynamic]string
	env.allocator = context.temp_allocator
	if len(s.input) > 0 { // a passphrase goes in the environment, not the command line
		envs, _ := os.environ(context.temp_allocator)
		for e in envs do append(&env, e)
		append(&env, strings.concatenate({"K4_INPUT=", string(s.input[:])}, context.temp_allocator))
	}
	_, out, _, _ := os.process_exec({command = {"sh", "-c", strings.to_string(sb)}, env = len(env) > 0 ? env[:] : nil}, context.temp_allocator)
	lines := strings.split_lines(strings.trim_space(string(out)), context.temp_allocator)
	last := len(lines) > 0 ? lines[len(lines) - 1] : ""
	switch {
	case last == "k4:close": a.exit = 0; a.done = true
	case strings.has_prefix(last, "k4:passphrase "): s.pass_key = strings.clone(last[14:]); clear(&s.input); s.toast = ""
	case: s.toast = strings.clone(last); s.toast_hot = strings.has_prefix(last, "Ended") || strings.has_prefix(last, "Removed") || strings.has_prefix(last, "Could not") || strings.has_prefix(last, "Wrong")
	}
	return last
}

@(private = "file")
async_start :: proc(j: ^Ssh_Async, cmd, tag: string) {
	if j.running do return
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	j.out = fmt.aprintf("%s/k4-ssh-%s.out", run != "" ? run : "/tmp", tag)
	p, err := os.process_start({command = {"sh", "-c", fmt.tprintf("%s > %s 2>&1", cmd, sh_quote(j.out))}})
	if err != nil do return
	j.proc_, j.running, j.started = p, true, time.tick_now()
}

@(private = "file")
async_read :: proc(j: ^Ssh_Async) -> (text: string, done: bool) {
	data, err := os.read_entire_file(j.out, context.temp_allocator)
	if err == nil do text = string(data)
	if j.running {
		st, _ := os.process_wait(j.proc_, 0)
		if st.exited { j.running = false; done = true }
	}
	return
}

@(private = "file")
async_stop :: proc(j: ^Ssh_Async) {
	_ = os.process_kill(j.proc_)
	_, _ = os.process_wait(j.proc_, 200 * time.Millisecond)
	j.running = false
}

// Connecting: the check runs in the background; each line moves the steps.
@(private = "file")
ssh_connect :: proc(a: ^App, anyway := false) {
	s := a.ssh
	h, ok := ssh_sel(a)
	if !ok do return
	if !anyway && h.ms == "down" { s.toast = fmt.aprintf("%s isn’t answering on %s:%s · try anyway with ⇧↵", h.name, h.host, h.port); return }
	if s.checker == "" { s.band, s.step = "step", 0; s.toast = fmt.aprintf("(check %s)", h.name); return } // tests
	s.band, s.step, s.band_a, s.band_b = "step", 0, "", ""
	s.toast = ""
	async_start(&s.check, fmt.tprintf("%s %s", s.checker, sh_quote(h.name)), "check")
}

// Every tick: the check's progress and the data refreshed in the background.
ssh_tick :: proc(a: ^App) -> bool {
	s := a.ssh
	changed := false
	if s.check.running {
		text, done := async_read(&s.check)
		lines := strings.split_lines(strings.trim_space(text), context.temp_allocator)
		last := len(lines) > 0 ? lines[len(lines) - 1] : ""
		h, _ := ssh_sel(a)
		switch {
		case strings.has_prefix(last, "step "): n, _ := strconv.parse_int(last[5:]); if n != s.step { s.step = n; changed = true }
		case strings.has_prefix(last, "ok"):
			s.step = 4
			s.band = ""
			ssh_run(a, "connect", h.name)
			changed = true
		case strings.has_prefix(last, "newhost "): s.band, s.band_a = "newhost", strings.clone(last[8:]); changed = true
		case strings.has_prefix(last, "changed "):
			p := strings.fields(last[8:], context.temp_allocator)
			s.band = "changed"
			s.band_a, s.band_b = strings.clone(len(p) > 0 ? p[0] : "?"), strings.clone(len(p) > 1 ? p[1] : "?")
			changed = true
		case strings.has_prefix(last, "locked "): s.band, s.band_a = "pass", strings.clone(last[7:]); clear(&s.input); changed = true
		case strings.has_prefix(last, "fail "): s.band, s.band_a = "fail", strings.clone(last[5:]); changed = true
		case done && s.band == "step": s.band, s.band_a = "fail", "the check stopped"; changed = true
		}
		if s.band != "step" && s.check.running do async_stop(&s.check)
		_ = done
	}
	if s.loader != "" {
		if s.reload.running {
			text, done := async_read(&s.reload)
			if done && strings.contains(text, "\nR\t") {
				keep := s.sel
				ssh_parse(s, text)
				s.sel = keep
				changed = true
			}
		} else if time.tick_diff(s.reload_at, time.tick_now()) > 3 * time.Second {
			s.reload_at = time.tick_now()
			async_start(&s.reload, s.loader, "data")
		}
	}
	return changed
}

// ---------- keys ----------

@(private = "file")
ssh_band_key :: proc(a: ^App, k: Key, ch: rune, text: string) -> bool {
	s := a.ssh
	h, _ := ssh_sel(a)
	cancel :: proc(s: ^Ssh) { s.band = ""; s.toast = "Cancelled"; clear(&s.input); if s.check.running do async_stop(&s.check) }
	switch s.band {
	case "step": if k == .Escape do cancel(s)
	case "newhost":
		switch {
		case text == "y" || k == .Enter: ssh_run(a, "trust", h.name); ssh_connect(a, true)
		case text == "n" || k == .Escape: cancel(s)
		}
	case "changed":
		switch {
		case text == "R": ssh_run(a, "replace", h.name); ssh_connect(a, true)
		case k == .Escape || text == "n": cancel(s)
		}
	case "pass", "forward":
		switch {
		case k == .Escape: cancel(s)
		case k == .Enter:
			if s.band == "pass" {
				r := ssh_run(a, "unlock", h.name, s.band_a)
				clear(&s.input)
				if !strings.has_prefix(r, "Wrong") do ssh_connect(a, true)
			} else {
				spec := strings.clone(string(s.input[:]), context.temp_allocator)
				clear(&s.input)
				s.band = ""
				ssh_run(a, "forward", h.name, spec)
			}
		case k == .Backspace: if len(s.input) > 0 { _, n := utf8.decode_last_rune(s.input[:]); resize(&s.input, len(s.input) - n) }
		case text != "": append(&s.input, ..transmute([]u8)text)
		}
	case "fail":
		switch {
		case text == "r" || k == .Enter: ssh_connect(a, true)
		case k == .Escape: s.band = ""
		}
	}
	return true
}

ssh_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	s := a.ssh
	if ctrl && (ch == 'c' || ch == 'g') { a.exit = 1; a.done = true; return true }
	if (k == .Tab || k == .Back_Tab) && s.band == "" && s.pass_key == "" { s.tab = (s.tab + (k == .Tab ? 1 : 2)) % 3; s.toast, s.hask = "", ""; return true }
	if alt && ch >= '1' && ch <= '3' { s.tab = int(ch - '1'); s.toast = ""; return true }
	switch s.tab {
	case 0:
		if s.band != "" do return ssh_band_key(a, k, ch, text)
		l := ssh_list(a)
		h, ok := ssh_sel(a)
		switch {
		case k == .Down: if len(l) > 0 { s.cur = min(s.cur + 1, len(l) - 1); s.sel = strings.clone(l[s.cur].id); s.toast = "" }
		case k == .Up: if len(l) > 0 { s.cur = max(s.cur - 1, 0); s.sel = strings.clone(l[s.cur].id); s.toast = "" }
		case k == .Enter && ok && h.tag == "GIT":
			if s.runner != "" {
				_, out, errb, _ := os.process_exec({command = {"ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", fmt.tprintf("git@%s", h.host)}}, context.temp_allocator)
				msg := strings.trim_space(string(errb)) != "" ? strings.trim_space(string(errb)) : strings.trim_space(string(out))
				s.toast = fmt.aprintf("%s has no shell · %s", h.host, msg)
			} else do s.toast = "(test login)"
		case k == .Enter: ssh_connect(a, a.shift)
		case ctrl && ok && ch == 'o': ssh_run(a, "sftp", h.name)
		case ctrl && ok && ch == 'y': ssh_run(a, "copy", h.name)
		case ctrl && ok && ch == 'f': s.band = "forward"; clear(&s.input); s.toast = ""
		case ctrl && ok && ch == 'm': ssh_run(a, "mount", h.name)
		case ctrl && ok && ch == 'k': ssh_run(a, "sendkey", h.name)
		case ctrl && ok && ch == 'e': ssh_run(a, "edit", h.name)
		case ctrl && ok && ch == 'p': ssh_run(a, "pin", h.name); s.reload_at = {}
		case k == .Escape:
			if len(a.query) > 0 { clear(&a.query); a.cursor = 0 } else { a.exit = 1; a.done = true }
		case:
			before := strings.clone(string(a.query[:]), context.temp_allocator)
			r := app_edit_key(a, k, ctrl, ch, text)
			if string(a.query[:]) != before { s.cur = 0; s.sel = "" }
			return r
		}
	case 1:
		rows := ssh_host_rows(s)
		if s.hask != "" {
			switch {
			case text == "y" || k == .Enter: ssh_host_act(a, rows, true)
			case text == "n" || k == .Escape: s.hask = ""
			}
			return true
		}
		left := 0
		for r in rows do if r.col == 0 do left += 1
		switch {
		case k == .Down: s.hi = min(s.hi + 1, len(rows) - 1)
		case k == .Up: s.hi = max(s.hi - 1, 0)
		case (k == .Right || k == .Left) && s.hi < len(rows) && rows[s.hi].id == "port":
			ports := [3]int{22, 2222, 22022}
			i := 0
			for p, j in ports do if p == s.sport do i = j
			i = clamp(i + (k == .Right ? 1 : -1), 0, 2)
			ssh_run(a, "port", fmt.tprint(ports[i]))
		case k == .Right: if s.hi < left && left < len(rows) do s.hi = left
		case k == .Left: if s.hi >= left do s.hi = 0
		case k == .Enter || text == " " || k == .Delete: ssh_host_act(a, rows, false)
		case text == "b" && s.failed >= 20 && s.run: ssh_run(a, "block", s.failed_ip)
		case text == "a": ssh_run(a, "authadd"); s.reload_at = {}
		case k == .Escape: a.exit = 1; a.done = true
		case: return false
		}
	case 2:
		if s.pass_key != "" { // a key's passphrase for the agent
			switch {
			case k == .Escape: s.pass_key = ""; clear(&s.input)
			case k == .Enter:
				ssh_run(a, "unlock", "-", strings.concatenate({"~/.ssh/", s.pass_key}, context.temp_allocator))
				s.pass_key = ""; clear(&s.input); s.reload_at = {}
			case k == .Backspace: if len(s.input) > 0 { _, n := utf8.decode_last_rune(s.input[:]); resize(&s.input, len(s.input) - n) }
			case text != "": append(&s.input, ..transmute([]u8)text)
			}
			return true
		}
		n := len(s.keys)
		if n == 0 && k != .Escape && text != "n" do return false
		ky := n > 0 ? s.keys[clamp(s.ki, 0, n - 1)] : Ssh_Key{}
		switch {
		case k == .Down: s.ki = min(s.ki + 1, n - 1)
		case k == .Up: s.ki = max(s.ki - 1, 0)
		case k == .Enter: ssh_run(a, "keycopy", ky.name)
		case text == "a": ssh_run(a, ky.agent ? "agent-del" : "agent-add", ky.name); s.reload_at = {}
		case text == "k": s.tab = 0; s.toast = fmt.aprintf("Pick a host · ^K sends %s", ky.name)
		case text == "n": ssh_run(a, "newkey")
		case text == "q": ssh_run(a, "qr", ky.name)
		case k == .Escape: a.exit = 1; a.done = true
		case: return false
		}
	}
	return true
}

Ssh_Row :: struct { col: int, id, label, sub, meta: string, tog, on, dim, dot: bool }

// The Host page's rows: the server's settings (left), then sessions and allowed keys (right).
@(private = "file")
ssh_host_rows :: proc(s: ^Ssh) -> []Ssh_Row {
	out := make([dynamic]Ssh_Row, 0, 16, context.temp_allocator)
	append(&out, Ssh_Row{col = 0, id = "run", label = "SSH server (sshd)", sub = s.inst ? "Lets other machines log in to this one" : "Not installed · Omarchy: Setup › Security › SSHD", tog = true, on = s.run})
	append(&out, Ssh_Row{col = 0, id = "boot", label = "Start at boot", sub = "systemctl enable sshd", tog = true, on = s.boot, dim = !s.run})
	append(&out, Ssh_Row{col = 0, id = "port", label = "Port", sub = fmt.tprintf("Listening on :%d · ← → changes · firewall follows", s.sport), meta = fmt.tprintf("‹ %d ›", s.sport), dim = !s.run})
	append(&out, Ssh_Row{col = 0, id = "pass", label = "Password login", sub = s.pass ? "On · bots will try passwords; keys only is safer" : "Off: keys only (recommended)", tog = true, on = s.pass, dim = !s.run})
	append(&out, Ssh_Row{col = 0, id = "root", label = "Root login", sub = "Off: log in as yourself, then sudo", tog = true, on = s.root, dim = !s.run})
	append(&out, Ssh_Row{col = 0, id = "lan", label = "Only from home network and Tailscale", sub = "ufw allows 192.168.0.0/16 and 100.64.0.0/10", tog = true, on = s.lan, dim = !s.run})
	if s.run do for x in s.sess do append(&out, Ssh_Row{col = 1, id = fmt.tprintf("sess:%s", x.tty), label = fmt.tprintf("%s · %s", x.who, x.ip), sub = fmt.tprintf("%s · since %s", x.what != "" ? x.what : x.tty, x.since), meta = "end Del", dot = true})
	for x in s.auth do append(&out, Ssh_Row{col = 1, id = fmt.tprintf("auth:%s", x.line), label = x.comment, sub = x.info})
	return out[:]
}

@(private = "file")
ssh_host_act :: proc(a: ^App, rows: []Ssh_Row, confirmed: bool) {
	s := a.ssh
	if s.hi >= len(rows) do return
	r := rows[s.hi]
	switch {
	case r.id == "run": ssh_run(a, "sshd", s.run ? "off" : "on")
	case r.dim: s.toast = "Turn the SSH server on first"
	case r.id == "boot": ssh_run(a, "boot", s.boot ? "off" : "on")
	case r.id == "port": ssh_run(a, "port", s.sport == 22 ? "2222" : "22")
	case r.id == "pass":
		if !s.pass && !confirmed { s.hask = "pass"; return }
		ssh_run(a, "pass", s.pass ? "off" : "on")
	case r.id == "root": ssh_run(a, "root", s.root ? "off" : "on")
	case r.id == "lan": ssh_run(a, "lan", s.lan ? "off" : "on")
	case strings.has_prefix(r.id, "sess:"):
		if !confirmed { s.hask = r.id; return }
		ssh_run(a, "end", r.id[5:])
	case strings.has_prefix(r.id, "auth:"):
		if !confirmed { s.hask = r.id; return }
		ssh_run(a, "unauth", r.id[5:])
	}
	s.hask = ""
	s.reload_at = {}
}

ssh_click :: proc(a: ^App, x, y, button: int) -> bool {
	s := a.ssh
	h, ok := hit_at(a, x, y)
	if !ok { a.exit = 1; a.done = true; return true }
	#partial switch h.kind {
	case .Tab: s.tab, s.toast, s.band = h.a, "", ""
	case .Row:
		l := ssh_list(a)
		if h.a < len(l) {
			if s.cur == h.a && s.band == "" do ssh_connect(a)
			else { s.cur, s.band = h.a, ""; s.sel = strings.clone(l[h.a].id); s.toast = "" }
		}
	case .Chip: // the actions under a host, the band's buttons, the Keys page's
		keys := [?]string{"\n", "o", "y", "f", "m", "k", "e"}
		switch {
		case h.b == 0 && h.a < len(keys): ssh_key(a, h.a == 0 ? .Enter : .None, h.a > 0, false, rune(keys[h.a][0]), "")
		case h.b == 1: ssh_band_key(a, h.a == 0 ? .Enter : .Escape, 0, h.a == 0 ? "y" : (h.a == 2 ? "R" : ""))
		case h.b == 2:
			ks := [?]string{"\n", "a", "k", "n", "q"}
			if h.a < len(ks) do ssh_key(a, h.a == 0 ? .Enter : .None, false, false, rune(ks[h.a][0]), h.a == 0 ? "" : ks[h.a])
		}
	case .Item: // a row on the Host page
		if s.hi == h.a do ssh_host_act(a, ssh_host_rows(s), false)
		else do s.hi, s.hask = h.a, ""
	case .Result: s.ki = h.a // a key
	case .Confirm: ssh_run(a, "block", s.failed_ip)
	}
	return true
}

// ---------- drawing ----------

@(private = "file")
ssh_btn :: proc(a: ^App, cv: ^Canvas, S, x, y: int, label, key: string, prim, hot: bool, id, group: int, H: HUD, soft: u32, f, fk: ^Font, h := 28) -> int {
	bw := tw(f, label) + 7 * S + tw(fk, key) + 20 * S
	bc := hot ? H.hot : H.acc
	if prim || hot do fill_rect(cv, x, y, bw, h * S, argb(bc, 0xff))
	rounded_rect(cv, x, y, bw, h * S, 0, 0, f32(S), argb(prim || hot ? bc : H.line, 0xff))
	text_in(cv, f, label, x + 10 * S, y, h * S, argb(prim || hot ? H.bg : soft, 0xff))
	text_in(cv, fk, key, x + 10 * S + tw(f, label) + 7 * S, y, h * S, argb(prim || hot ? H.bg : H.dim, 0xff))
	hit_add(a, x, y, bw, h * S, .Chip, id, group)
	return bw
}

ssh_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	s := a.ssh
	t := a.theme
	H := hud(t)
	soft := mix(H.fg, H.bg, 0.2)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	fill_rect(cv, 0, 0, w, h, argb(H.bg, a.bg_alpha))
	// the head: SSH / what it is · the pages · the agent and the server
	hh := 60 * S
	px := 24 * S
	ty := (hh - int(s.f13b.line_h) - 3 * S - int(s.f10.line_h)) / 2
	spaced(cv, s.f13b, "SSH", px, ty, int(s.f13b.line_h), H.acc, 2 * S, true)
	sub := "Remote and host · Super+Shift+S"
	text_in(cv, s.f10, sub, px, ty + int(s.f13b.line_h) + 3 * S, int(s.f10.line_h), argb(H.dim, 0xff))
	tx := px + tw(s.f10, sub) + 22 * S
	alarm := s.run && s.failed >= 20
	for l, i in ([3]string{"CONNECT", "HOST", "KEYS"}) {
		on := i == s.tab
		k := fmt.tprintf("Alt %d", i + 1)
		badge := ""
		if i == 1 && s.run && (alarm || len(s.sess) > 0) do badge = alarm ? "!" : fmt.tprint(len(s.sess))
		bw := spaced_w(s.f11b, l, S) + 7 * S + tw(s.f10, k) + (badge != "" ? tw(s.f10b, badge) + 7 * S : 0) + 28 * S
		spaced(cv, s.f11b, l, tx + 14 * S, 0, hh, on ? H.fg : H.dim, S)
		kx := tx + 14 * S + spaced_w(s.f11b, l, S) + 7 * S
		text_in(cv, s.f10, k, kx, 0, hh, argb(H.faint, 0xff))
		if badge != "" do text_in(cv, s.f10b, badge, kx + tw(s.f10, k) + 7 * S, 0, hh, argb(alarm ? H.hot : H.acc, 0xff))
		if on do fill_rect(cv, tx, hh - 2 * S, bw, 2 * S, argb(H.acc, 0xff))
		hit_add(a, tx, 0, bw, hh, .Tab, i, 0)
		tx += bw + 2 * S
	}
	al := fmt.tprintf("agent · %d key%s loaded", s.agent, s.agent == 1 ? "" : "s")
	sl := s.run ? fmt.tprintf("sshd on :%d · %d connected", s.sport, len(s.sess)) : "sshd off"
	ry := (hh - 2 * int(s.f10.line_h) - 3 * S) / 2
	text_in(cv, s.f10, al, w - px - tw(s.f10, al), ry, int(s.f10.line_h), argb(H.dim, 0xff))
	text_in(cv, s.f10, sl, w - px - tw(s.f10, sl), ry + int(s.f10.line_h) + 3 * S, int(s.f10.line_h), argb(s.run ? (alarm ? H.hot : t.green) : H.dim, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	// the foot
	fh := 30 * S
	fy := h - fh
	top := hh + S
	switch s.tab {
	case 0: ssh_draw_connect(a, cv, S, top, fy, H, soft)
	case 1: ssh_draw_host(a, cv, S, top, fy, H, soft)
	case 2: ssh_draw_keys(a, cv, S, top, fy, H, soft)
	}
	for i in fy * w ..< h * w do cv.px[i] = 0
	fill_rect(cv, 0, fy, w, h - fy, argb(H.bg, a.bg_alpha))
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	HK: [][2]string
	switch {
	case s.tab == 0 && s.band == "newhost": HK = {{"y", "Trust"}, {"Esc", "Cancel"}}
	case s.tab == 0 && s.band == "changed": HK = {{"R", "Replace"}, {"Esc", "Keep blocking"}}
	case s.tab == 0 && s.band == "step": HK = {{"Esc", "Cancel"}}
	case s.tab == 0 && s.band == "fail": HK = {{"r", "Retry"}, {"Esc", "OK"}}
	case s.tab == 0 && s.band != "": HK = {{"↵", s.band == "pass" ? "Unlock" : "Forward"}, {"Esc", "Cancel"}}
	case s.tab == 0: HK = {{"↑↓", "Host"}, {"↵", "Connect"}, {"^Y ^O ^F ^M ^K", "Actions"}, {"Tab", "Host · Keys"}, {"Esc", "Close"}}
	case s.tab == 1: HK = {{"↑↓ ← →", "Move"}, {"␣", "Toggle"}, {"Del", "End / remove"}, {"a", "Allow key"}, {"Tab", "Keys"}}
	case: HK = {{"↑↓", "Key"}, {"↵", "Copy public"}, {"a", "Agent"}, {"n", "New"}, {"Tab", "Connect"}}
	}
	kx := px
	for k in HK {
		kw := tw(s.f10, k[0]) + 8 * S
		rounded_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, s.f10, k[0], kx + 4 * S, fy, fh, argb(H.fg, 0xff))
		kx += kw + 5 * S
		text_in(cv, s.f10, k[1], kx, fy, fh, argb(H.dim, 0xff))
		kx += tw(s.f10, k[1]) + 14 * S
	}
	if s.toast != "" {
		tt := ellipsize(s.f10, s.toast, w - px - kx)
		text_in(cv, s.f10, tt, w - px - tw(s.f10, tt), fy, fh, argb(s.toast_hot ? H.hot : H.acc, 0xff))
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 26)
}

@(private = "file")
ssh_draw_connect :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32) {
	s := a.ssh
	t := a.theme
	w := cv.w
	lw := 400 * S
	fill_rect(cv, lw, top, S, fy - top, argb(H.line, 0xff))
	// the filter
	bx, by, bw, bh := 12 * S, top + 10 * S, lw - 24 * S, 36 * S
	fill_rect(cv, bx, by, bw, bh, argb(t.fg, 0x0a))
	rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(S), argb(H.line, 0xff))
	fill_rect(cv, bx, by, 3 * S, bh, argb(H.acc, 0xff))
	text_in(cv, s.f14, "›", bx + 10 * S, by, bh, argb(H.acc, 0xff))
	qx := bx + 10 * S + tw(s.f14, "›") + 8 * S
	qt := string(a.query[:])
	q := strings.to_lower(ssh_query(a), context.temp_allocator)
	l := ssh_list(a)
	cnt := ssh_typed(q) ? "new host" : (q != "" ? fmt.tprintf("%d match", len(l)) : fmt.tprintf("%d hosts", len(s.hosts)))
	if qt == "" do text_in(cv, s.f12, "Find a host, or type user@host…", qx, by, bh, argb(H.hint, 0xff))
	else do text_in(cv, s.f12, qt, qx, by, bh, argb(H.fg, 0xff))
	qs := shape(s.f12, qt)
	cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
	fill_rect(cv, qx + int(qs.cp_x[min(cp, len(qs.cp_x) - 1)]), by + (bh - int(s.f12.line_h)) / 2, max(S, 2), int(s.f12.line_h), argb(H.acc, 0xff))
	text_in(cv, s.f10, cnt, bx + bw - 10 * S - tw(s.f10, cnt), by, bh, argb(H.dim, 0xff))
	// the hosts
	sel, has := ssh_sel(a)
	y := by + bh + 4 * S
	last_g := ""
	rh := 44 * S
	// scroll so the picked one shows: each group adds its heading
	cur := has ? s.cur : 0
	s.top = clamp(s.top, 0, cur)
	for s.top < cur {
		yy, g := y, ""
		for j in s.top ..= cur {
			if l[j].group != g { g = l[j].group; yy += 24 * S }
			yy += rh + 2 * S
		}
		if yy <= fy - 6 * S do break
		s.top += 1
	}
	for hst, i in l {
		if i < s.top do continue
		if hst.group != last_g {
			last_g = hst.group
			if y + 24 * S > fy do break
			hn := ""
			switch hst.group {
			case "NEARBY": hn = "Tailscale"
			case "RECENT": hn = "known_hosts · history"
			case "TYPED": hn = "not in config"
			case "CONFIG": hn = "~/.ssh/config"
			}
			spaced(cv, s.f10b, hst.group, 20 * S, y + 6 * S, 18 * S, H.dim, S)
			text_in(cv, s.f10, hn, 20 * S + spaced_w(s.f10b, hst.group, S) + 8 * S, y + 6 * S, 18 * S, argb(H.faint, 0xff))
			y += 24 * S
		}
		if y + rh > fy - 6 * S do break
		on := has && hst.id == sel.id
		x0, x1 := 12 * S, lw - 12 * S
		if on {
			fill_rect(cv, x0, y, x1 - x0, rh, argb(H.acc, 0x14))
			rounded_rect(cv, x0, y, x1 - x0, rh, 0, 0, f32(S), argb(H.acc, 0xff))
			fill_rect(cv, x0, y, 3 * S, rh, argb(H.acc, 0xff))
			mark_sel(a, x0, y, x1 - x0, rh)
		}
		live := hst.ms != "" && hst.ms != "down"
		dot := hst.open ? H.acc : (live ? t.green : H.faint)
		fill_rect(cv, x0 + 12 * S, y + (rh - 7 * S) / 2, 7 * S, 7 * S, argb(dot, 0xff))
		ms := hst.src == "typed" ? "" : (hst.ms == "" ? "…" : (hst.ms == "down" ? "down" : (hst.ms == "via" ? "via" : fmt.tprintf("%s ms", hst.ms))))
		msw := 46 * S
		text_in(cv, s.f10, ms, x1 - 10 * S - tw(s.f10, ms), y, rh, argb(hst.ms == "down" ? H.hot : H.dim, 0xff))
		right := x1 - 10 * S - msw - 6 * S
		tag, tc := hst.tag, H.dim
		switch {
		case hst.open: tag, tc = "OPEN", H.acc
		case tag == "PROD": tc = t.yellow
		case tag == "" && hst.newhost: tag = "NEW"
		}
		if tag != "" {
			tgw := tw(s.f9b, tag) + 10 * S
			rounded_rect(cv, right - tgw, y + (rh - 14 * S) / 2, tgw, 14 * S, 0, 0, f32(S), argb(tc, 0xff))
			text_in(cv, s.f9b, tag, right - tgw + 5 * S, y + (rh - 14 * S) / 2, 14 * S, argb(tc, 0xff))
			right -= tgw + 8 * S
		}
		nx := x0 + 12 * S + 7 * S + 10 * S
		ny := y + (rh - int(s.f12.line_h) - 3 * S - int(s.f10.line_h)) / 2
		nf := on ? s.f12b : s.f12
		name := ellipsize(nf, hst.name, right - nx)
		at := q != "" && !ssh_typed(q) ? strings.index(strings.to_lower(name, context.temp_allocator), q) : -1
		nc := live || hst.src == "typed" ? H.fg : H.dim
		if at >= 0 && at + len(q) <= len(name) {
			text_in(cv, nf, name[:at], nx, ny, int(s.f12.line_h), argb(nc, 0xff))
			hx := nx + tw(nf, name[:at])
			text_in(cv, nf, name[at:at + len(q)], hx, ny, int(s.f12.line_h), argb(H.acc, 0xff))
			text_in(cv, nf, name[at + len(q):], hx + tw(nf, name[at:at + len(q)]), ny, int(s.f12.line_h), argb(nc, 0xff))
		} else do text_in(cv, nf, name, nx, ny, int(s.f12.line_h), argb(nc, 0xff))
		subl := fmt.tprintf("%s@%s%s%s", hst.user, hst.host, hst.port != "22" ? fmt.tprintf(":%s", hst.port) : "", hst.jump != "" ? fmt.tprintf(" · via %s", hst.jump) : "")
		text_in(cv, s.f10, ellipsize(s.f10, subl, right - nx), nx, ny + int(s.f12.line_h) + 3 * S, int(s.f10.line_h), argb(H.dim, 0xff))
		hit_add(a, x0, y, x1 - x0, rh, .Row, i, 0)
		y += rh + 2 * S
	}
	if len(l) == 0 do text_in(cv, s.f11, "No host matches · type user@host to connect to a new one", 24 * S, y + 20 * S, 20 * S, argb(H.dim, 0xff))
	if !has do return
	// the picked host
	x := lw + S
	rw := w - x
	hy := top + 16 * S
	text_in(cv, s.f18b, sel.name, x + 20 * S, hy, int(s.f18b.line_h), argb(H.fg, 0xff))
	live := sel.ms != "" && sel.ms != "down"
	st, stc := "", H.dim
	switch {
	case sel.open: st, stc = "● session open", H.acc
	case sel.src == "typed": st = "not checked yet"
	case sel.ms == "via": st, stc = fmt.tprintf("● through %s", sel.jump), H.acc
	case live: st, stc = fmt.tprintf("● %s ms", sel.ms), t.green
	case sel.ms == "down": st, stc = "● not answering", H.hot
	}
	text_in(cv, s.f11, st, x + 20 * S + tw(s.f18b, sel.name) + 10 * S, hy, int(s.f18b.line_h), argb(stc, 0xff))
	src := fmt.tprintf("from %s", sel.src)
	text_in(cv, s.f10, src, w - 20 * S - tw(s.f10, src), hy, int(s.f18b.line_h), argb(H.dim, 0xff))
	hy += int(s.f18b.line_h) + 4 * S
	text_in(cv, s.f12, ellipsize(s.f12, ssh_cmd(sel), rw - 40 * S), x + 20 * S, hy, int(s.f12.line_h), argb(soft, 0xff))
	hy += int(s.f12.line_h) + 10 * S
	fill_rect(cv, x, hy, rw, S, argb(H.line, 0xff))
	hy += 12 * S
	kv := [?][3]string{
		{"HostName", sel.host, ""}, {"User", sel.user, ""}, {"Port", sel.port, sel.port != "22" ? "yellow" : ""},
		{"IdentityFile", sel.key, ""}, {"ProxyJump", sel.jump != "" ? sel.jump : "—", sel.jump != "" ? "acc" : "faint"},
		{"Host key", sel.newhost ? "not seen before" : "in known_hosts", sel.newhost ? "yellow" : "soft"}, {"Last connected", sel.last, "soft"},
	}
	for e in kv {
		text_in(cv, s.f11, e[0], x + 20 * S, hy, 18 * S, argb(H.dim, 0xff))
		c := H.fg
		switch e[2] { case "yellow": c = t.yellow; case "acc": c = H.acc; case "faint": c = H.faint; case "soft": c = soft }
		text_in(cv, s.f11, ellipsize(s.f11, e[1], rw - 160 * S), x + 20 * S + 122 * S, hy, 18 * S, argb(c, 0xff))
		hy += 18 * S + 6 * S
	}
	if len(sel.fwd) > 0 {
		hy += 6 * S
		spaced(cv, s.f10b, "PORT FORWARDS", x + 20 * S, hy, 16 * S, H.dim, S)
		hy += 20 * S
		for f in sel.fwd {
			fill_rect(cv, x + 20 * S, hy, rw - 40 * S, 28 * S, argb(t.fg, 0x0a))
			rounded_rect(cv, x + 20 * S, hy, rw - 40 * S, 28 * S, 0, 0, f32(S), argb(H.line, 0xff))
			rounded_rect(cv, x + 30 * S, hy + 7 * S, tw(s.f9b, f[0]) + 8 * S, 14 * S, 0, 0, f32(S), argb(H.acc, 0xff))
			text_in(cv, s.f9b, f[0], x + 34 * S, hy + 7 * S, 14 * S, argb(H.acc, 0xff))
			text_in(cv, s.f11, f[1], x + 30 * S + tw(s.f9b, f[0]) + 18 * S, hy, 28 * S, argb(H.fg, 0xff))
			hy += 28 * S + 4 * S
		}
	}
	// the band (connecting, a new or changed key, a passphrase, a forward) or the actions
	if s.band != "" {
		title, c, bg: string
		cc := H.acc
		lines := make([dynamic][2]string, 0, 3, context.temp_allocator) // text, colour
		switch s.band {
		case "step":
			title = fmt.tprintf("Connecting to %s%s", sel.name, sel.jump != "" ? fmt.tprintf(" via %s", sel.jump) : "")
			append(&lines, [2]string{ssh_cmd(sel), "dim"})
		case "newhost":
			title, cc = fmt.tprintf("First time connecting to %s", sel.name), t.yellow
			append(&lines, [2]string{fmt.tprintf("Key fingerprint is %s", s.band_a), "fg"}, [2]string{sel.src == "Tailscale" ? "Tailscale vouches for this machine." : "Check it against the server before saying yes.", "soft"})
		case "changed":
			title, cc = fmt.tprintf("Host key changed for %s · not connecting", sel.name), H.hot
			append(&lines, [2]string{fmt.tprintf("Saved: %s   Now: %s", s.band_a, s.band_b), "fg"}, [2]string{"Someone may be in the middle, or the server was reinstalled. Only update it if you know it was rebuilt.", "soft"})
		case "pass":
			title = fmt.tprintf("Unlock %s", s.band_a)
			append(&lines, [2]string{fmt.tprintf("%s needs this key. The passphrase never leaves this machine.", sel.name), "soft"})
		case "forward":
			title = fmt.tprintf("Forward a port through %s", sel.name)
			append(&lines, [2]string{"LOCAL:HOST:PORT, e.g. 5432:db:5432 · localhost:5432 then reaches db:5432 over SSH", "soft"})
		case "fail":
			title, cc = fmt.tprintf("Could not connect to %s", sel.name), H.hot
			append(&lines, [2]string{s.band_a, "fg"})
		}
		_ = c; _ = bg
		inner := rw - 40 - 28
		wrapped := make([dynamic][2]string, 0, 6, context.temp_allocator)
		for ln in lines do for wl in wrap_hard(s.f11, ln[0], inner * S) do append(&wrapped, [2]string{wl, ln[1]})
		bh2 := 12 * S + int(s.f13b.line_h) + 8 * S + len(wrapped) * 16 * S + (s.band == "step" ? 8 * S + 3 * S + 4 * S + int(s.f10.line_h) : 0) + (s.band == "pass" || s.band == "forward" ? 8 * S + 30 * S : 0) + 8 * S + 26 * S + 12 * S
		bx2, by2 := x + 20 * S, fy - 12 * S - bh2
		fill_rect(cv, bx2, by2, rw - 40 * S, bh2, cc == H.acc ? argb(t.fg, 0x0a) : argb(cc, 0x12))
		rounded_rect(cv, bx2, by2, rw - 40 * S, bh2, 0, 0, f32(S), argb(cc, 0xff))
		fill_rect(cv, bx2, by2, 3 * S, bh2, argb(cc, 0xff))
		yy := by2 + 12 * S
		text_in(cv, s.f13b, ellipsize(s.f13b, title, rw - 70 * S), bx2 + 14 * S, yy, int(s.f13b.line_h), argb(cc, 0xff))
		yy += int(s.f13b.line_h) + 8 * S
		for ln in wrapped {
			lc := ln[1] == "fg" ? H.fg : (ln[1] == "dim" ? H.dim : soft)
			text_in(cv, s.f11, ln[0], bx2 + 14 * S, yy, 16 * S, argb(lc, 0xff))
			yy += 16 * S
		}
		if s.band == "step" {
			yy += 8 * S
			names := [4]string{"Resolving", fmt.tprintf("TCP %s", sel.port), "Key exchange", "Logging in"}
			sw := (rw - 40 * S - 28 * S - 3 * 4 * S) / 4
			for nm, i in names {
				sx := bx2 + 14 * S + i * (sw + 4 * S)
				c2 := i < s.step ? t.green : (i == s.step ? H.acc : H.faint)
				fill_rect(cv, sx, yy, sw, 3 * S, argb(i < s.step ? t.green : (i == s.step ? H.acc : H.line), 0xff))
				text_in(cv, s.f10, i < s.step ? fmt.tprintf("%s ✓", nm) : nm, sx, yy + 7 * S, int(s.f10.line_h), argb(c2, 0xff))
			}
			yy += 3 * S + 4 * S + int(s.f10.line_h)
		}
		if s.band == "pass" || s.band == "forward" {
			yy += 8 * S
			fill_rect(cv, bx2 + 14 * S, yy, rw - 68 * S, 30 * S, argb(H.bg, 0xff))
			rounded_rect(cv, bx2 + 14 * S, yy, rw - 68 * S, 30 * S, 0, 0, f32(S), argb(H.acc, 0xff))
			shown := s.band == "pass" ? strings.repeat("•", utf8.rune_count_in_string(string(s.input[:])), context.temp_allocator) : string(s.input[:])
			ph := s.band == "pass" ? "passphrase" : "5432:db:5432"
			if shown == "" do text_in(cv, s.f12, ph, bx2 + 24 * S, yy, 30 * S, argb(H.hint, 0xff))
			else do text_in(cv, s.f12, shown, bx2 + 24 * S, yy, 30 * S, argb(H.fg, 0xff))
			fill_rect(cv, bx2 + 24 * S + tw(s.f12, shown) + S, yy + 8 * S, max(S, 2), 14 * S, argb(H.acc, 0xff))
			yy += 30 * S
		}
		yy += 8 * S
		ax := bx2 + 14 * S
		switch s.band {
		case "step": ax += ssh_btn(a, cv, S, ax, yy, "Cancel", "Esc", false, false, 1, 1, H, soft, s.f11b, s.f11, 26)
		case "newhost":
			ax += ssh_btn(a, cv, S, ax, yy, "Trust and connect", "y", true, false, 0, 1, H, soft, s.f11b, s.f11, 26) + 6 * S
			ssh_btn(a, cv, S, ax, yy, "Cancel", "n", false, false, 1, 1, H, soft, s.f11b, s.f11, 26)
		case "changed":
			ax += ssh_btn(a, cv, S, ax, yy, "Keep blocking", "Esc", true, false, 1, 1, H, soft, s.f11b, s.f11, 26) + 6 * S
			ssh_btn(a, cv, S, ax, yy, "Replace saved key…", "R", false, false, 2, 1, H, soft, s.f11b, s.f11, 26)
		case "pass":
			ax += ssh_btn(a, cv, S, ax, yy, "Unlock", "↵", true, false, 0, 1, H, soft, s.f11b, s.f11, 26) + 6 * S
			ssh_btn(a, cv, S, ax, yy, "Cancel", "Esc", false, false, 1, 1, H, soft, s.f11b, s.f11, 26)
		case "forward":
			ax += ssh_btn(a, cv, S, ax, yy, "Forward", "↵", true, false, 0, 1, H, soft, s.f11b, s.f11, 26) + 6 * S
			ssh_btn(a, cv, S, ax, yy, "Cancel", "Esc", false, false, 1, 1, H, soft, s.f11b, s.f11, 26)
		case "fail":
			ax += ssh_btn(a, cv, S, ax, yy, "Retry", "r", false, true, 0, 1, H, soft, s.f11b, s.f11, 26) + 6 * S
			ssh_btn(a, cv, S, ax, yy, "OK", "Esc", false, false, 1, 1, H, soft, s.f11b, s.f11, 26)
		}
		return
	}
	ay := fy - 14 * S - 28 * S
	ax := x + 20 * S
	if sel.tag == "GIT" {
		fill_rect(cv, x, ay - 12 * S, rw, S, argb(H.line, 0xff))
		ax += ssh_btn(a, cv, S, ax, ay, "Test login", "↵", true, false, 0, 0, H, soft, s.f11b, s.f11) + 6 * S
		ssh_btn(a, cv, S, ax, ay, "Copy command", "^Y", false, false, 2, 0, H, soft, s.f11b, s.f11)
		return
	}
	acts := [?][3]string{{"Connect", "↵", "0"}, {"Files (SFTP)", "^O", "1"}, {"Copy command", "^Y", "2"}, {"Port forward…", "^F", "3"}, {"Mount", "^M", "4"}, {"Send my key", "^K", "5"}, {"Edit in config", "^E", "6"}}
	// as many as fit on the first row, the rest under them
	abw := make([]int, len(acts), context.temp_allocator)
	split, run := len(acts), x + 20 * S
	for ac, i in acts {
		abw[i] = tw(s.f11b, ac[0]) + 7 * S + tw(s.f11, ac[1]) + 20 * S
		if run + abw[i] > w - 20 * S && split == len(acts) do split = i
		run += abw[i] + 6 * S
	}
	if split < len(acts) do ay -= 28 * S + 6 * S
	fill_rect(cv, x, ay - 12 * S, rw, S, argb(H.line, 0xff))
	for ac, i in acts {
		if i == split { ax = x + 20 * S; ay += 28 * S + 6 * S }
		id, _ := strconv.parse_int(ac[2])
		ax += ssh_btn(a, cv, S, ax, ay, ac[0], ac[1], ac[0] == "Connect", false, id, 0, H, soft, s.f11b, s.f11) + 6 * S
	}
}

@(private = "file")
ssh_draw_host :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32) {
	s := a.ssh
	t := a.theme
	w := cv.w
	y := top + 10 * S
	if s.run && s.failed >= 20 {
		ah := 36 * S
		fill_rect(cv, 20 * S, y, w - 40 * S, ah, argb(H.hot, 0x12))
		rounded_rect(cv, 20 * S, y, w - 40 * S, ah, 0, 0, f32(S), argb(H.hot, 0xff))
		fill_rect(cv, 20 * S, y, 3 * S, ah, argb(H.hot, 0xff))
		l1 := fmt.tprintf("%d failed logins from %s in the last hour", s.failed, s.failed_ip)
		text_in(cv, s.f11b, l1, 32 * S, y, ah, argb(H.hot, 0xff))
		b := "Block for 24 h"
		bw := tw(s.f10b, b) + 6 * S + tw(s.f10, "b") + 18 * S
		bx := w - 32 * S - bw
		fill_rect(cv, bx, y + 6 * S, bw, 24 * S, argb(H.hot, 0xff))
		text_in(cv, s.f10b, b, bx + 9 * S, y + 6 * S, 24 * S, argb(H.bg, 0xff))
		text_in(cv, s.f10, "b", bx + 9 * S + tw(s.f10b, b) + 6 * S, y + 6 * S, 24 * S, argb(H.bg, 0xff))
		hit_add(a, bx, y + 6 * S, bw, 24 * S, .Confirm, 0, 0)
		sx := 32 * S + tw(s.f11b, l1) + 10 * S
		text_in(cv, s.f10, ellipsize(s.f10, s.pass ? "Password login is on: some may get in." : "All refused (password login is off).", bx - 10 * S - sx), sx, y, ah, argb(soft, 0xff))
		y += ah + 8 * S
	}
	rows := ssh_host_rows(s)
	s.hi = clamp(s.hi, 0, max(len(rows) - 1, 0))
	colw := [2]int{380 * S, w - 40 * S - 380 * S - 18 * S}
	colx := [2]int{20 * S, 20 * S + 380 * S + 18 * S}
	cy := [2]int{y, y}
	head :: proc(a: ^App, cv: ^Canvas, s: ^Ssh, S, x, y: int, h, hn: string, H: HUD) -> int {
		spaced(cv, s.f10b, h, x + 2 * S, y + 8 * S, 16 * S, H.dim, S)
		text_in(cv, s.f10, hn, x + 2 * S + spaced_w(s.f10b, h, S) + 8 * S, y + 8 * S, 16 * S, argb(H.faint, 0xff))
		return y + 8 * S + 16 * S + 5 * S
	}
	host := strings.trim_space(string(os.read_entire_file("/etc/hostname", context.temp_allocator) or_else nil))
	cy[0] = head(a, cv, s, S, colx[0], cy[0], "THIS MACHINE AS A SERVER", host, H)
	sess_head, key_head := false, false
	if !s.run { cy[1] = head(a, cv, s, S, colx[1], cy[1], "CONNECTED NOW", "server off", H); sess_head = true }
	for r, i in rows {
		c := r.col
		if c == 1 && !sess_head && strings.has_prefix(r.id, "sess:") { cy[1] = head(a, cv, s, S, colx[1], cy[1], "CONNECTED NOW", fmt.tprintf("%d sessions · Del ends one", len(s.sess)), H); sess_head = true }
		if c == 1 && !key_head && strings.has_prefix(r.id, "auth:") {
			if !sess_head { cy[1] = head(a, cv, s, S, colx[1], cy[1], "CONNECTED NOW", "nobody", H); sess_head = true }
			cy[1] = head(a, cv, s, S, colx[1], cy[1], "ALLOWED KEYS", "~/.ssh/authorized_keys · a adds from clipboard", H); key_head = true
		}
		rh := 42 * S
		if cy[c] + rh > fy - 6 * S do continue
		x, rw := colx[c], colw[c]
		on := i == s.hi
		asking := s.hask != "" && (s.hask == r.id)
		inv := on && !asking
		bg := asking ? argb(H.hot, 0x14) : (on ? argb(H.acc, 0xff) : argb(t.fg, 0x0a))
		fill_rect(cv, x, cy[c], rw, rh, bg)
		rounded_rect(cv, x, cy[c], rw, rh, 0, 0, f32(S), argb(asking ? H.hot : (on ? H.acc : H.line), 0xff))
		if on do mark_sel(a, x, cy[c], rw, rh)
		lx := x + 10 * S
		if r.dot { fill_rect(cv, lx, cy[c] + (rh - 7 * S) / 2, 7 * S, 7 * S, argb(t.green, 0xff)); lx += 17 * S }
		right := x + rw - 10 * S
		sub, sc := r.sub, H.dim
		meta := r.meta
		if asking {
			sc, meta = H.hot, "y / n"
			switch {
			case r.id == "pass": sub = "Sure? Keys are much safer · y turns it on, n keeps it off"
			case strings.has_prefix(r.id, "sess:"): sub = "End this session? y / n · their unsaved work is lost"
			case: sub = "Remove this key? y / n · that machine can no longer log in"
			}
		}
		if r.tog {
			sw, sh := 28 * S, 14 * S
			sx, sy := right - sw, cy[c] + (rh - sh) / 2
			if r.on do fill_rect(cv, sx, sy, sw, sh, argb(inv ? H.bg : H.acc, 0xff))
			rounded_rect(cv, sx, sy, sw, sh, 0, 0, f32(S), argb(inv ? H.bg : (r.on ? H.acc : H.faint), 0xff))
			fill_rect(cv, r.on ? sx + sw - 12 * S : sx + 2 * S, sy + 2 * S, 10 * S, 10 * S, argb(r.on ? (inv ? H.acc : H.bg) : (inv ? H.bg : H.dim), 0xff))
			right = sx - 8 * S
		} else if meta != "" {
			text_in(cv, s.f10b, meta, right - tw(s.f10b, meta), cy[c], rh, argb(inv ? H.bg : (asking ? H.hot : H.acc), 0xff))
			right -= tw(s.f10b, meta) + 8 * S
		}
		ly := cy[c] + (rh - int(s.f11b.line_h) - 3 * S - int(s.f10.line_h)) / 2
		text_in(cv, s.f11b, ellipsize(s.f11b, r.label, right - lx), lx, ly, int(s.f11b.line_h), argb(inv ? H.bg : H.fg, 0xff))
		text_in(cv, s.f10, ellipsize(s.f10, sub, right - lx), lx, ly + int(s.f11b.line_h) + 3 * S, int(s.f10.line_h), argb(inv ? H.bg : sc, 0xff))
		if r.dim && !on do fill_rect(cv, x, cy[c], rw, rh, argb(H.bg, 0x80))
		hit_add(a, x, cy[c], rw, rh, .Item, i, 0)
		cy[c] += rh + 3 * S
	}
	if !key_head && len(s.auth) == 0 do text_in(cv, s.f11, "No keys allowed in yet · a adds the one on the clipboard", colx[1], cy[1] + 10 * S, 20 * S, argb(H.dim, 0xff))
}

@(private = "file")
ssh_draw_keys :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32) {
	s := a.ssh
	t := a.theme
	w := cv.w
	x0, x1 := 20 * S, w - 20 * S
	y := top + 12 * S
	s.ki = clamp(s.ki, 0, max(len(s.keys) - 1, 0))
	if len(s.keys) == 0 do text_in(cv, s.f12, "No keys in ~/.ssh yet · n makes one", x0, y + 20 * S, 20 * S, argb(H.dim, 0xff))
	for k, i in s.keys {
		rh := 52 * S
		on := i == s.ki
		fill_rect(cv, x0, y, x1 - x0, rh, on ? argb(H.acc, 0x14) : argb(t.fg, 0x0a))
		rounded_rect(cv, x0, y, x1 - x0, rh, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
		if on { fill_rect(cv, x0, y, 3 * S, rh, argb(H.acc, 0xff)); mark_sel(a, x0, y, x1 - x0, rh) }
		tc := k.kind == "FIDO2 SK" ? t.yellow : H.acc
		tgw := 56 * S
		rounded_rect(cv, x0 + 12 * S, y + (rh - 16 * S) / 2, tgw, 16 * S, 0, 0, f32(S), argb(tc, 0xff))
		text_in(cv, s.f9b, k.kind, x0 + 12 * S + (tgw - tw(s.f9b, k.kind)) / 2, y + (rh - 16 * S) / 2, 16 * S, argb(tc, 0xff))
		right := x1 - 12 * S
		text_in(cv, s.f10, k.used, right - tw(s.f10, k.used), y, rh, argb(H.dim, 0xff))
		right -= max(130 * S, tw(s.f10, k.used)) + 10 * S
		ag := k.agent ? "● in agent" : (k.locked ? "○ locked" : "○ not loaded")
		text_in(cv, s.f10, ag, right - tw(s.f10, ag), y, rh, argb(k.agent ? t.green : H.dim, 0xff))
		right -= tw(s.f10, ag) + 12 * S
		nx := x0 + 12 * S + tgw + 12 * S
		ny := y + (rh - int(s.f12b.line_h) - 3 * S - int(s.f10.line_h)) / 2
		text_in(cv, s.f12b, k.name, nx, ny, int(s.f12b.line_h), argb(H.fg, 0xff))
		text_in(cv, s.f12, ellipsize(s.f12, k.comment, right - nx - tw(s.f12b, k.name) - 8 * S), nx + tw(s.f12b, k.name) + 8 * S, ny, int(s.f12b.line_h), argb(H.dim, 0xff))
		text_in(cv, s.f10, ellipsize(s.f10, k.fp, right - nx), nx, ny + int(s.f12b.line_h) + 3 * S, int(s.f10.line_h), argb(H.dim, 0xff))
		hit_add(a, x0, y, x1 - x0, rh, .Result, i, 0)
		y += rh + 6 * S
	}
	if len(s.keys) == 0 do return
	k := s.keys[s.ki]
	y += 6 * S
	// the public key, or the passphrase for the agent
	pw := x1 - x0
	if s.pass_key != "" {
		fill_rect(cv, x0, y, pw, 90 * S, argb(t.fg, 0x0a))
		rounded_rect(cv, x0, y, pw, 90 * S, 0, 0, f32(S), argb(H.acc, 0xff))
		text_in(cv, s.f13b, fmt.tprintf("Unlock %s for the agent (1 h)", s.pass_key), x0 + 14 * S, y + 10 * S, 20 * S, argb(H.acc, 0xff))
		fill_rect(cv, x0 + 14 * S, y + 40 * S, pw - 28 * S, 30 * S, argb(H.bg, 0xff))
		rounded_rect(cv, x0 + 14 * S, y + 40 * S, pw - 28 * S, 30 * S, 0, 0, f32(S), argb(H.acc, 0xff))
		dots := strings.repeat("•", utf8.rune_count_in_string(string(s.input[:])), context.temp_allocator)
		text_in(cv, s.f12, dots != "" ? dots : "passphrase · ↵ unlocks · Esc cancels", x0 + 24 * S, y + 40 * S, 30 * S, argb(dots != "" ? H.fg : H.hint, 0xff))
		return
	}
	lines := wrap_hard(s.f11, k.pub, pw - 28 * S)
	ph := 12 * S + 16 * S + 6 * S + len(lines) * 17 * S + 12 * S
	fill_rect(cv, x0, y, pw, ph, argb(t.fg, 0x0a))
	rounded_rect(cv, x0, y, pw, ph, 0, 0, f32(S), argb(H.line, 0xff))
	spaced(cv, s.f10b, fmt.tprintf("PUBLIC KEY · %s", strings.to_upper(k.name, context.temp_allocator)), x0 + 14 * S, y + 12 * S, 16 * S, H.dim, S)
	ly := y + 12 * S + 16 * S + 6 * S
	for l in lines { text_in(cv, s.f11, l, x0 + 14 * S, ly, 17 * S, argb(soft, 0xff)); ly += 17 * S }
	ay := fy - 14 * S - 28 * S
	ax := x0
	acts := [?][2]string{{"Copy public key", "↵"}, {k.agent ? "Remove from agent" : "Add to agent", "a"}, {"Send to host…", "k"}, {"New key", "n"}, {"Show QR", "q"}}
	for ac, i in acts do ax += ssh_btn(a, cv, S, ax, ay, ac[0], ac[1], i == 0, false, i, 2, H, soft, s.f11b, s.f11) + 6 * S
}

ssh_dump :: proc(a: ^App) -> string {
	s := a.ssh
	sb := strings.builder_make(context.temp_allocator)
	pages := [3]string{"connect", "host", "keys"}
	fmt.sbprintfln(&sb, "ssh %s · %d hosts · sshd %s", pages[s.tab], len(s.hosts), s.run ? "on" : "off")
	switch s.tab {
	case 0:
		sel, _ := ssh_sel(a)
		for h in ssh_list(a) do fmt.sbprintfln(&sb, "%s %s · %s%s", h.id == sel.id ? "*" : " ", h.name, h.group, h.tag != "" ? fmt.tprintf(" · %s", h.tag) : "")
		if s.band != "" do fmt.sbprintfln(&sb, "band %s%s", s.band, s.band_a != "" ? fmt.tprintf(" %s", s.band_a) : "")
	case 1:
		for r, i in ssh_host_rows(s) do fmt.sbprintfln(&sb, "%s %s%s", i == s.hi ? "*" : " ", r.label, s.hask == r.id ? " (asking)" : "")
	case 2:
		for k, i in s.keys do fmt.sbprintfln(&sb, "%s %s · %s", i == s.ki ? "*" : " ", k.name, k.agent ? "in agent" : (k.locked ? "locked" : "not loaded"))
	}
	if s.toast != "" do fmt.sbprintfln(&sb, "toast %s", s.toast)
	return strings.to_string(sb)
}
