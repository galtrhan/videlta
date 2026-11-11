package videlta

/*
	videlta - turn a video into a base frame plus cumulative delta frames.

	Frame 0 is the base image. Every following frame only stores the pixels that
	changed since the previous frame, everything else stays fully transparent.
	Draw frame 0, then 1, 2, 3... on the same canvas and the video plays back.
*/

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import stb "vendor:stb/image"

VERSION :: "0.1.0"

DEFAULT_THRESHOLD   :: 8
DEFAULT_BG_TOL      :: 16
DEFAULT_JPG_QUALITY :: 90

Config :: struct {
	input:       string,
	out_dir:     string,
	has_bg:      bool,
	bg:          [3]u8,
	fps:         string,
	threshold:   int,
	bg_tol:      int,
	jpg_quality: int,
	lossless:    bool,
	verify:      bool,
	force:       bool,
	optimize:    bool,
	verbose:     bool,
}

Frame_Reader :: struct {
	process:     os.Process,
	pipe:        ^os.File,
	buf:         []u8,
	frame_bytes: int,
}

USAGE :: `videlta ` + VERSION + ` - base frame + delta PNG frames from a video

Usage:
  videlta <input> [options]

Options:
  -o, --out DIR         Output directory (default: <input>_frames next to the input)
  -bg, --bg COLOR       Background color to key out: #RRGGBB, RRGGBB or R,G,B.
                        Frame 0 is then written as 0.png with the background
                        transparent. Without -bg, frame 0 is written as 0.jpg.
  -fps, --fps RATE      Resample to RATE frames per second (e.g. 12, 29.97 or
                        30000/1001). Default: keep the source frames.
  -threshold N          Per-channel change threshold 0..255 (default: 8, 0 = exact).
                        Smaller changes are treated as unchanged and stay transparent.
  -bg-tol N             Background key tolerance 0..255 (default: 16).
  -jpgq N               JPEG quality 1..100 for 0.jpg (default: 90).
  -lossless             Without -bg, write an opaque 0.png instead of a lossy 0.jpg.
  -optimize             Smaller files, same pixels. ImageMagick lossless PNG
                        recompress for every PNG; cjpeg -optimize for 0.jpg when
                        the base is JPEG. Needs magick; needs cjpeg only for 0.jpg.
  -verify               Decode the written files, composite them on a canvas and
                        compare against the source video. Reports the worst error.
  -force                Replace a non-empty output directory.
  -v, --verbose         Print one line per frame.
  -V, --version         Print the version.
  -h, --help            Show this help.

Output:
  0.jpg (without -bg) or 0.png (with -bg), followed by 1.png, 2.png, ...
  Each delta PNG holds only the pixels that changed since the previous frame.
  Every other pixel is fully transparent. Compositing 0, 1, 2, 3... in order on
  one canvas replays the video. See README.md for the exact rules.
`

main :: proc() {
	os.exit(cli(os.args))
}

