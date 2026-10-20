//! Remote metrics collection over a plain SSH exec channel.
//!
//! The legacy Tauri build shipped the batch-command builder and the section
//! splitter in OSS but kept the *parsers* in the closed-source crate, so an
//! OSS build collected output it could not read. The Flutter bridge went one
//! step further and returned hard-coded zeros, which is what the monitor panel
//! had been rendering.
//!
//! Everything here is plain `/proc`, `df`, `ps` and `netstat` parsing — no
//! agent to install and nothing that warrants being closed-source.
//!
//! CPU and network are *cumulative* counters, so a single sample cannot
//! produce a percentage or a rate. [`MonitorSampler`] keeps the previous
//! reading per session and turns consecutive snapshots into deltas; the
//! first sample of a session reports 0 and primes the baseline.

use std::collections::HashMap;

use super::types::*;

/// Marker prefix/suffix used to split the batched command's output.
const SECTION_MARK: &str = "---";

/// Builds the single batched command whose output [`parse_snapshot`] reads.
///
/// One round-trip per tick rather than one per metric: at a 2s poll interval
/// eight separate `exec` channels per tick is both slow and noisy in the
/// server's auth log.
pub fn build_batch_command(os: ServerOS) -> String {
    match os {
        ServerOS::Linux | ServerOS::Unknown => "echo '---CPU---' && head -1 /proc/stat && \
             echo '---MEM---' && head -8 /proc/meminfo && \
             echo '---DISK---' && df -kP / && \
             echo '---NET---' && cat /proc/net/dev && \
             echo '---LOAD---' && cat /proc/loadavg && \
             echo '---UPTIME---' && cat /proc/uptime && \
             echo '---PROCS---' && ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -21"
            .to_string(),
        ServerOS::MacOS => "echo '---CPU---' && top -l 1 -n 0 | grep 'CPU usage' && \
             echo '---MEM---' && vm_stat && echo '---MEMSIZE---' && sysctl -n hw.memsize && \
             echo '---DISK---' && df -kP / && \
             echo '---NET---' && netstat -ibn && \
             echo '---LOAD---' && sysctl -n vm.loadavg && \
             echo '---UPTIME---' && sysctl -n kern.boottime && \
             echo '---PROCS---' && ps -eo pid,user,pcpu,pmem,comm -r | head -21"
            .to_string(),
        ServerOS::FreeBSD => "echo '---CPU---' && sysctl -n kern.cp_time && \
             echo '---MEM---' && sysctl -n hw.physmem vm.stats.vm.v_free_count vm.stats.vm.v_page_size && \
             echo '---DISK---' && df -kP / && \
             echo '---NET---' && netstat -ibn && \
             echo '---LOAD---' && sysctl -n vm.loadavg && \
             echo '---UPTIME---' && sysctl -n kern.boottime && \
             echo '---PROCS---' && ps -eo pid,user,pcpu,pmem,comm -r | head -21"
            .to_string(),
    }
}

/// Splits batched output into named sections keyed by their `---NAME---` marker.
pub fn split_sections(output: &str) -> HashMap<String, String> {
    let mut sections: HashMap<String, String> = HashMap::new();
    let mut name = String::new();
    let mut body = String::new();

    for line in output.lines() {
        let trimmed = line.trim();
        let marker = trimmed
            .strip_prefix(SECTION_MARK)
            .and_then(|s| s.strip_suffix(SECTION_MARK))
            .filter(|s| !s.is_empty() && !s.contains(SECTION_MARK));
        if let Some(next) = marker {
            if !name.is_empty() {
                sections.insert(name.clone(), body.trim_end().to_string());
            }
            name = next.to_string();
            body.clear();
        } else if !name.is_empty() {
            body.push_str(line);
            body.push('\n');
        }
    }
    if !name.is_empty() {
        sections.insert(name, body.trim_end().to_string());
    }
    sections
}

// ─── Individual parsers ──────────────────────────────────────────────────────

