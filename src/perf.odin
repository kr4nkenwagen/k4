package k4

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

// --perf: the System popup (the Kestrel design's performance and utilities): 680×560 under the
// bar's performance module, or Super+Shift+Esc. Three pages (Tab, 1–3): Overview — CPU, memory,
// disk and network as big numbers over the last 48 seconds, then a row of sensors; a red line
// names the culprit when memory or CPU runs out (↵ shows it). Processes — the top 12 by CPU or
// memory (← → sorts), typing filters, Del ends one after y / n, ⇧Del kills it. Utilities — the
// script's one-key fixes (k4-perf util-list on stdin's U lines, run with "R ID"; ask = y / n
// first). Everything else is read from /proc and /sys once a second.
//   R <command>: runs "ID [VALUE]", its last line is the footer's message
//   L <command>: the utilities again (sizes after a run)
//   U <column 0|1> <group> <id> <label> <sub> <meta> <flags: ask; step=A|B|C; cur=N; tog=1|0; term>

PERF_W, PERF_H :: 680, 560
PERF_N :: 48 // seconds of history

Perf_Proc :: struct {
	pid: int,
	name, desc, user: string,
	cpu: f32, // % of one core
	mem: f32, // MB resident
	ticks: u64,
}

Perf_Util :: struct {
	col: int,
	group, id, label, sub, meta: string,
	ask, tog, on, term: bool,
	steps: []string,
	cur: int,
	done: string,
}

Perf :: struct {
	tab: int,
	// the machine
	host, os_name, kernel: string,
	cores: int,
	mem_total, swap_total: f32, // GB
	disk: string, // the main block device
	// samples
	cpu, mem_used, mem_cache, swap_used, disk_mbs, net_dn, net_up: f32,
	core_pct: [dynamic]f32,
	hist_cpu, hist_mem, hist_disk, hist_dn, hist_up: [PERF_N]f32,
	n_hist: int,
	prev_total, prev_idle: u64,
	prev_core: [dynamic][2]u64,
	prev_sect: u64,
	prev_rx, prev_tx, boot_rx, boot_tx: u64,
	prev_at: time.Tick,
	ghz, cpu_temp, nvme_temp, gpu_pct, gpu_temp, gpu_fan, gpu_w: f32,
	gpu_ok: bool,
	gpu_at: time.Tick,
	bat: string,
	load: [3]f32,
	uptime: string,
	net_if, net_meta: string,
	fs: [dynamic]Perf_Fs,
	// processes
	procs: [dynamic]Perf_Proc,
	prev_ticks: map[int]u64,
	users: map[int]string,
	n_procs: int,
	sort: int, // 0 cpu, 1 memory, 2 name
	sel_pid, ask_pid: int,
	// utilities
	runner, loader: string,
	utils: [dynamic]Perf_Util,
	ui: int,
	uask: string,
	utils_loaded: bool,
	job, lister: Perf_Job, // the utility running and the list loading, both in the background
	job_id, job_label: string,
	toast: string,
	toast_hot: bool,
	f9, f10, f10b, f11, f11b, f12, f12b, f13b, f24b: ^Font,
}

Perf_Job :: struct {
	proc_: os.Process,
	out: string,
	running: bool,
	at: time.Tick,
}

Perf_Fs :: struct { mount: string, used, total: f32 }

perf_setup :: proc(a: ^App, data: string) {
	p := new(Perf)
	a.perf = p
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	p.f9, p.f10, p.f11, p.f12 = reg(a, 9), reg(a, 10), reg(a, 11), reg(a, 12)
	p.f10b, p.f11b, p.f12b, p.f13b, p.f24b = bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 13), bld(a, 24)
	if !a.opts.popup.set { a.opts.anchor = .Top_Right; a.opts.margin = 10 }
	switch a.opts.open { case "processes", "2": p.tab = 1; case "utilities", "3": p.tab = 2 }
	perf_parse_utils(p, data)
	perf_static(p)
	perf_sample(p)
	if a.opts.dry_run != "" || a.opts.dump { time.sleep(300 * time.Millisecond); perf_sample(p) } // a first rate
	if p.tab == 2 do perf_load_utils(a)
}

// ---------- reading /proc and /sys ----------

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}

@(private = "file")
read_num :: proc(path: string) -> (f32, bool) {
	v, ok := strconv.parse_f32(strings.trim_space(read_text(path)))
	return v, ok
}

@(private = "file")
perf_static :: proc(p: ^Perf) {
	p.host = strings.clone(strings.trim_space(read_text("/etc/hostname")))
	p.kernel = strings.clone(strings.trim_space(read_text("/proc/sys/kernel/osrelease")))
	if i := strings.index_byte(p.kernel, '-'); i > 0 && strings.count(p.kernel, "-") > 1 do p.kernel = p.kernel[:i]
	osr := read_text("/etc/os-release")
	for line in strings.split_lines_iterator(&osr) {
		if strings.has_prefix(line, "NAME=") do p.os_name = strings.clone(strings.trim(line[5:], "\""))
		if strings.has_prefix(line, "VERSION_ID=") do p.os_name = strings.concatenate({p.os_name, " ", strings.trim(line[11:], "\"")})
	}
	if v, err := os.read_link("/etc/os-release", context.temp_allocator); err == nil do _ = v
	// the user names, for the process list
	pw := read_text("/etc/passwd")
	for line in strings.split_lines_iterator(&pw) {
		f := strings.split(line, ":", context.temp_allocator)
		if len(f) > 2 do if uid, ok := strconv.parse_int(f[2]); ok do p.users[uid] = strings.clone(f[0])
	}
	// the main disk: the first nvme or sd device
	ds := read_text("/proc/diskstats")
	for line in strings.split_lines_iterator(&ds) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 3 do continue
		n := f[2]
		if (strings.has_prefix(n, "nvme") && !strings.contains(n, "p")) || (strings.has_prefix(n, "sd") && len(n) == 3) || (strings.has_prefix(n, "vd") && len(n) == 3) { p.disk = strings.clone(n); break }
	}
	// the default route's interface
	rt := read_text("/proc/net/route")
	for line in strings.split_lines_iterator(&rt) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) > 2 && f[1] == "00000000" { p.net_if = strings.clone(f[0]); break }
	}
	if p.net_if != "" {
		if sp, ok := read_num(fmt.tprintf("/sys/class/net/%s/speed", p.net_if)); ok && sp > 0 do p.net_meta = fmt.aprintf("%s · %s", p.net_if, sp >= 1000 ? fmt.tprintf("%.0f Gb/s", sp / 1000) : fmt.tprintf("%.0f Mb/s", sp))
		else do p.net_meta = strings.clone(p.net_if)
	}
	// / and /home (when /home is its own file system)
	for m in ([]string{"/", "/home"}) {
		st: linux.Stat_FS
		if linux.statfs(strings.clone_to_cstring(m, context.temp_allocator), &st) != .NONE do continue
		tot := f32(st.blocks) * f32(st.bsize) / 1e9
		used := f32(st.blocks - st.bfree) * f32(st.bsize) / 1e9
		if m == "/home" && len(p.fs) > 0 && abs(tot - p.fs[0].total) < 0.01 do continue
		append(&p.fs, Perf_Fs{m, used, tot})
	}
}