cli :: proc(args: []string) -> int {
	cfg := Config {
		threshold   = DEFAULT_THRESHOLD,
		bg_tol      = DEFAULT_BG_TOL,
		jpg_quality = DEFAULT_JPG_QUALITY,
	}

	have_input := false

	i := 1
	for i < len(args) {
		arg := args[i]
		switch arg {
		case "-h", "--help", "help":
			fmt.print(USAGE)
			return 0
		case "-V", "--version":
			fmt.printf("videlta %s\n", VERSION)
			return 0
		case "-v", "--verbose":
			cfg.verbose = true
		case "-verify", "--verify":
			cfg.verify = true
		case "-lossless", "--lossless":
			cfg.lossless = true
		case "-optimize", "--optimize":
			cfg.optimize = true
		case "-force", "--force":
			cfg.force = true
		case "-o", "--out":
			i += 1
			if i >= len(args) {
				return usage_error("missing value for %s", arg)
			}
			cfg.out_dir = args[i]
		case "-bg", "--bg", "--background":
			i += 1
			if i >= len(args) {
				return usage_error("missing value for %s", arg)
			}
			rgb, cok := parse_color(args[i])
			if !cok {
				return usage_error("invalid color %q: expected #RRGGBB, RRGGBB or R,G,B", args[i])
			}
			cfg.has_bg = true
			cfg.bg = rgb
		case "-fps", "--fps":
			i += 1
			if i >= len(args) {
				return usage_error("missing value for %s", arg)
			}
			rate, rok := parse_rate(args[i])
			if !rok || rate <= 0 {
				return usage_error("invalid fps %q", args[i])
			}
			cfg.fps = args[i]
		case "-threshold", "-t", "--threshold":
			i += 1
			if i >= len(args) {
				return usage_error("missing value for %s", arg)
			}
			v, vok := parse_int_range(args[i], 0, 255)
			if !vok {
				return usage_error("invalid threshold %q: expected 0..255", args[i])
			}
			cfg.threshold = v
		case "-bg-tol", "--bg-tol":
			i += 1
			if i >= len(args) {
				return usage_error("missing value for %s", arg)
			}
			v, vok := parse_int_range(args[i], 0, 255)
			if !vok {
				return usage_error("invalid background tolerance %q: expected 0..255", args[i])
			}
			cfg.bg_tol = v
		case "-jpgq", "-jpg-quality", "--jpg-quality":
			i += 1
			if i >= len(args) {
				return usage_error("missing value for %s", arg)
			}
			v, vok := parse_int_range(args[i], 1, 100)
			if !vok {
				return usage_error("invalid JPEG quality %q: expected 1..100", args[i])
			}
			cfg.jpg_quality = v
		case:
			if strings.has_prefix(arg, "-") && arg != "-" {
				return usage_error("unknown option %q", arg)
			}
			if have_input {
				return usage_error("unexpected argument %q", arg)
			}
			cfg.input = arg
			have_input = true
		}
		i += 1
	}

	if !have_input {
		fmt.eprintln("videlta: missing input video")
		fmt.eprintln("try `videlta -h`")
		return 2
	}

	fi, ferr := os.stat(cfg.input, context.allocator)
	if ferr != nil {
		fmt.eprintf("videlta: cannot read %q: %s\n", cfg.input, os.error_string(ferr))
		return 1
	}
	defer os.file_info_delete(fi, context.allocator)

	if fi.type == .Directory {
		fmt.eprintf("videlta: %q is a directory, expected a video file\n", cfg.input)
		return 1
	}

	if cfg.out_dir == "" {
		stem := os.stem(cfg.input)
		if stem == "" {
			stem = "frames"
		}
		dir := os.dir(cfg.input)
		if dir == "" {
			dir = "."
		}
		cfg.out_dir = fmt.aprintf("%s/%s_frames", dir, stem)
	}

	return run(cfg)
}