/// Parses the aggregate `cpu` line of `/proc/stat`.
///
/// Fields after `steal` (guest, guest_nice) are already counted inside
/// `user`/`nice` by the kernel, so adding them would double-count.
pub fn parse_proc_stat_cpu(section: &str) -> Option<RawCpuCounters> {
    let line = section.lines().find(|l| l.trim_start().starts_with("cpu"))?;
    let mut v = line.split_whitespace().skip(1).map(|f| f.parse::<u64>().unwrap_or(0));
    Some(RawCpuCounters {
        user: v.next()?,
        nice: v.next().unwrap_or(0),
        system: v.next().unwrap_or(0),
        idle: v.next().unwrap_or(0),
        iowait: v.next().unwrap_or(0),
        irq: v.next().unwrap_or(0),
        softirq: v.next().unwrap_or(0),
        steal: v.next().unwrap_or(0),
    })
}

/// Busy percentage between two `/proc/stat` samples.
///
/// Returns `None` when the counters did not advance — a duplicate read, or a
/// wrapped/rebooted counter where `total` went backwards. Reporting 0% there
/// would be indistinguishable from a genuinely idle host.
pub fn cpu_percent_between(prev: &RawCpuCounters, cur: &RawCpuCounters) -> Option<f32> {
    let total = cur.total().checked_sub(prev.total())?;
    if total == 0 {
        return None;
    }
    let idle = cur.idle_total().saturating_sub(prev.idle_total());
    let busy = total.saturating_sub(idle);
    Some(((busy as f64 / total as f64) * 100.0).clamp(0.0, 100.0) as f32)
}

/// Parses `/proc/meminfo` into (used_mb, total_mb).
///
/// "Used" is `MemTotal - MemAvailable`, not `MemTotal - MemFree`: the latter
/// counts the page cache as used and reports ~100% on any long-running box.
/// Falls back to `free + buffers + cached` on kernels older than 3.14 that
/// do not publish `MemAvailable`.
pub fn parse_meminfo(section: &str) -> Option<(u64, u64)> {
    let mut fields: HashMap<&str, u64> = HashMap::new();
    for line in section.lines() {
        let (key, rest) = line.split_once(':')?;
        let kb = rest.split_whitespace().next()?.parse::<u64>().ok()?;
        fields.insert(key.trim(), kb);
    }
    let total_kb = *fields.get("MemTotal")?;
    let available_kb = fields.get("MemAvailable").copied().unwrap_or_else(|| {
        fields.get("MemFree").copied().unwrap_or(0)
            + fields.get("Buffers").copied().unwrap_or(0)
            + fields.get("Cached").copied().unwrap_or(0)
    });
    let used_kb = total_kb.saturating_sub(available_kb.min(total_kb));
    Some((used_kb / 1024, total_kb / 1024))
}

/// Parses `df -kP <mount>` into (used_gb, total_gb).
///
/// `-P` forces the POSIX one-line-per-filesystem format; without it a long
/// device name wraps onto its own line and the columns shift.
pub fn parse_df(section: &str) -> Option<(f32, f32)> {
    // Skip the header; take the first data row.
    let row = section
        .lines()
        .skip_while(|l| l.trim_start().starts_with("Filesystem"))
        .find(|l| !l.trim().is_empty())?;
    let cols: Vec<&str> = row.split_whitespace().collect();
    if cols.len() < 4 {
        return None;
    }
    let total_kb = cols[1].parse::<f64>().ok()?;
    let used_kb = cols[2].parse::<f64>().ok()?;
    const KB_PER_GB: f64 = 1024.0 * 1024.0;
    Some(((used_kb / KB_PER_GB) as f32, (total_kb / KB_PER_GB) as f32))
}