// One sample: rates since the last one, the history moves on.
perf_sample :: proc(p: ^Perf) {
	now := time.tick_now()
	dt := p.prev_at == {} ? 1.0 : f32(time.duration_seconds(time.tick_diff(p.prev_at, now)))
	if dt <= 0 do dt = 1
	first := p.prev_at == {}
	p.prev_at = now
	// CPU: the whole and each core
	st := read_text("/proc/stat")
	ci := 0
	for line in strings.split_lines_iterator(&st) {
		if !strings.has_prefix(line, "cpu") do break
		f := strings.fields(line, context.temp_allocator)
		total, idle: u64
		for v, i in f[1:] {
			n, _ := strconv.parse_u64(v)
			total += n
			if i == 3 || i == 4 do idle += n
		}
		if f[0] == "cpu" {
			if !first && total > p.prev_total do p.cpu = 100 * (1 - f32(idle - p.prev_idle) / f32(total - p.prev_total))
			p.prev_total, p.prev_idle = total, idle
		} else {
			if ci >= len(p.prev_core) { append(&p.prev_core, [2]u64{}); append(&p.core_pct, 0) }
			pc := p.prev_core[ci]
			if !first && total > pc[0] do p.core_pct[ci] = 100 * (1 - f32(idle - pc[1]) / f32(total - pc[0]))
			p.prev_core[ci] = {total, idle}
			ci += 1
		}
	}
	p.cores = ci
	// memory
	mi := read_text("/proc/meminfo")
	mem: map[string]f32
	mem.allocator = context.temp_allocator
	for line in strings.split_lines_iterator(&mi) {
		i := strings.index_byte(line, ':')
		if i < 0 do continue
		f := strings.fields(line[i + 1:], context.temp_allocator)
		if len(f) > 0 do if v, ok := strconv.parse_f32(f[0]); ok do mem[line[:i]] = v / 1048576 // kB → GB
	}
	p.mem_total, p.swap_total = mem["MemTotal"], mem["SwapTotal"]
	p.mem_cache = mem["Buffers"] + mem["Cached"] + mem["SReclaimable"] - mem["Shmem"]
	p.mem_used = p.mem_total - mem["MemAvailable"]
	p.swap_used = p.swap_total - mem["SwapFree"]
	// disk: sectors read and written by the main device
	ds := read_text("/proc/diskstats")
	for line in strings.split_lines_iterator(&ds) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) > 9 && f[2] == p.disk {
			r, _ := strconv.parse_u64(f[5]); w, _ := strconv.parse_u64(f[9])
			if !first do p.disk_mbs = f32(r + w - p.prev_sect) * 512 / 1e6 / dt
			p.prev_sect = r + w
		}
	}
	// network: every interface but lo
	nd := read_text("/proc/net/dev")
	rx, tx: u64
	for line in strings.split_lines_iterator(&nd) {
		i := strings.index_byte(line, ':')
		if i < 0 do continue
		name := strings.trim_space(line[:i])
		if name == "lo" do continue
		f := strings.fields(line[i + 1:], context.temp_allocator)
		if len(f) > 8 { a, _ := strconv.parse_u64(f[0]); b, _ := strconv.parse_u64(f[8]); rx += a; tx += b }
	}
	if !first { p.net_dn = f32(rx - p.prev_rx) / 1e6 / dt; p.net_up = f32(tx - p.prev_tx) / 1e6 / dt }
	p.prev_rx, p.prev_tx = rx, tx
	p.boot_rx, p.boot_tx = rx, tx
	// the clock speed, temperatures, load, uptime, battery
	ci2 := read_text("/proc/cpuinfo")
	sum: f32
	n: int
	for line in strings.split_lines_iterator(&ci2) {
		if strings.has_prefix(line, "cpu MHz") {
			if i := strings.index_byte(line, ':'); i > 0 do if v, ok := strconv.parse_f32(strings.trim_space(line[i + 1:])); ok { sum += v; n += 1 }
		}
	}
	if n > 0 do p.ghz = sum / f32(n) / 1000
	for i in 0 ..< 12 {
		base := fmt.tprintf("/sys/class/hwmon/hwmon%d", i)
		name := strings.trim_space(read_text(strings.concatenate({base, "/name"}, context.temp_allocator)))
		if name == "" do continue
		t, ok := read_num(strings.concatenate({base, "/temp1_input"}, context.temp_allocator))
		if !ok do continue
		switch name {
		case "k10temp", "coretemp", "zenpower", "cpu_thermal": p.cpu_temp = t / 1000
		case "nvme": p.nvme_temp = t / 1000
		}
	}
	la := strings.fields(read_text("/proc/loadavg"), context.temp_allocator)
	for i in 0 ..< min(3, len(la)) do p.load[i], _ = strconv.parse_f32(la[i])
	up, _ := strconv.parse_f32(strings.fields(read_text("/proc/uptime"), context.temp_allocator)[0])
	s := int(up)
	delete(p.uptime)
	p.uptime = s >= 86400 ? fmt.aprintf("up %d d %d h", s / 86400, s % 86400 / 3600) : (s >= 3600 ? fmt.aprintf("up %d h %d min", s / 3600, s % 3600 / 60) : fmt.aprintf("up %d min", s / 60))
	delete(p.bat)
	p.bat = ""
	for b in ([]string{"BAT0", "BAT1"}) {
		if c, ok := read_num(fmt.tprintf("/sys/class/power_supply/%s/capacity", b)); ok { p.bat = fmt.aprintf("%.0f%%", c); break }
	}
	// the GPU (NVIDIA), every few seconds: nvidia-smi takes a while
	if time.tick_diff(p.gpu_at, now) > 3 * time.Second || p.gpu_at == {} {
		p.gpu_at = now
		if _, out, _, err := os.process_exec({command = {"nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu,fan.speed,power.draw", "--format=csv,noheader,nounits"}}, context.temp_allocator); err == nil {
			f := strings.split(strings.trim_space(string(out)), ",", context.temp_allocator)
			if len(f) >= 4 {
				p.gpu_ok = true
				p.gpu_pct, _ = strconv.parse_f32(strings.trim_space(f[0])); p.gpu_temp, _ = strconv.parse_f32(strings.trim_space(f[1]))
				p.gpu_fan, _ = strconv.parse_f32(strings.trim_space(f[2])); p.gpu_w, _ = strconv.parse_f32(strings.trim_space(f[3]))
			}
		}
	}
	// the history
	if !first {
		push :: proc(h: ^[PERF_N]f32, v: f32) { copy(h[:PERF_N - 1], h[1:]); h[PERF_N - 1] = v }
		push(&p.hist_cpu, p.cpu); push(&p.hist_mem, p.mem_used); push(&p.hist_disk, p.disk_mbs)
		push(&p.hist_dn, p.net_dn); push(&p.hist_up, p.net_up)
		p.n_hist = min(p.n_hist + 1, PERF_N)
	}
	perf_procs(p, dt, first)
}

@(private = "file")
perf_procs :: proc(p: ^Perf, dt: f32, first: bool) {
	for x in p.procs { delete(x.name); delete(x.desc) }
	clear(&p.procs)
	seen := make(map[int]u64, 256, context.temp_allocator)
	h, err := os.open("/proc")
	if err != nil do return
	defer os.close(h)
	ents, _ := os.read_dir(h, -1, context.temp_allocator)
	page := f32(4096) / 1048576
	for e in ents {
		pid, ok := strconv.parse_int(e.name)
		if !ok do continue
		st := read_text(fmt.tprintf("/proc/%d/stat", pid))
		l, r := strings.index_byte(st, '('), strings.last_index_byte(st, ')')
		if l < 0 || r < l do continue
		f := strings.fields(st[r + 1:], context.temp_allocator) // f[0] = state (field 3)
		if len(f) < 22 do continue
		ut, _ := strconv.parse_u64(f[11]); stt, _ := strconv.parse_u64(f[12])
		rss, _ := strconv.parse_f32(f[21])
		if rss == 0 do continue // kernel threads
		ticks := ut + stt
		seen[pid] = ticks
		x := Perf_Proc{pid = pid, name = strings.clone(st[l + 1:r]), mem = rss * page, ticks = ticks}
		if prev, had := p.prev_ticks[pid]; had && !first do x.cpu = f32(ticks - prev) / dt // CLK_TCK is 100: ticks a second = %
		// what it is about: its first argument that is not an option, as a file name
		cl := read_text(fmt.tprintf("/proc/%d/cmdline", pid))
		args := strings.split(cl, "\x00", context.temp_allocator)
		for arg in args[1:] {
			if arg == "" || arg[0] == '-' do continue
			b := arg
			if i := strings.last_index_byte(b, '/'); i >= 0 && i < len(b) - 1 do b = b[i + 1:]
			x.desc = strings.clone(len(b) > 28 ? b[:28] : b)
			break
		}
		stat_s := read_text(fmt.tprintf("/proc/%d/status", pid))
		if i := strings.index(stat_s, "Uid:"); i >= 0 {
			uf := strings.fields(stat_s[i + 4:], context.temp_allocator)
			if len(uf) > 0 do if uid, ok2 := strconv.parse_int(uf[0]); ok2 do x.user = p.users[uid] or_else fmt.aprint(uid)
		}
		append(&p.procs, x)
	}
	p.n_procs = len(ents)
	clear(&p.prev_ticks)
	for k, v in seen do p.prev_ticks[k] = v
}