usage_error :: proc(format: string, args: ..any) -> int {
	fmt.eprint("videlta: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	fmt.eprintln("try `videlta -h`")
	return 2
}

parse_color :: proc(input: string) -> (rgb: [3]u8, ok: bool) {
	s := strings.trim_space(input)
	if strings.has_prefix(s, "#") {
		s = s[1:]
	}

	if strings.contains_rune(s, ',') {
		parts, _ := strings.split(s, ",", context.temp_allocator)
		if len(parts) != 3 {
			return {}, false
		}
		for p, idx in parts {
			v, vok := strconv.parse_int(strings.trim_space(p), 10)
			if !vok || v < 0 || v > 255 {
				return {}, false
			}
			rgb[idx] = u8(v)
		}
		return rgb, true
	}

	if len(s) == 3 {
		buf: [6]u8
		buf[0] = s[0]; buf[1] = s[0]
		buf[2] = s[1]; buf[3] = s[1]
		buf[4] = s[2]; buf[5] = s[2]
		s = string(buf[:])
	}
	if len(s) != 6 {
		return {}, false
	}

	for idx in 0 ..< 3 {
		v, vok := strconv.parse_int(s[idx * 2:idx * 2 + 2], 16)
		if !vok || v < 0 || v > 255 {
			return {}, false
		}
		rgb[idx] = u8(v)
	}
	return rgb, true
}

parse_int_range :: proc(s: string, lo, hi: int) -> (v: int, ok: bool) {
	n, nok := strconv.parse_int(strings.trim_space(s), 10)
	if !nok || n < lo || n > hi {
		return 0, false
	}
	return n, true
}

parse_rate :: proc(s: string) -> (rate: f64, ok: bool) {
	t := strings.trim_space(s)
	if idx := strings.index_byte(t, '/'); idx >= 0 {
		num, ok1 := strconv.parse_f64(t[:idx])
		den, ok2 := strconv.parse_f64(t[idx + 1:])
		if !ok1 || !ok2 || den == 0 {
			return 0, false
		}
		return num / den, true
	}
	return strconv.parse_f64(t)
}

probe_video :: proc(input: string) -> (w, h: int, ok: bool) {
	cmd := make([dynamic]string, 0, 12, context.temp_allocator)
	append(
		&cmd,
		"ffprobe",
		"-v", "error",
		"-select_streams", "V:0",
		"-show_entries", "stream=width,height",
		"-of", "default=nokey=1:noprint_wrappers=1",
		input,
	)

	desc := os.Process_Desc {
		command = cmd[:],
	}

	state, out, err_out, perr := os.process_exec(desc, context.temp_allocator)
	if perr != nil {
		fmt.eprintf("videlta: cannot run ffprobe: %s\n", os.error_string(perr))
		return 0, 0, false
	}
	if state.exit_code != 0 {
		fmt.eprintf("videlta: ffprobe failed: %s\n", strings.trim_space(string(err_out)))
		return 0, 0, false
	}

	text := strings.trim_space(string(out))
	if text == "" {
		fmt.eprintf("videlta: no video stream found in %q\n", input)
		return 0, 0, false
	}

	nums: [2]int
	found := 0
	lines, _ := strings.split(text, "\n", context.temp_allocator)
	for line in lines {
		l := strings.trim_space(line)
		if l == "" {
			continue
		}
		v, vok := strconv.parse_int(l, 10)
		if !vok || v <= 0 {
			fmt.eprintf("videlta: cannot parse ffprobe output %q\n", l)
			return 0, 0, false
		}
		if found < 2 {
			nums[found] = v
		}
		found += 1
	}
	if found < 2 {
		fmt.eprintln("videlta: ffprobe returned incomplete frame dimensions")
		return 0, 0, false
	}

	return nums[0], nums[1], true
}

prepare_out_dir :: proc(cfg: Config) -> bool {
	if os.exists(cfg.out_dir) {
		fi, ferr := os.stat(cfg.out_dir, context.temp_allocator)
		if ferr != nil {
			fmt.eprintf("videlta: cannot inspect %q: %s\n", cfg.out_dir, os.error_string(ferr))
			return false
		}
		if fi.type != .Directory {
			fmt.eprintf("videlta: %q exists and is not a directory\n", cfg.out_dir)
			return false
		}

		entries, derr := os.read_all_directory_by_path(cfg.out_dir, context.temp_allocator)
		if derr != nil {
			fmt.eprintf("videlta: cannot list %q: %s\n", cfg.out_dir, os.error_string(derr))
			return false
		}

		count := 0
		for e in entries {
			if e.name != "." && e.name != ".." {
				count += 1
			}
		}

		if count > 0 {
			if !cfg.force {
				fmt.eprintf(
					"videlta: output directory %q is not empty (use -force to replace it)\n",
					cfg.out_dir,
				)
				return false
			}
			if rerr := os.remove_all(cfg.out_dir); rerr != nil {
				fmt.eprintf("videlta: cannot clear %q: %s\n", cfg.out_dir, os.error_string(rerr))
				return false
			}
		}
	}

	if merr := os.make_directory_all(cfg.out_dir); merr != nil {
		fmt.eprintf("videlta: cannot create %q: %s\n", cfg.out_dir, os.error_string(merr))
		return false
	}
	return true
}

reader_start :: proc(cfg: Config, buf: []u8) -> (r: Frame_Reader, ok: bool) {
	pipe_r, pipe_w, perr := os.pipe()
	if perr != nil {
		fmt.eprintf("videlta: cannot create pipe: %s\n", os.error_string(perr))
		return {}, false
	}

	cmd := make([dynamic]string, 0, 18, context.temp_allocator)
	append(
		&cmd,
		"ffmpeg",
		"-hide_banner",
		"-v", "error",
		"-nostdin",
		"-noautorotate",
		"-i", cfg.input,
		"-map", "0:V:0",
	)
	if cfg.fps != "" {
		append(&cmd, "-vf", fmt.aprintf("fps=%s", cfg.fps))
	} else {
		append(&cmd, "-fps_mode", "passthrough")
	}
	append(&cmd, "-f", "rawvideo", "-pix_fmt", "rgb24", "-")

	desc := os.Process_Desc {
		command = cmd[:],
		stdout  = pipe_w,
		stderr  = os.stderr,
	}

	process, serr := os.process_start(desc)
	os.close(pipe_w)
	if serr != nil {
		os.close(pipe_r)
		fmt.eprintf("videlta: cannot start ffmpeg: %s\n", os.error_string(serr))
		return {}, false
	}

	return Frame_Reader {
		process     = process,
		pipe        = pipe_r,
		buf         = buf,
		frame_bytes = len(buf),
	}, true
}

process_wait_ok :: proc(process: os.Process, tool: string) -> bool {
	state, werr := os.process_wait(process)
	if werr != nil {
		fmt.eprintf("videlta: cannot wait for %s: %s\n", tool, os.error_string(werr))
		return false
	}
	if !state.success || state.exit_code != 0 {
		fmt.eprintf("videlta: %s exited with status %d\n", tool, state.exit_code)
		return false
	}
	return true
}

reader_stop :: proc(r: ^Frame_Reader) -> bool {
	if r.pipe != nil {
		os.close(r.pipe)
		r.pipe = nil
	}
	return process_wait_ok(r.process, "ffmpeg")
}

read_frame :: proc(r: ^Frame_Reader) -> (got: int, err: os.Error) {
	for got < r.frame_bytes {
		n, e := os.read(r.pipe, r.buf[got:])
		got += n
		if e != nil {
			return got, e
		}
		if n == 0 {
			return got, .EOF
		}
	}
	return got, nil
}

fill_bg :: proc(dst: []u8, bg: [3]u8) {
	for i := 0; i < len(dst); i += 3 {
		dst[i + 0] = bg[0]
		dst[i + 1] = bg[1]
		dst[i + 2] = bg[2]
	}
}

fill_opaque :: proc(dst_rgba: []u8, src_rgb: []u8) {
	for p in 0 ..< len(src_rgb) / 3 {
		dst_rgba[p * 4 + 0] = src_rgb[p * 3 + 0]
		dst_rgba[p * 4 + 1] = src_rgb[p * 3 + 1]
		dst_rgba[p * 4 + 2] = src_rgb[p * 3 + 2]
		dst_rgba[p * 4 + 3] = 255
	}
}

tool_ok :: proc(cmd: []string) -> bool {
	desc := os.Process_Desc {
		command = cmd,
	}
	state, _, _, perr := os.process_exec(desc, context.temp_allocator)
	return perr == nil && state.exit_code == 0
}

// magick is always required. cjpeg only when the base frame is 0.jpg.
require_optimize_tools :: proc(cfg: Config) -> bool {
	if !tool_ok([]string{"magick", "-version"}) {
		fmt.eprintln("videlta: -optimize requires ImageMagick `magick` on PATH")
		return false
	}
	need_cjpeg := !cfg.has_bg && !cfg.lossless
	if need_cjpeg && !tool_ok([]string{"cjpeg", "-version"}) {
		fmt.eprintln("videlta: -optimize requires cjpeg on PATH (libjpeg-turbo) for 0.jpg")
		return false
	}
	return true
}

optimize_png_file :: proc(path: string) -> bool {
	cmd := make([dynamic]string, 0, 8, context.temp_allocator)
	append(
		&cmd,
		"magick",
		path,
		"-strip",
		"-define", "png:compression-level=9",
		"-define", "png:compression-filter=5",
		path,
	)
	desc := os.Process_Desc {
		command = cmd[:],
	}
	state, _, err_out, perr := os.process_exec(desc, context.temp_allocator)
	if perr != nil {
		fmt.eprintf("videlta: cannot run magick: %s\n", os.error_string(perr))
		return false
	}
	if state.exit_code != 0 {
		msg := strings.trim_space(string(err_out))
		if msg == "" {
			fmt.eprintf("videlta: magick failed on %s (status %d)\n", path, state.exit_code)
		} else {
			fmt.eprintf("videlta: magick failed on %s: %s\n", path, msg)
		}
		return false
	}
	return true
}

write_png_file :: proc(path: string, rgba: []u8, w, h: int, optimize: bool) -> bool {
	if stb.write_png(
		cstr(path),
		c.int(w), c.int(h), 4,
		rawptr(raw_data(rgba)),
		c.int(w * 4),
	) == 0 {
		return false
	}
	return !optimize || optimize_png_file(path)
}

write_jpg_cjpeg :: proc(path: string, rgb: []u8, w, h, quality: int) -> bool {
	pipe_r, pipe_w, perr := os.pipe()
	if perr != nil {
		fmt.eprintf("videlta: cannot create pipe: %s\n", os.error_string(perr))
		return false
	}

	qstr := fmt.aprintf("%d", quality)
	defer delete(qstr)

	cmd := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&cmd, "cjpeg", "-optimize", "-quality", qstr, "-outfile", path)

	desc := os.Process_Desc {
		command = cmd[:],
		stdin   = pipe_r,
		stderr  = os.stderr,
	}

	process, serr := os.process_start(desc)
	os.close(pipe_r)
	if serr != nil {
		os.close(pipe_w)
		fmt.eprintf("videlta: cannot start cjpeg: %s\n", os.error_string(serr))
		return false
	}

	fail :: proc(process: os.Process, path, why: string) -> bool {
		_, _ = os.process_wait(process)
		_ = os.remove(path)
		fmt.eprintf("videlta: %s\n", why)
		return false
	}

	header := fmt.aprintf("P6\n%d %d\n255\n", w, h)
	defer delete(header)

	hw, herr := os.write(pipe_w, raw_data(header)[:len(header)])
	if herr != nil || hw != len(header) {
		os.close(pipe_w)
		return fail(process, path, "failed to write PPM header to cjpeg")
	}
	rw, rerr := os.write(pipe_w, rgb)
	os.close(pipe_w)
	if rerr != nil || rw != len(rgb) {
		return fail(process, path, "failed to write RGB to cjpeg")
	}

	if !process_wait_ok(process, "cjpeg") {
		_ = os.remove(path)
		return false
	}
	return true
}