/// Sums rx/tx bytes across every real interface in `/proc/net/dev`.
///
/// Loopback is excluded — it carries local IPC traffic that says nothing
/// about the host's network activity and can dwarf the real interfaces.
pub fn parse_proc_net_dev(section: &str) -> RawNetworkCounters {
    let mut rx_total = 0u64;
    let mut tx_total = 0u64;
    for line in section.lines() {
        let Some((name, rest)) = line.split_once(':') else {
            continue; // header lines carry no colon
        };
        let name = name.trim();
        if name == "lo" || name.is_empty() {
            continue;
        }
        let cols: Vec<&str> = rest.split_whitespace().collect();
        // /proc/net/dev columns: rx_bytes is 0, tx_bytes is 8.
        if cols.len() < 9 {
            continue;
        }
        rx_total += cols[0].parse::<u64>().unwrap_or(0);
        tx_total += cols[8].parse::<u64>().unwrap_or(0);
    }
    RawNetworkCounters { name: "total".into(), rx_bytes: rx_total, tx_bytes: tx_total }
}

/// Bytes/second between two cumulative network samples.
///
/// A counter that went backwards means the interface reset (or the host
/// rebooted); report 0 for that tick rather than a nonsense spike.
pub fn net_rate_between(
    prev: &RawNetworkCounters,
    cur: &RawNetworkCounters,
    elapsed_secs: f64,
) -> (u64, u64) {
    if elapsed_secs <= 0.0 {
        return (0, 0);
    }
    let rx = cur.rx_bytes.saturating_sub(prev.rx_bytes) as f64 / elapsed_secs;
    let tx = cur.tx_bytes.saturating_sub(prev.tx_bytes) as f64 / elapsed_secs;
    (rx as u64, tx as u64)
}

/// Parses `ps -eo pid,user,pcpu,pmem,comm` output.
pub fn parse_ps(section: &str, limit: usize) -> Vec<ProcessInfo> {
    section
        .lines()
        .skip_while(|l| {
            let u = l.trim_start();
            u.starts_with("PID") || u.starts_with("pid")
        })
        .filter_map(|line| {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 5 {
                return None;
            }
            Some(ProcessInfo {
                pid: cols[0].parse().ok()?,
                user: cols[1].to_string(),
                cpu_percent: cols[2].parse().unwrap_or(0.0),
                mem_percent: cols[3].parse().unwrap_or(0.0),
                // `comm` can contain spaces; everything from column 5 on is
                // the command.
                command: cols[4..].join(" "),
            })
        })
        .take(limit)
        .collect()
}

/// Parses `/proc/loadavg`.
pub fn parse_loadavg(section: &str) -> Option<LoadAverage> {
    let mut v = section.split_whitespace();
    Some(LoadAverage {
        one: v.next()?.parse().ok()?,
        five: v.next()?.parse().unwrap_or(0.0),
        fifteen: v.next()?.parse().unwrap_or(0.0),
    })
}

/// Parses `/proc/uptime`, returning whole seconds.
pub fn parse_uptime(section: &str) -> Option<u64> {
    section.split_whitespace().next()?.parse::<f64>().ok().map(|s| s as u64)
}

// ─── Snapshot ────────────────────────────────────────────────────────────────

/// One parsed tick, still holding the raw cumulative counters so the next
/// tick can difference against it.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub cpu_raw: Option<RawCpuCounters>,
    pub net_raw: RawNetworkCounters,
    pub mem_used_mb: u64,
    pub mem_total_mb: u64,
    pub disk_used_gb: f32,
    pub disk_total_gb: f32,
    pub load: Option<LoadAverage>,
    pub uptime_secs: Option<u64>,
    pub processes: Vec<ProcessInfo>,
}

/// Parses the batched command output into a [`Snapshot`].
///
/// Individually fallible: a host without `/proc/loadavg` still yields CPU and
/// memory rather than failing the whole tick.
pub fn parse_snapshot(output: &str, process_limit: usize) -> Snapshot {
    let sections = split_sections(output);
    let get = |k: &str| sections.get(k).map(String::as_str).unwrap_or("");
    let (mem_used_mb, mem_total_mb) = parse_meminfo(get("MEM")).unwrap_or((0, 0));
    let (disk_used_gb, disk_total_gb) = parse_df(get("DISK")).unwrap_or((0.0, 0.0));
    Snapshot {
        cpu_raw: parse_proc_stat_cpu(get("CPU")),
        net_raw: parse_proc_net_dev(get("NET")),
        mem_used_mb,
        mem_total_mb,
        disk_used_gb,
        disk_total_gb,
        load: parse_loadavg(get("LOAD")),
        uptime_secs: parse_uptime(get("UPTIME")),
        processes: parse_ps(get("PROCS"), process_limit),
    }
}