// The processes on show: filtered, sorted, twelve.
@(private = "file")
perf_shown :: proc(a: ^App) -> []Perf_Proc {
	p := a.perf
	q := strings.to_lower(strings.trim_space(string(a.query[:])), context.temp_allocator)
	out := make([dynamic]Perf_Proc, 0, len(p.procs), context.temp_allocator)
	for x in p.procs {
		if q != "" && !strings.contains(strings.to_lower(x.name, context.temp_allocator), q) && !strings.contains(strings.to_lower(x.desc, context.temp_allocator), q) && !strings.contains(fmt.tprint(x.pid), q) do continue
		append(&out, x)
	}
	switch p.sort {
	case 1: slice.sort_by(out[:], proc(x, y: Perf_Proc) -> bool { return x.mem > y.mem })
	case 2: slice.sort_by(out[:], proc(x, y: Perf_Proc) -> bool { return strings.to_lower(x.name, context.temp_allocator) < strings.to_lower(y.name, context.temp_allocator) })
	case: slice.sort_by(out[:], proc(x, y: Perf_Proc) -> bool { return x.cpu != y.cpu ? x.cpu > y.cpu : x.mem > y.mem })
	}
	return out[:min(12, len(out))]
}

@(private = "file")
perf_mem_str :: proc(mb: f32) -> string { return mb >= 1000 ? fmt.tprintf("%.1f GB", mb / 1024) : fmt.tprintf("%.0f MB", mb) }

// What is wrong, if anything: memory or CPU near the top, and who is behind it.
@(private = "file")
perf_warn :: proc(p: ^Perf) -> (title, sub: string, culprit: int) {
	mem_pct := p.mem_total > 0 ? p.mem_used / p.mem_total * 100 : 0
	if mem_pct < 90 && p.cpu < 90 do return
	top := -1
	for x, i in p.procs do if top < 0 || (mem_pct >= 90 ? x.mem > p.procs[top].mem : x.cpu > p.procs[top].cpu) do top = i
	parts := make([dynamic]string, 0, 2, context.temp_allocator)
	if mem_pct >= 90 do append(&parts, "Memory almost full")
	if p.cpu >= 90 do append(&parts, fmt.tprintf("CPU at %.0f%%", p.cpu))
	title = strings.join(parts[:], " · ", context.temp_allocator)
	if top >= 0 {
		x := p.procs[top]
		sub = fmt.tprintf("%s uses %s and %.0f%% CPU%s", x.name, perf_mem_str(x.mem), x.cpu, p.swap_used > 0.5 ? " · swap is filling" : "")
		culprit = x.pid
	}
	return
}

// ---------- the utilities (the script) ----------

@(private = "file")
perf_parse_utils :: proc(p: ^Perf, data: string) {
	clear(&p.utils)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		get :: proc(f: []string, i: int) -> string { return i < len(f) ? strings.clone(f[i]) : "" }
		switch f[0] {
		case "R": p.runner = get(f, 1)
		case "L": p.loader = get(f, 1)
		case "U":
			u := Perf_Util{group = get(f, 2), id = get(f, 3), label = get(f, 4), sub = get(f, 5), meta = get(f, 6)}
			u.col, _ = strconv.parse_int(get(f, 1))
			for fl in strings.split(get(f, 7), ";", context.temp_allocator) {
				switch {
				case fl == "ask": u.ask = true
				case fl == "term": u.term = true
				case strings.has_prefix(fl, "step="): u.steps = strings.split(strings.clone(fl[5:]), "|")
				case strings.has_prefix(fl, "cur="): u.cur, _ = strconv.parse_int(fl[4:])
				case strings.has_prefix(fl, "tog="): u.tog, u.on = true, fl[4:] == "1"
				}
			}
			append(&p.utils, u)
			p.utils_loaded = true
		}
	}
}

// The list (and its sizes) loads in the background; a window that renders once loads it at once.
@(private = "file")
perf_load_utils :: proc(a: ^App) {
	p := a.perf
	if p.loader == "" || p.utils_loaded || p.lister.running do return
	if a.opts.dry_run != "" || a.opts.dump {
		_, out, _, err := os.process_exec({command = {"sh", "-c", p.loader}}, context.temp_allocator)
		if err == nil do perf_parse_utils(p, string(out))
		p.utils_loaded = true
		return
	}
	perf_job_start(&p.lister, p.loader, "list")
}

@(private = "file")
perf_job_start :: proc(j: ^Perf_Job, cmd, tag: string) -> bool {
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	delete(j.out)
	j.out = fmt.aprintf("%s/k4-perf-%s-%d.out", run != "" ? run : "/tmp", tag, os.get_pid())
	pr, err := os.process_start({command = {"sh", "-c", fmt.tprintf("exec %s > %s 2>&1", cmd, sh_quote(j.out))}})
	if err != nil do return false
	j.proc_, j.running, j.at = pr, true, time.tick_now()
	return true
}

// What the job printed so far, and whether it just finished.
@(private = "file")
perf_job_poll :: proc(j: ^Perf_Job) -> (text: string, done: bool) {
	if data, err := os.read_entire_file(j.out, context.temp_allocator); err == nil do text = string(data)
	if !j.running do return
	if st, _ := os.process_wait(j.proc_, 0); st.exited {
		j.running, done = false, true
		_ = os.remove(j.out)
	}
	return
}

// The last line a job printed: its progress while it runs, its result when done.
@(private = "file")
perf_last_line :: proc(text: string) -> string {
	lines := strings.split_lines(strings.trim_space(text), context.temp_allocator)
	l := len(lines) > 0 ? lines[len(lines) - 1] : ""
	if i := strings.last_index_byte(l, '\r'); i >= 0 do l = l[i + 1:] // a progress bar redrawn in place
	return strings.trim_space(l)
}

// Once a second the numbers; more often while a utility runs, for its progress line.
perf_tick :: proc(a: ^App) {
	p := a.perf
	if time.duration_seconds(time.tick_diff(p.prev_at, time.tick_now())) >= 0.95 do perf_sample(p)
	if p.lister.running {
		if text, done := perf_job_poll(&p.lister); done {
			keep := p.ui
			clear(&p.utils)
			perf_parse_utils(p, text)
			p.utils_loaded = true
			p.ui = min(keep, max(len(p.utils) - 1, 0))
			for &v in p.utils do if v.id == p.job_id && p.toast != "" && !v.tog && len(v.steps) == 0 do v.done = strings.clone(p.toast)
		}
	}
	if p.job.running {
		text, done := perf_job_poll(&p.job)
		if !done do return
		msg := perf_last_line(text)
		if msg == "k4:close" { a.exit = 0; a.done = true; return } // it opened a terminal or picks a window
		p.toast = strings.clone(msg)
		p.toast_hot = false
		for &u in p.utils do if u.id == p.job_id && !u.tog && len(u.steps) == 0 {
			u.done = strings.clone(msg)
			p.utils_loaded = false
			perf_load_utils(a) // the sizes again
		}
	}
}