write_jpg_file :: proc(path: string, rgb: []u8, w, h, quality: int, optimize: bool) -> bool {
	if optimize {
		return write_jpg_cjpeg(path, rgb, w, h, quality)
	}
	return stb.write_jpg(
		cstr(path),
		c.int(w), c.int(h), 3,
		rawptr(raw_data(rgb)),
		c.int(quality),
	) != 0
}

abs_u8 :: proc(a, b: u8) -> int {
	d := int(a) - int(b)
	if d < 0 {
		return -d
	}
	return d
}

// Odin strings are null-terminated, so this is a cheap reinterpretation.
cstr :: proc(s: string) -> cstring {
	return cstring(raw_data(s))
}

// Writes the changed pixels of `next` (RGB) into `rgba` (RGBA) and advances `cur`.
// Pixels within `threshold` of the current canvas stay transparent.
// With a background color, pixels within `bg_tol` of it are snapped to the exact
// background color, so keyed areas get repainted with that color instead of
// leaving stale pixels behind.
diff_into :: proc(next, cur, rgba: []u8, cfg: Config) -> (opaque: int) {
	pixels := len(next) / 3
	thr := cfg.threshold
	tol := cfg.bg_tol
	has_bg := cfg.has_bg
	bgr, bgg, bgb := cfg.bg[0], cfg.bg[1], cfg.bg[2]

	for i in 0 ..< pixels {
		j := i * 3
		k := i * 4

		r := next[j + 0]
		g := next[j + 1]
		b := next[j + 2]

		if has_bg {
			if abs_u8(r, bgr) <= tol && abs_u8(g, bgg) <= tol && abs_u8(b, bgb) <= tol {
				r, g, b = bgr, bgg, bgb
			}
		}

		if abs_u8(r, cur[j + 0]) > thr ||
		   abs_u8(g, cur[j + 1]) > thr ||
		   abs_u8(b, cur[j + 2]) > thr {
			rgba[k + 0] = r
			rgba[k + 1] = g
			rgba[k + 2] = b
			rgba[k + 3] = 255
			cur[j + 0] = r
			cur[j + 1] = g
			cur[j + 2] = b
			opaque += 1
		} else {
			rgba[k + 0] = 0
			rgba[k + 1] = 0
			rgba[k + 2] = 0
			rgba[k + 3] = 0
		}
	}
	return
}