// ─── Sampler ─────────────────────────────────────────────────────────────────

/// Previous tick for one session, used to difference cumulative counters.
#[derive(Debug, Clone)]
struct Previous {
    cpu: Option<RawCpuCounters>,
    net: RawNetworkCounters,
    at_unix_ms: i64,
}

/// Turns consecutive [`Snapshot`]s into rates, keyed by session id.
///
/// Stateful by necessity: `/proc/stat` and `/proc/net/dev` are monotonic
/// counters, so "CPU 12%" only exists relative to a previous read.
#[derive(Default)]
pub struct MonitorSampler {
    previous: HashMap<String, Previous>,
}

/// A fully-derived tick, ready to hand to the UI.
#[derive(Debug, Clone)]
pub struct DerivedStats {
    pub cpu_percent: f32,
    pub mem_used_mb: u64,
    pub mem_total_mb: u64,
    pub disk_used_gb: f32,
    pub disk_total_gb: f32,
    pub net_rx_bytes: u64,
    pub net_tx_bytes: u64,
    pub load: Option<LoadAverage>,
    pub uptime_secs: Option<u64>,
    pub processes: Vec<ProcessInfo>,
}

impl MonitorSampler {
    pub fn new() -> Self {
        Self::default()
    }

    /// Folds `snapshot` into the session's history and derives rates.
    ///
    /// `now_unix_ms` is passed in rather than read from the clock so the
    /// elapsed interval is testable.
    pub fn ingest(
        &mut self,
        session_id: &str,
        snapshot: Snapshot,
        now_unix_ms: i64,
    ) -> DerivedStats {
        let prev = self.previous.get(session_id);

        // First sample of a session has no baseline: report 0 and prime it.
        // The next tick (2s later at the default interval) shows real numbers.
        let cpu_percent = match (prev.and_then(|p| p.cpu.as_ref()), snapshot.cpu_raw.as_ref()) {
            (Some(p), Some(c)) => cpu_percent_between(p, c).unwrap_or(0.0),
            _ => 0.0,
        };
        let (net_rx_bytes, net_tx_bytes) = match prev {
            Some(p) => {
                let elapsed = (now_unix_ms - p.at_unix_ms) as f64 / 1000.0;
                net_rate_between(&p.net, &snapshot.net_raw, elapsed)
            }
            None => (0, 0),
        };

        self.previous.insert(
            session_id.to_string(),
            Previous {
                cpu: snapshot.cpu_raw.clone(),
                net: snapshot.net_raw.clone(),
                at_unix_ms: now_unix_ms,
            },
        );

        DerivedStats {
            cpu_percent,
            mem_used_mb: snapshot.mem_used_mb,
            mem_total_mb: snapshot.mem_total_mb,
            disk_used_gb: snapshot.disk_used_gb,
            disk_total_gb: snapshot.disk_total_gb,
            net_rx_bytes,
            net_tx_bytes,
            load: snapshot.load,
            uptime_secs: snapshot.uptime_secs,
            processes: snapshot.processes,
        }
    }

    /// Drops a session's baseline. Called on disconnect so a reconnect does
    /// not difference against counters from before a reboot.
    pub fn forget(&mut self, session_id: &str) {
        self.previous.remove(session_id);
    }

    /// True when the session already has a baseline — i.e. the next
    /// [`ingest`](Self::ingest) will produce real rates.
    pub fn has_baseline(&self, session_id: &str) -> bool {
        self.previous.contains_key(session_id)
    }
}