perf_tick_ms :: proc(a: ^App) -> int { return a.perf.job.running || a.perf.lister.running ? 150 : 1000 }

// The row's line while its utility runs: what it last printed, and for how long.
@(private = "file")
perf_job_line :: proc(p: ^Perf) -> string {
	text, _ := os.read_entire_file(p.job.out, context.temp_allocator)
	l := perf_last_line(string(text))
	secs := int(time.duration_seconds(time.tick_diff(p.job.at, time.tick_now())))
	return fmt.tprintf("%s · %d:%02d", l != "" ? l : "Running…", secs / 60, secs % 60)
}

// The utilities in reading order: the left column, then the right.
@(private = "file")
perf_util_order :: proc(p: ^Perf) -> []int {
	out := make([dynamic]int, 0, len(p.utils), context.temp_allocator)
	for c in 0 ..< 2 do for u, i in p.utils do if u.col == c do append(&out, i)
	return out[:]
}

@(private = "file")
perf_run_util :: proc(a: ^App, confirmed: bool) {
	p := a.perf
	order := perf_util_order(p)
	if p.ui >= len(order) do return
	u := &p.utils[order[p.ui]]
	if p.job.running && p.runner != "" {
		p.toast = fmt.aprintf("%s is still running · this one waits", p.job_label)
		p.toast_hot = true
		return
	}
	if u.ask && !confirmed && p.uask != u.id { p.uask = u.id; p.toast = ""; return }
	p.uask = ""
	arg := ""
	if len(u.steps) > 0 { u.cur = (u.cur + 1) % len(u.steps); arg = u.steps[u.cur] }
	if u.tog { u.on = !u.on; arg = u.on ? "on" : "off" }
	if p.runner == "" { p.toast = fmt.aprintf("(%s%s%s)", u.id, arg != "" ? " " : "", arg); return } // tests
	delete(p.job_id); delete(p.job_label)
	p.job_id, p.job_label = strings.clone(u.id), strings.clone(u.label)
	u.done = ""
	p.toast = ""
	perf_job_start(&p.job, fmt.tprintf("%s %s %s", p.runner, sh_quote(u.id), sh_quote(arg)), "run") // perf_tick reads the result
}

// ---------- keys and the pointer ----------

@(private = "file")
perf_sel :: proc(a: ^App) -> (Perf_Proc, int, bool) {
	p := a.perf
	shown := perf_shown(a)
	for x, i in shown do if x.pid == p.sel_pid do return x, i, true
	if len(shown) > 0 do return shown[0], 0, true
	return {}, -1, false
}

@(private = "file")
perf_kill :: proc(a: ^App, force: bool) {
	p := a.perf
	x, _, ok := perf_sel(a)
	if !ok do return
	if !force && p.ask_pid != x.pid { p.ask_pid = x.pid; p.sel_pid = x.pid; p.toast = ""; return }
	p.ask_pid = 0
	if os.get_env("K4_PERF_NOKILL", context.temp_allocator) == "" do linux.kill(linux.Pid(x.pid), force ? .SIGKILL : .SIGTERM)
	p.toast = fmt.aprintf("%s %s (%d) · %s", force ? "Killed" : "Ended", x.name, x.pid, force ? "SIGKILL" : "SIGTERM")
	p.toast_hot = true
}

@(private = "file")
perf_btop :: proc(a: ^App) {
	if a.perf.runner == "" { a.perf.toast = "(btop)"; return }
	_, _ = os.process_start({command = {"setsid", "-f", "sh", "-c", fmt.tprintf("%s btop", a.perf.runner)}}) // the window goes at once; btop opens behind it
	a.exit = 0; a.done = true
}

perf_key :: proc(a: ^App, k: Key, ctrl: bool, ch: rune, text: string) -> bool {
	p := a.perf
	if k == .Tab || k == .Back_Tab { p.tab = (p.tab + (k == .Tab ? 1 : 2)) % 3; p.toast = ""; if p.tab == 2 do perf_load_utils(a); return true }
	if ctrl && (ch == 'c' || ch == 'g') { a.exit = 1; a.done = true; return true }
	if p.tab != 1 && (text == "1" || text == "2" || text == "3") { p.tab = int(text[0] - '1'); p.toast = ""; if p.tab == 2 do perf_load_utils(a); return true }
	switch p.tab {
	case 0:
		switch {
		case k == .Enter:
			if _, _, pid := perf_warn(p); pid > 0 { p.tab, p.sort, p.sel_pid = 1, 0, pid }
		case k == .Escape: a.exit = 1; a.done = true
		case: return false
		}
	case 1:
		if p.ask_pid > 0 {
			switch {
			case text == "y" || k == .Enter: perf_kill(a, false)
			case text == "n" || k == .Escape: p.ask_pid = 0
			}
			return true
		}
		shown := perf_shown(a)
		_, cur, _ := perf_sel(a)
		switch {
		case k == .Down: if cur + 1 < len(shown) do p.sel_pid, p.toast = shown[cur + 1].pid, ""
		case k == .Up: if cur > 0 do p.sel_pid, p.toast = shown[cur - 1].pid, ""
		case k == .Right: p.sort = (p.sort + 1) % 3
		case k == .Left: p.sort = (p.sort + 2) % 3
		case k == .Delete: perf_kill(a, a.shift)
		case k == .Enter: perf_btop(a)
		case k == .Escape:
			if len(a.query) > 0 { clear(&a.query); a.cursor = 0 } else { a.exit = 1; a.done = true }
		case: return app_edit_key(a, k, ctrl, ch, text)
		}
	case 2:
		order := perf_util_order(p)
		if p.uask != "" {
			switch {
			case text == "y" || k == .Enter: perf_run_util(a, true)
			case text == "n" || k == .Escape: p.uask = ""
			}
			return true
		}
		left := 0
		for i in order do if p.utils[i].col == 0 do left += 1
		switch {
		case k == .Down: p.ui, p.toast = min(p.ui + 1, max(len(order) - 1, 0)), ""
		case k == .Up: p.ui, p.toast = max(p.ui - 1, 0), ""
		case k == .Right || k == .Left:
			if p.ui < len(order) && len(p.utils[order[p.ui]].steps) > 0 { // a step row: the value
				u := &p.utils[order[p.ui]]
				u.cur = clamp(u.cur + (k == .Right ? 1 : -1) - 1, -1, len(u.steps) - 2) // run moves it one on
				perf_run_util(a, true)
			} else if k == .Right && p.ui < left do p.ui = min(left + p.ui, len(order) - 1)
			else if k == .Left && p.ui >= left do p.ui = min(p.ui - left, left - 1)
		case k == .Enter || text == " ": perf_run_util(a, false)
		case k == .Escape: a.exit = 1; a.done = true
		case: return false
		}
	}
	return true
}

perf_click :: proc(a: ^App, x, y, button: int) -> bool {
	p := a.perf
	h, ok := hit_at(a, x, y)
	if !ok { a.exit = 1; a.done = true; return true }
	#partial switch h.kind {
	case .Tab: p.tab = h.a; p.toast = ""; if p.tab == 2 do perf_load_utils(a)
	case .Section: p.tab = h.b; p.sort = h.a // a card: its page
	case .Row: // a process
		if p.sel_pid == h.a && p.ask_pid == 0 do perf_btop(a)
		else do p.sel_pid, p.ask_pid, p.toast = h.a, 0, ""
	case .Chip: // the process bar's buttons
		switch h.a {
		case 0: perf_kill(a, false)
		case 1: perf_kill(a, true)
		case 2: perf_btop(a)
		case 3: p.ask_pid = 0
		}
	case .Result: p.sort = h.a // a column
	case .Item: // a utility
		if p.ui == h.a do perf_run_util(a, false)
		else do p.ui, p.uask, p.toast = h.a, "", ""
	case .Confirm: if _, _, pid := perf_warn(p); pid > 0 { p.tab, p.sort, p.sel_pid = 1, 0, pid }
	}
	return true
}