file_size :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return 0
	}
	return fi.size
}

fmt_size :: proc(bytes: i64) -> string {
	b := f64(bytes)
	switch {
	case b >= 1024 * 1024 * 1024:
		return fmt.aprintf("%.2f GB", b / (1024 * 1024 * 1024))
	case b >= 1024 * 1024:
		return fmt.aprintf("%.2f MB", b / (1024 * 1024))
	case b >= 1024:
		return fmt.aprintf("%.2f KB", b / 1024)
	}
	return fmt.aprintf("%d B", bytes)
}

run :: proc(cfg: Config) -> int {
	w, h, probe_ok := probe_video(cfg.input)
	if !probe_ok {
		return 1
	}
	frame_bytes := w * h * 3

	if cfg.optimize && !require_optimize_tools(cfg) {
		return 1
	}

	if !prepare_out_dir(cfg) {
		return 1
	}

	buf := make([]u8, frame_bytes)
	defer delete(buf)

	reader, started := reader_start(cfg, buf)
	if !started {
		return 1
	}

	cur := make([]u8, frame_bytes)
	defer delete(cur)
	rgba := make([]u8, w * h * 4)
	defer delete(rgba)

	frames := 0
	total_bytes: i64 = 0
	worst_frame := -1
	worst_pct := f64(0)
	exit_code := 0

	for {
		n, rerr := read_frame(&reader)
		if n == 0 {
			if rerr != nil && rerr != .EOF && rerr != .Broken_Pipe {
				fmt.eprintf("videlta: reading from ffmpeg failed: %s\n", os.error_string(rerr))
				exit_code = 1
			}
			break
		}
		if n < frame_bytes {
			fmt.eprintln("videlta: warning: source ended mid-frame, dropping the partial frame")
			break
		}

		idx := frames
		size: i64
		changed := 0

		fpath: string
		wrote: bool

		if idx == 0 && !cfg.has_bg {
			copy(cur, buf)
			if cfg.lossless {
				fill_opaque(rgba, buf)
				fpath = fmt.aprintf("%s/0.png", cfg.out_dir)
				wrote = write_png_file(fpath, rgba, w, h, cfg.optimize)
			} else {
				fpath = fmt.aprintf("%s/0.jpg", cfg.out_dir)
				wrote = write_jpg_file(fpath, buf, w, h, cfg.jpg_quality, cfg.optimize)
			}
		} else {
			if idx == 0 {
				fill_bg(cur, cfg.bg)
			}
			changed = diff_into(buf, cur, rgba, cfg)
			fpath = fmt.aprintf("%s/%d.png", cfg.out_dir, idx)
			wrote = write_png_file(fpath, rgba, w, h, cfg.optimize)
		}

		if !wrote {
			fmt.eprintf("videlta: failed to write %s\n", fpath)
			delete(fpath)
			exit_code = 1
			break
		}
		size = file_size(fpath)
		delete(fpath)

		total_bytes += size
		frames += 1

		if idx > 0 {
			pct := f64(changed) / f64(w * h) * 100
			if pct > worst_pct {
				worst_pct = pct
				worst_frame = idx
			}
		}

		if cfg.verbose {
			fmt.printf(
				"frame %d: %d/%d px (%.2f%%), %s\n",
				idx, changed, w * h, f64(changed) / f64(w * h) * 100, fmt_size(size),
			)
		}
	}

	stop_ok := reader_stop(&reader)

	if frames == 0 {
		if exit_code == 0 {
			fmt.eprintln("videlta: no frames decoded (does the input contain a video stream?)")
		}
		return 1
	}
	if !stop_ok && exit_code == 0 {
		exit_code = 1
	}

	print_summary(cfg, w, h, frames, total_bytes, worst_frame, worst_pct)

	if exit_code != 0 {
		return exit_code
	}
	if cfg.verify && !verify_run(cfg, w, h) {
		return 1
	}
	return 0
}