// ---------- drawing ----------

perf_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	p := a.perf
	t := a.theme
	H := hud(t)
	soft := mix(H.fg, H.bg, 0.2)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	fill_rect(cv, 0, 0, w, h, argb(H.bg, a.bg_alpha))
	// the head: SYSTEM · host · up, OS, kernel · load · live
	hh := 40 * S
	cw := tw(p.f11b, "SYSTEM") + 12 * S
	fill_rect(cv, 12 * S, (hh - 20 * S) / 2, cw, 20 * S, argb(H.acc, 0xff))
	text_in(cv, p.f11b, "SYSTEM", 18 * S, (hh - 20 * S) / 2, 20 * S, argb(H.bg, 0xff))
	hx := 12 * S + cw + 10 * S
	text_in(cv, p.f13b, p.host, hx, 0, hh, argb(H.fg, 0xff))
	hx += tw(p.f13b, p.host) + 10 * S
	right := w - 12 * S
	fill_rect(cv, right - 6 * S, (hh - 6 * S) / 2, 6 * S, 6 * S, argb(t.green, 0xff))
	right -= 6 * S + 10 * S
	ld := fmt.tprintf("load %.2f  %.2f  %.2f", p.load[0], p.load[1], p.load[2])
	text_in(cv, p.f10, ld, right - tw(p.f10, ld), 0, hh, argb(p.load[0] > f32(max(p.cores, 1)) * 0.7 ? t.yellow : H.dim, 0xff))
	right -= tw(p.f10, ld) + 10 * S
	info := fmt.tprintf("%s · %s · %s", p.uptime, p.os_name, p.kernel)
	text_in(cv, p.f10, ellipsize(p.f10, info, right - hx), hx, 0, hh, argb(H.dim, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	// the pages
	ty, th := hh + S, 36 * S
	tx := 12 * S
	warn, _, _ := perf_warn(p)
	for l, i in ([3]string{"OVERVIEW", "PROCESSES", "UTILITIES"}) {
		on := i == p.tab
		k := fmt.tprint(i + 1)
		bw := spaced_w(p.f11b, l, S) + 7 * S + tw(p.f10, k) + 24 * S
		spaced(cv, p.f11b, l, tx + 12 * S, ty, th, on ? H.fg : H.dim, S)
		text_in(cv, p.f10, k, tx + 12 * S + spaced_w(p.f11b, l, S) + 7 * S, ty, th, argb(H.faint, 0xff))
		if i == 0 && warn != "" do text_in(cv, p.f10b, "!", tx + bw - 8 * S, ty, th, argb(H.hot, 0xff))
		if on do fill_rect(cv, tx, ty + th - 2 * S, bw, 2 * S, argb(H.acc, 0xff))
		hit_add(a, tx, ty, bw, th, .Tab, i, 0)
		tx += bw + 2 * S
	}
	note: string
	switch p.tab {
	case 0: note = "live · 1 s"
	case 1: note = fmt.tprintf("%d processes", len(p.procs))
	case 2: note = "one key each"
	}
	text_in(cv, p.f10, note, w - 12 * S - tw(p.f10, note), ty, th, argb(H.dim, 0xff))
	fill_rect(cv, 0, ty + th, w, S, argb(H.line, 0xff))
	top := ty + th + S
	fh := 30 * S
	fy := h - fh
	switch p.tab {
	case 0: perf_draw_overview(a, cv, S, top, fy, H, soft)
	case 1: perf_draw_procs(a, cv, S, top, fy, H, soft)
	case 2: perf_draw_utils(a, cv, S, top, fy, H, soft)
	}
	// the foot
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	if p.toast != "" do text_in(cv, p.f10, ellipsize(p.f10, p.toast, w - 24 * S), 12 * S, fy, fh, argb(p.toast_hot ? H.hot : H.acc, 0xff))
	else {
		HK: [][2]string
		switch p.tab {
		case 0: HK = {{"Tab 1–3", "Pages"}, {"↵", warn != "" ? "Show culprit" : "Click a card"}, {"Esc", "Close"}}
		case 1: HK = {{"↑↓", "Move"}, {"← →", "Sort"}, {"Del", "End"}, {"⇧Del", "Kill"}, {"Esc", "Close"}}
		case: HK = {{"↑↓ ← →", "Move"}, {"↵", "Run"}, {"y n", "Confirm"}, {"Esc", "Close"}}
		}
		kx := 12 * S
		for k in HK {
			kw := tw(p.f10, k[0]) + 8 * S
			fill_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, argb(t.selection, 0xff))
			text_in(cv, p.f10, k[0], kx + 4 * S, fy, fh, argb(H.fg, 0xff))
			kx += kw + 5 * S
			text_in(cv, p.f10, k[1], kx, fy, fh, argb(H.dim, 0xff))
			kx += tw(p.f10, k[1]) + 12 * S
		}
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
}

@(private = "file")
perf_sev :: proc(v, warn, crit: f32, H: HUD, t_yellow: u32) -> u32 { return v >= crit ? H.hot : (v >= warn ? t_yellow : H.fg) }

@(private = "file")
perf_draw_overview :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32) {
	p := a.perf
	t := a.theme
	w := cv.w
	y := top + 12 * S
	if warn, sub, _ := perf_warn(p); warn != "" { // the red line that names the culprit
		bh := 34 * S
		fill_rect(cv, 12 * S, y, w - 24 * S, bh, argb(H.hot, 0x12))
		rounded_rect(cv, 12 * S, y, w - 24 * S, bh, 0, 0, f32(S), argb(H.hot, 0xff))
		fill_rect(cv, 12 * S, y, 3 * S, bh, argb(H.hot, 0xff))
		text_in(cv, p.f11b, warn, 24 * S, y, bh, argb(H.hot, 0xff))
		sw := tw(p.f10b, "Show ↵")
		text_in(cv, p.f10b, "Show ↵", w - 24 * S - sw, y, bh, argb(H.hot, 0xff))
		sx := 24 * S + tw(p.f11b, warn) + 10 * S
		text_in(cv, p.f10, ellipsize(p.f10, sub, w - 36 * S - sw - sx), sx, y, bh, argb(soft, 0xff))
		hit_add(a, 12 * S, y, w - 24 * S, bh, .Confirm, 0, 0)
		y += bh + 10 * S
	}
	sensors_h := 32 * S
	gy := y
	gh := fy - 12 * S - sensors_h - 10 * S - gy
	cw := (w - 24 * S - 10 * S) / 2
	ch := (gh - 10 * S) / 2
	mem_pct := p.mem_total > 0 ? p.mem_used / p.mem_total * 100 : 0
	cpu_c := perf_sev(p.cpu, 70, 90, H, t.yellow)
	mem_c := perf_sev(mem_pct, 80, 90, H, t.yellow)
	// the cards: CPU, memory, disk, network
	for i in 0 ..< 4 {
		cx := 12 * S + (i % 2) * (cw + 10 * S)
		cy := gy + (i / 2) * (ch + 10 * S)
		fill_rect(cv, cx, cy, cw, ch, argb(t.fg, 0x0a))
		rounded_rect(cv, cx, cy, cw, ch, 0, 0, f32(S), argb(H.line, 0xff))
		title, meta, big, unit: string
		big_c := H.fg
		hist: []f32
		hmax: f32 = 100
		hist2: []f32
		col := H.acc
		switch i {
		case 0:
			title, big, unit, big_c = "CPU", fmt.tprintf("%.0f%%", p.cpu), "avg over 1 s", cpu_c
			meta = fmt.tprintf("%d threads · %.1f GHz%s", p.cores, p.ghz, p.cpu_temp > 0 ? fmt.tprintf(" · %.0f°C", p.cpu_temp) : "")
			hist = p.hist_cpu[:]
			if cpu_c != H.fg do col = cpu_c
		case 1:
			title, big, unit, big_c = "MEMORY", fmt.tprintf("%.1f GB", p.mem_used), fmt.tprintf("in use · %.0f%%", mem_pct), mem_c
			meta = fmt.tprintf("%.0f GB%s", p.mem_total, p.swap_total > 0 ? fmt.tprintf(" · swap %.1f / %.0f GB", p.swap_used, p.swap_total) : "")
			hist, hmax = p.hist_mem[:], max(p.mem_total, 1)
			if mem_c != H.fg do col = mem_c
		case 2:
			title, big, unit = "DISK", fmt.tprintf("%.0f", p.disk_mbs), "MB/s read + write"
			meta = fmt.tprintf("%s%s", p.disk, p.nvme_temp > 0 ? fmt.tprintf(" · %.0f°C", p.nvme_temp) : "")
			hist = p.hist_disk[:]
			hmax = 1
			for v in p.hist_disk do hmax = max(hmax, v)
		case 3:
			title, big, unit = "NETWORK", fmt.tprintf("↓ %.1f", p.net_dn), p.net_up >= 1 ? fmt.tprintf("MB/s · ↑ %.1f MB/s", p.net_up) : fmt.tprintf("MB/s · ↑ %.0f KB/s", p.net_up * 1000)
			meta = p.net_meta
			hist, hist2 = p.hist_dn[:], p.hist_up[:]
			hmax = 1
			for v in p.hist_dn do hmax = max(hmax, v)
		}
		hit_add(a, cx, cy, cw, ch, .Section, i == 1 ? 1 : 0, i == 2 ? 2 : (i == 3 ? 0 : 1))
		yy := cy + 10 * S
		spaced(cv, p.f10b, title, cx + 12 * S, yy, int(p.f10b.line_h), H.dim, S)
		text_in(cv, p.f10, ellipsize(p.f10, meta, cw - 30 * S - spaced_w(p.f10b, title, S)), cx + cw - 12 * S - min(tw(p.f10, meta), cw - 30 * S - spaced_w(p.f10b, title, S)), yy, int(p.f10b.line_h), argb(H.dim, 0xff))
		yy += int(p.f10b.line_h) + 8 * S
		text_in(cv, p.f24b, big, cx + 12 * S, yy, int(p.f24b.line_h), argb(big_c, 0xff))
		text_in(cv, p.f11, unit, cx + 12 * S + tw(p.f24b, big) + 8 * S, yy + int(p.f24b.line_h) - int(p.f11.line_h) - 2 * S, int(p.f11.line_h), argb(soft, 0xff))
		yy += int(p.f24b.line_h) + 8 * S
		// the bars under the sparkline
		Bar :: struct { l, v: string, w1, w2: f32, c1, c2, vc: u32 }
		bars := make([dynamic]Bar, 0, 3, context.temp_allocator)
		switch i {
		case 0:
			sb := strings.builder_make(context.temp_allocator)
			busiest, bi: f32 = 0, 0
			for c, k in p.core_pct {
				strings.write_string(&sb, c >= 90 ? "█" : (c >= 60 ? "▆" : (c >= 30 ? "▄" : "▂")))
				if c > busiest do busiest, bi = c, f32(k)
			}
			append(&bars, Bar{l = "cores", v = strings.to_string(sb), vc = H.acc})
			append(&bars, Bar{l = "busiest", w1 = busiest / 100, c1 = H.acc, v = fmt.tprintf("core %.0f · %.0f%%", bi + 1, busiest), vc = soft})
		case 1:
			append(&bars, Bar{l = "apps · cache", w1 = p.mem_used / max(p.mem_total, 1), c1 = col, w2 = max(p.mem_cache, 0) / max(p.mem_total, 1), c2 = mix(H.bg, H.acc, 0.3), v = fmt.tprintf("%.1f GB cache", p.mem_cache), vc = soft})
		case 2:
			for f in p.fs {
				pct := f.used / max(f.total, 1)
				c := pct >= 0.9 ? H.hot : (pct >= 0.8 ? t.yellow : H.acc)
				append(&bars, Bar{l = f.mount, w1 = pct, c1 = c, v = fmt.tprintf("%.0f / %.0f GB", f.used, f.total), vc = pct >= 0.8 ? c : soft})
			}
		case 3:
			append(&bars, Bar{l = "since boot", v = fmt.tprintf("↓ %s  ↑ %s", perf_mem_str(f32(p.boot_rx) / 1048576), perf_mem_str(f32(p.boot_tx) / 1048576)), vc = soft})
		}
		bars_h := len(bars) * (int(p.f10.line_h) + 4 * S)
		sh := cy + ch - 10 * S - bars_h - 6 * S - yy
		// the sparkline: the last 48 seconds, a second series inside the first
		if sh > 6 * S {
			bw := f32(cw - 24 * S - (PERF_N - 1) * S) / PERF_N
			for k in 0 ..< PERF_N {
				v := clamp(hist[k] / hmax, 0, 1)
				bx := cx + 12 * S + int(f32(k) * (bw + f32(S)))
				bh := max(int(v * f32(sh)), k >= PERF_N - p.n_hist ? S : 0)
				fill_rect(cv, bx, yy + sh - bh, max(int(bw), 1), bh, argb(col, 0xff))
				if hist2 != nil {
					v2 := clamp(hist2[k] / hmax, 0, v)
					fill_rect(cv, bx, yy + sh - bh, max(int(bw), 1), int(v2 * f32(sh)), argb(t.magenta, 0xff))
				}
			}
			fill_rect(cv, cx + 12 * S, yy + sh, cw - 24 * S, S, argb(H.line, 0xff))
		}
		by := cy + ch - 10 * S - bars_h
		for b in bars {
			lh := int(p.f10.line_h)
			text_in(cv, p.f10, b.l, cx + 12 * S, by, lh, argb(H.dim, 0xff))
			vw := min(tw(p.f10, b.v), cw - 24 * S - 70 * S)
			text_in(cv, p.f10, ellipsize(p.f10, b.v, cw - 24 * S - 70 * S), cx + cw - 12 * S - vw, by, lh, argb(b.vc, 0xff))
			if b.c1 != 0 {
				tx0, tx1 := cx + 12 * S + 70 * S, cx + cw - 12 * S - vw - 8 * S
				if tx1 > tx0 {
					fill_rect(cv, tx0, by + (lh - 5 * S) / 2, tx1 - tx0, 5 * S, argb(H.line, 0xff))
					w1 := int(clamp(b.w1, 0, 1) * f32(tx1 - tx0))
					fill_rect(cv, tx0, by + (lh - 5 * S) / 2, w1, 5 * S, argb(b.c1, 0xff))
					if b.c2 != 0 do fill_rect(cv, tx0 + w1, by + (lh - 5 * S) / 2, min(int(clamp(b.w2, 0, 1) * f32(tx1 - tx0)), tx1 - tx0 - w1), 5 * S, argb(b.c2, 0xff))
				}
			}
			by += lh + 4 * S
		}
	}
	// the sensors
	sy := fy - 12 * S - sensors_h
	rounded_rect(cv, 12 * S, sy, w - 24 * S, sensors_h, 0, 0, f32(S), argb(H.line, 0xff))
	sens := make([dynamic][3]string, 0, 6, context.temp_allocator) // label, value, warn level
	if p.gpu_ok do append(&sens, [3]string{"GPU", fmt.tprintf("%.0f%%", p.gpu_pct), ""})
	if p.cpu_temp > 0 do append(&sens, [3]string{"CPU", fmt.tprintf("%.0f°", p.cpu_temp), p.cpu_temp >= 85 ? "hot" : (p.cpu_temp >= 75 ? "warn" : "")})
	if p.nvme_temp > 0 do append(&sens, [3]string{"NVMe", fmt.tprintf("%.0f°", p.nvme_temp), p.nvme_temp >= 70 ? "warn" : ""})
	if p.gpu_ok {
		append(&sens, [3]string{"GPU", fmt.tprintf("%.0f°", p.gpu_temp), p.gpu_temp >= 85 ? "hot" : (p.gpu_temp >= 75 ? "warn" : "")})
		append(&sens, [3]string{"Fan", fmt.tprintf("%.0f%%", p.gpu_fan), p.gpu_fan >= 80 ? "warn" : ""})
		append(&sens, [3]string{"Power", fmt.tprintf("%.0f W", p.gpu_w), ""})
	}
	if p.bat != "" do append(&sens, [3]string{"Battery", p.bat, ""})
	if len(sens) > 0 {
		sw := (w - 24 * S) / len(sens)
		for s, i in sens {
			sx := 12 * S + i * sw
			if i > 0 do fill_rect(cv, sx, sy, S, sensors_h, argb(H.line, 0xff))
			c := s[2] == "hot" ? H.hot : (s[2] == "warn" ? t.yellow : H.fg)
			tw2 := tw(p.f10, s[0]) + 6 * S + tw(p.f10b, s[1])
			lx := sx + (sw - tw2) / 2
			text_in(cv, p.f10, s[0], lx, sy, sensors_h, argb(H.dim, 0xff))
			text_in(cv, p.f10b, s[1], lx + tw(p.f10, s[0]) + 6 * S, sy, sensors_h, argb(c, 0xff))
		}
	}
}

@(private = "file")
perf_draw_procs :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32) {
	p := a.perf
	t := a.theme
	w := cv.w
	x0, x1 := 12 * S, w - 12 * S
	y := top + 10 * S
	// the filter
	fill_rect(cv, x0, y, x1 - x0, 32 * S, argb(t.fg, 0x0a))
	rounded_rect(cv, x0, y, x1 - x0, 32 * S, 0, 0, f32(S), argb(H.line, 0xff))
	fill_rect(cv, x0, y, 3 * S, 32 * S, argb(H.acc, 0xff))
	text_in(cv, p.f13b, "›", x0 + 10 * S, y, 32 * S, argb(H.acc, 0xff))
	qx := x0 + 10 * S + tw(p.f13b, "›") + 8 * S
	qt := string(a.query[:])
	if qt == "" do text_in(cv, p.f12, "Filter processes…", qx, y, 32 * S, argb(H.hint, 0xff))
	else do text_in(cv, p.f12, qt, qx, y, 32 * S, argb(H.fg, 0xff))
	qs := shape(p.f12, qt)
	cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
	fill_rect(cv, qx + int(qs.cp_x[min(cp, len(qs.cp_x) - 1)]), y + (32 * S - int(p.f12.line_h)) / 2, max(S, 2), int(p.f12.line_h), argb(H.acc, 0xff))
	shown := perf_shown(a)
	sorts := [3]string{"by CPU", "by memory", "by name"}
	cnt := qt != "" ? fmt.tprintf("%d match", len(shown)) : fmt.tprintf("top 12 · %s", sorts[p.sort])
	text_in(cv, p.f10, cnt, x1 - 10 * S - tw(p.f10, cnt), y, 32 * S, argb(H.dim, 0xff))
	y += 32 * S + 8 * S
	// the columns
	cpu_w, mem_w, pid_w, user_w := 74 * S, 70 * S, 52 * S, 60 * S
	col_x := proc(x1, cpu_w, mem_w, user_w, pid_w, S: int) -> (int, int, int, int) {
		ux := x1 - 10 * S - user_w
		mx := ux - 10 * S - mem_w
		cx := mx - 10 * S - cpu_w
		px := cx - 10 * S - pid_w
		return px, cx, mx, ux
	}
	px, cx, mx, ux := col_x(x1, cpu_w, mem_w, user_w, pid_w, S)
	hy, hh := y, 24 * S
	spaced(cv, p.f10b, "PROCESS", x0 + 10 * S, hy, hh, H.dim, S)
	text_in(cv, p.f10b, "PID", px + pid_w - tw(p.f10b, "PID"), hy, hh, argb(H.dim, 0xff))
	cl := p.sort == 0 ? "CPU ▾" : "CPU"
	ml := p.sort == 1 ? "MEM ▾" : "MEM"
	text_in(cv, p.f10b, cl, cx + cpu_w - tw(p.f10b, cl), hy, hh, argb(p.sort == 0 ? H.acc : H.dim, 0xff))
	hit_add(a, cx, hy, cpu_w, hh, .Result, 0, 0)
	text_in(cv, p.f10b, ml, mx + mem_w - tw(p.f10b, ml), hy, hh, argb(p.sort == 1 ? H.acc : H.dim, 0xff))
	hit_add(a, mx, hy, mem_w, hh, .Result, 1, 0)
	text_in(cv, p.f10b, "USER", ux, hy, hh, argb(H.dim, 0xff))
	fill_rect(cv, x0, hy + hh, x1 - x0, S, argb(H.line, 0xff))
	y = hy + hh + 3 * S
	sel, cur, has := perf_sel(a)
	rh := 27 * S
	bar_y := fy - 10 * S - 40 * S
	for x, i in shown {
		if y + rh > bar_y - 6 * S do break
		on := i == cur
		asking := p.ask_pid == x.pid
		if asking do fill_rect(cv, x0, y, x1 - x0, rh, argb(H.hot, 0xff))
		else if on { fill_rect(cv, x0, y, x1 - x0, rh, argb(H.acc, 0xff)); mark_sel(a, x0, y, x1 - x0, rh) }
		fg := on || asking ? H.bg : H.fg
		dc := on || asking ? H.bg : H.dim
		nf := on ? p.f11b : p.f11
		text_in(cv, nf, x.name, x0 + 10 * S, y, rh, argb(fg, 0xff))
		dx := x0 + 10 * S + tw(nf, x.name) + 8 * S
		text_in(cv, p.f10, ellipsize(p.f10, x.desc, px - 10 * S - dx), dx, y, rh, argb(dc, 0xff))
		pid := fmt.tprint(x.pid)
		text_in(cv, p.f10, pid, px + pid_w - tw(p.f10, pid), y, rh, argb(dc, 0xff))
		cc := x.cpu >= 50 ? H.hot : (x.cpu >= 20 ? t.yellow : H.acc)
		fill_rect(cv, cx + 4 * S, y + (rh - 3 * S) / 2, 22 * S, 3 * S, on || asking ? argb(0, 0x40) : argb(H.line, 0xff))
		fill_rect(cv, cx + 4 * S, y + (rh - 3 * S) / 2, int(min(x.cpu, 100) / 100 * f32(22 * S)), 3 * S, argb(on || asking ? H.bg : cc, 0xff))
		cs := fmt.tprintf("%.1f%%", x.cpu)
		text_in(cv, p.f11, cs, cx + cpu_w - tw(p.f11, cs), y, rh, argb(on || asking ? H.bg : (x.cpu >= 50 ? H.hot : H.fg), 0xff))
		ms := perf_mem_str(x.mem)
		mvc := on || asking ? H.bg : (x.mem >= 4000 ? H.hot : (x.mem >= 1500 ? t.yellow : soft))
		text_in(cv, p.f11, ms, mx + mem_w - tw(p.f11, ms), y, rh, argb(mvc, 0xff))
		text_in(cv, p.f10, ellipsize(p.f10, x.user, user_w), ux, y, rh, argb(dc, 0xff))
		hit_add(a, x0, y, x1 - x0, rh, .Row, x.pid, 0)
		y += rh
	}
	// the bar: what the picked one is, and what can be done
	bh := 40 * S
	asking := p.ask_pid != 0 && has && sel.pid == p.ask_pid
	fill_rect(cv, x0, bar_y, x1 - x0, bh, argb(t.fg, 0x0a))
	rounded_rect(cv, x0, bar_y, x1 - x0, bh, 0, 0, f32(S), argb(asking ? H.hot : H.line, 0xff))
	if asking do fill_rect(cv, x0, bar_y, 3 * S, bh, argb(H.hot, 0xff))
	if !has do return
	acts: [][3]string
	line: string
	if asking {
		line = fmt.tprintf("End %s (%d)? Unsaved work in it may be lost", sel.name, sel.pid)
		acts = {{"End", "y", "0"}, {"Cancel", "n", "3"}}
	} else {
		line = fmt.tprintf("%s · %d · %.1f%% CPU · %s", sel.name, sel.pid, sel.cpu, perf_mem_str(sel.mem))
		acts = {{"End", "Del", "0"}, {"Force kill", "⇧Del", "1"}, {"btop", "↵", "2"}}
	}
	ax := x1 - 10 * S
	for i := len(acts) - 1; i >= 0; i -= 1 {
		a_ := acts[i]
		bw := tw(p.f10b, a_[0]) + 6 * S + tw(p.f10, a_[1]) + 18 * S
		ax -= bw
		hot := asking && i == 0
		if hot do fill_rect(cv, ax, bar_y + (bh - 26 * S) / 2, bw, 26 * S, argb(H.hot, 0xff))
		rounded_rect(cv, ax, bar_y + (bh - 26 * S) / 2, bw, 26 * S, 0, 0, f32(S), argb(hot ? H.hot : H.line, 0xff))
		text_in(cv, p.f10b, a_[0], ax + 9 * S, bar_y + (bh - 26 * S) / 2, 26 * S, argb(hot ? H.bg : soft, 0xff))
		text_in(cv, p.f10, a_[1], ax + 9 * S + tw(p.f10b, a_[0]) + 6 * S, bar_y + (bh - 26 * S) / 2, 26 * S, argb(hot ? H.bg : H.dim, 0xff))
		id, _ := strconv.parse_int(a_[2])
		hit_add(a, ax, bar_y + (bh - 26 * S) / 2, bw, 26 * S, .Chip, id, 0)
		ax -= 8 * S
	}
	text_in(cv, p.f11, ellipsize(p.f11, line, ax - x0 - 20 * S), x0 + 10 * S, bar_y, bh, argb(asking ? H.hot : soft, 0xff))
}