print_summary :: proc(cfg: Config, w, h, frames: int, total_bytes: i64, worst_frame: int, worst_pct: f64) {
	source_bytes := i64(w) * i64(h) * 3 * i64(frames)

	fmt.printf("videlta: %dx%d, %d frames -> %s/\n", w, h, frames, cfg.out_dir)
	if cfg.has_bg {
		fmt.printf(
			"  base frame: 0.png (bg #%02X%02X%02X keyed, tolerance %d)\n",
			cfg.bg[0], cfg.bg[1], cfg.bg[2], cfg.bg_tol,
		)
	} else if cfg.lossless {
		fmt.printf("  base frame: 0.png (lossless)\n")
	} else {
		fmt.printf("  base frame: 0.jpg (quality %d)\n", cfg.jpg_quality)
	}
	if frames > 1 {
		fmt.printf(
			"  deltas: %d PNG, %s written (%.1f%% of the %s uncompressed source)\n",
			frames - 1, fmt_size(total_bytes),
			f64(total_bytes) / f64(source_bytes) * 100, fmt_size(source_bytes),
		)
		if worst_frame >= 0 {
			fmt.printf("  largest delta: frame %d (%.2f%% of pixels)\n", worst_frame, worst_pct)
		}
	}
}

decode_rgb_with_ffmpeg :: proc(path: string, w, h: int) -> (pixels: []u8, ok: bool) {
	frame_bytes := w * h * 3
	cmd := make([dynamic]string, 0, 12, context.temp_allocator)
	append(&cmd, "ffmpeg", "-v", "error", "-nostdin", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-")

	desc := os.Process_Desc {
		command = cmd[:],
	}
	state, out, err_out, perr := os.process_exec(desc, context.allocator)
	if perr != nil || state.exit_code != 0 {
		delete(out)
		delete(err_out)
		return nil, false
	}
	delete(err_out)
	if len(out) < frame_bytes {
		delete(out)
		return nil, false
	}
	return out[:frame_bytes], true
}

load_rgba :: proc(path: string, w, h: int) -> (pixels: []u8, ok: bool) {
	width, height, channels: c.int
	data := stb.load(cstr(path), &width, &height, &channels, 4)
	if data == nil {
		return nil, false
	}
	if int(width) != w || int(height) != h {
		fmt.eprintf(
			"videlta: %s is %dx%d, expected %dx%d\n",
			path, width, height, w, h,
		)
		stb.image_free(rawptr(data))
		return nil, false
	}
	return data[:w * h * 4], true
}

composite :: proc(img: []u8, canvas: []u8, pixels: int) {
	for p in 0 ..< pixels {
		k := p * 4
		if img[k + 3] != 0 {
			canvas[p * 3 + 0] = img[k + 0]
			canvas[p * 3 + 1] = img[k + 1]
			canvas[p * 3 + 2] = img[k + 2]
		}
	}
}

max_channel_error :: proc(a, b: []u8) -> int {
	worst := 0
	for i in 0 ..< len(a) {
		d := abs_u8(a[i], b[i])
		if d > worst {
			worst = d
		}
	}
	return worst
}

verify_run :: proc(cfg: Config, w, h: int) -> bool {
	fmt.println("videlta: verifying with a second decode pass")

	frame_bytes := w * h * 3
	buf := make([]u8, frame_bytes)
	defer delete(buf)

	reader, started := reader_start(cfg, buf)
	if !started {
		return false
	}
	defer reader_stop(&reader)

	canvas := make([]u8, frame_bytes)
	defer delete(canvas)
	if cfg.has_bg {
		fill_bg(canvas, cfg.bg)
	}

	base_err := 0
	worst_err := 0
	worst_frame := -1
	frames := 0

	for {
		n, _ := read_frame(&reader)
		if n < frame_bytes {
			break
		}

		idx := frames
		if idx == 0 && !cfg.has_bg && !cfg.lossless {
			// The base is a lossy 0.jpg. Decode it with ffmpeg so the check is not
			// skewed by stb's simpler JPEG decoder.
			fpath := fmt.aprintf("%s/0.jpg", cfg.out_dir)
			base, bok := decode_rgb_with_ffmpeg(fpath, w, h)
			delete(fpath)
			if !bok {
				fmt.eprintf("videlta: verify failed: cannot decode 0.jpg\n")
				return false
			}
			copy(canvas, base)
			delete(base)
		} else {
			fpath: string
			if idx == 0 {
				fpath = fmt.aprintf("%s/0.png", cfg.out_dir)
			} else {
				fpath = fmt.aprintf("%s/%d.png", cfg.out_dir, idx)
			}

			img, iok := load_rgba(fpath, w, h)
			if !iok {
				fmt.eprintf("videlta: verify failed: cannot decode %s\n", fpath)
				delete(fpath)
				return false
			}
			composite(img, canvas, w * h)
			stb.image_free(rawptr(raw_data(img)))
			delete(fpath)
		}

		err := max_channel_error(canvas, buf)
		if idx == 0 {
			base_err = err
		}
		if err > worst_err {
			worst_err = err
			worst_frame = idx
		}
		frames += 1
	}

	if frames == 0 {
		fmt.eprintln("videlta: verify failed: no frames decoded")
		return false
	}

	slack := base_err
	if cfg.has_bg && cfg.bg_tol > slack {
		slack = cfg.bg_tol
	}
	bound := cfg.threshold + slack
	pass := worst_err <= bound

	fmt.printf("  frames compared: %d\n", frames)
	if cfg.has_bg {
		fmt.printf("  base frame 0 error: %d (background key tolerance %d)\n", base_err, cfg.bg_tol)
	} else if cfg.lossless {
		fmt.printf("  base frame 0 error: %d (lossless png base)\n", base_err)
	} else {
		fmt.printf("  base frame 0 error: %d (lossy jpg base)\n", base_err)
	}
	fmt.printf("  worst frame: %d, max channel error %d\n", worst_frame, worst_err)
	verdict := "FAIL"
	if pass {
		verdict = "PASS"
	}
	fmt.printf(
		"  expected bound: threshold %d + slack %d = %d -> %s\n",
		cfg.threshold, slack, bound, verdict,
	)
	return pass
}