@(private = "file")
perf_draw_utils :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32) {
	p := a.perf
	t := a.theme
	w := cv.w
	if len(p.utils) == 0 {
		l := p.loader == "" ? "No utilities (k4-perf gives them)" : "Measuring…"
		text_in(cv, p.f12, l, (w - tw(p.f12, l)) / 2, top + 80 * S, 20 * S, argb(H.dim, 0xff))
		return
	}
	order := perf_util_order(p)
	colw := (w - 24 * S - 14 * S) / 2
	for c in 0 ..< 2 {
		x := 12 * S + c * (colw + 14 * S)
		y := top + 4 * S
		group := ""
		for oi, k in order {
			u := p.utils[oi]
			if u.col != c do continue
			if u.group != group {
				group = u.group
				y += 10 * S
				spaced(cv, p.f10b, strings.to_upper(group, context.temp_allocator), x + 2 * S, y, int(p.f10b.line_h), H.dim, S)
				y += int(p.f10b.line_h) + 5 * S
			}
			rh := 44 * S
			if y + rh > fy - 6 * S do break
			on := k == p.ui
			asking := p.uask == u.id
			bg := asking ? argb(H.hot, 0x14) : (on ? argb(H.acc, 0xff) : argb(t.fg, 0x0a))
			fill_rect(cv, x, y, colw, rh, bg)
			rounded_rect(cv, x, y, colw, rh, 0, 0, f32(S), argb(asking ? H.hot : (on ? H.acc : H.line), 0xff))
			if on && !asking do mark_sel(a, x, y, colw, rh)
			inv := on && !asking
			sub, sc := u.sub, H.dim
			meta, mc := u.meta, H.acc
			if len(u.steps) > 0 do meta = fmt.tprintf("‹ %s ›", u.steps[clamp(u.cur, 0, len(u.steps) - 1)])
			if u.done != "" { sub, sc, meta, mc = u.done, t.green, "done", t.green }
			if p.job.running && p.job_id == u.id { sub, sc, meta, mc = perf_job_line(p), H.acc, "running", H.acc }
			if asking { sub, sc, meta, mc = "Sure? y runs it · n cancels", H.hot, "y / n", H.hot }
			right := x + colw - 10 * S
			if u.tog {
				sw, sh := 28 * S, 14 * S
				sx, sy := right - sw, y + (rh - sh) / 2
				if u.on do fill_rect(cv, sx, sy, sw, sh, argb(inv ? H.bg : H.acc, 0xff))
				rounded_rect(cv, sx, sy, sw, sh, 0, 0, f32(S), argb(inv ? H.bg : (u.on ? H.acc : H.faint), 0xff))
				fill_rect(cv, u.on ? sx + sw - 12 * S : sx + 2 * S, sy + 2 * S, 10 * S, 10 * S, argb(u.on ? (inv ? H.acc : H.bg) : (inv ? H.bg : H.dim), 0xff))
				right = sx - 8 * S
			} else if meta != "" {
				text_in(cv, p.f10b, meta, right - tw(p.f10b, meta), y, rh, argb(inv ? H.bg : mc, 0xff))
				right -= tw(p.f10b, meta) + 8 * S
			}
			ly := y + (rh - int(p.f11b.line_h) - 3 * S - int(p.f10.line_h)) / 2
			text_in(cv, p.f11b, ellipsize(p.f11b, u.label, right - x - 10 * S), x + 10 * S, ly, int(p.f11b.line_h), argb(inv ? H.bg : H.fg, 0xff))
			text_in(cv, p.f10, ellipsize(p.f10, sub, right - x - 10 * S), x + 10 * S, ly + int(p.f11b.line_h) + 3 * S, int(p.f10.line_h), argb(inv ? H.bg : sc, 0xff))
			hit_add(a, x, y, colw, rh, .Item, k, 0)
			y += rh + 3 * S
		}
	}
}

perf_dump :: proc(a: ^App) -> string {
	p := a.perf
	sb := strings.builder_make(context.temp_allocator)
	pages := [3]string{"overview", "processes", "utilities"}
	fmt.sbprintfln(&sb, "perf %s", pages[p.tab])
	switch p.tab {
	case 0:
		fmt.sbprintfln(&sb, "cards CPU MEMORY DISK NETWORK · %d threads · %d processes", p.cores, len(p.procs))
	case 1:
		_, cur, _ := perf_sel(a)
		sorts := [3]string{"cpu", "mem", "name"}
		fmt.sbprintfln(&sb, "sort %s · %d shown", sorts[p.sort], len(perf_shown(a)))
		if p.ask_pid != 0 do fmt.sbprintfln(&sb, "ask %d", p.ask_pid)
		_ = cur
	case 2:
		for oi, k in perf_util_order(p) {
			u := p.utils[oi]
			fmt.sbprintfln(&sb, "%s %s · %s%s", k == p.ui ? "*" : " ", u.group, u.label, p.uask == u.id ? " (asking)" : "")
		}
	}
	if p.job.running do fmt.sbprintfln(&sb, "running %s", p.job_id)
	if p.toast != "" do fmt.sbprintfln(&sb, "toast %s", p.toast)
	return strings.to_string(sb)
}
